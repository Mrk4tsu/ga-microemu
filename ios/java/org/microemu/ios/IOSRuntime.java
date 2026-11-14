package org.microemu.ios;

import java.io.*;
import java.util.*;
import javax.microedition.lcdui.*;
import javax.microedition.midlet.MIDlet;
import org.microemu.*;
import org.microemu.app.launcher.Launcher;
import org.microemu.device.DeviceFactory;
import org.microemu.device.ui.EventDispatcher;

public final class IOSRuntime implements MicroEmulator, TabRunner {
    static IOSRuntime instance;
    final int tabId;
    private final Map properties = new HashMap();
    private IOSClassLoader loader;
    private IOSDevice device;
    private IOSRecordStores stores;
    private MIDlet midlet;
    private MIDletAccess midletAccess;
    private volatile boolean running = true;
    private volatile boolean destroyed;
    private volatile boolean sleeping;
    private volatile boolean stopped;
    private long generation;
    private volatile String workerError;
    private volatile String state = "ANALYZING";
    private final IOSInputSequence input = new IOSInputSequence();
    private final Vector heldKeys = new Vector();
    private boolean pointerDown;
    private int pointerX, pointerY;

    public IOSRuntime() {
        this(0);
    }
    private IOSRuntime(int tabId) {
        this.tabId = tabId;
    }
    static int currentTabId() {
        return instance != null ? instance.tabId : 0;
    }
    boolean isSleeping() { return sleeping; }
    boolean isStopped() { return stopped; }
    void sleepThrottle() {
        if (!sleeping || stopped) return;
        try { Thread.sleep(250); } catch (InterruptedException ignored) { }
    }

    public static void main(String[] args) {
        try {
            if (args.length < 2) throw new IllegalArgumentException("Expected JAR and RMS directory");
            instance = new IOSRuntime(0);
            instance.start(args[0], args[1], args.length > 2 ? Integer.parseInt(args[2]) : 480,
                           args.length > 3 ? Integer.parseInt(args[3]) : 320);
        } catch (Throwable error) {
            error.printStackTrace(); NativeBridge.failed(error.toString());
        } finally {
            if (instance != null) instance.cleanup();
            // miniJVM exits its Java threads; this does not terminate the native iOS app.
            System.exit(0);
        }
    }

    public int runTab(int tabId, String jarPath, String rmsPath, int width, int height) {
        IOSRuntime runtime = new IOSRuntime(tabId);
        instance = runtime;
        try {
            runtime.start(jarPath, rmsPath, width, height);
            return 0;
        } catch (Throwable error) {
            error.printStackTrace();
            NativeBridge.failedTab(tabId, error.toString());
            return -1;
        } finally {
            runtime.cleanup();
        }
    }

    private void cleanup() {
        stopped = true;
        if (generation != 0) {
            if (!NativeBridge.releaseSession(generation)) throw new IllegalStateException("Session is still using resources");
            generation = 0;
        }
        if (stores != null) stores.closeAll();
        MIDletBridge.clear();
        if (loader != null) {
            loader.close();
            loader = null;
        }
    }

    private void setState(String next) {
        if ("STOPPING".equals(state) && !("STOPPED".equals(next) || "FAILED".equals(next) || "STOPPING".equals(next))) return;
        state = next;
        System.out.println("[SESSION] tab=" + tabId + " generation=" + generation + " state=" + next);
    }

    /** This host thread never executes code supplied by a game. */
    private void start(final String jarPath, final String rmsPath, final int width, final int height) throws Exception {
        generation = NativeBridge.beginSession(tabId);
        setState("ANALYZING");
        Thread worker = new Thread(new Runnable() {
            public void run() {
                NativeBridge.bindSession(generation);
                try { runGame(jarPath, rmsPath, width, height); }
                catch (Throwable error) {
                    workerError = error.getClass().getName();
                    running = false;
                    // Throwable methods can be overridden by a game. Keep even
                    // error reporting on the cancellable worker, never the host.
                    error.printStackTrace();
                }
            }
        }, "game-" + tabId);
        worker.start();
        while (running && !NativeBridge.stopRequested(tabId)) Thread.sleep(8);
        setState("STOPPING");
        NativeBridge.statusTab(tabId, "Stopping");
        running = false;
        // Give destroyApp a bounded chance to save state. All callbacks, including
        // constructor/start/destroy, remain on cancellable game-owned threads.
        long grace = System.currentTimeMillis() + 150;
        while (worker.isAlive() && System.currentTimeMillis() < grace) Thread.sleep(8);
        int active = NativeBridge.cancelSession(generation);
        long reportAt = System.currentTimeMillis() + 2000;
        while (active != 0 || worker.isAlive()) {
            Thread.sleep(20);
            active = NativeBridge.cancelSession(generation);
            if (System.currentTimeMillis() >= reportAt) {
                NativeBridge.statusTab(tabId, "Stopping: waiting for native operation");
                reportAt = System.currentTimeMillis() + 5000;
            }
        }
        cleanup();
        if (workerError != null) {
            setState("FAILED");
            throw new RuntimeException(workerError);
        }
        setState("STOPPED");
    }

    private void runGame(String jarPath, String rmsPath, int width, int height) throws Exception {
        if (width < 128 || height < 128 || width > 1920 || height > 1920) throw new IllegalArgumentException("Invalid virtual resolution");
        File jarFile = new File(jarPath);
        if (!jarFile.exists() || jarFile.length() == 0) {
            throw new IOException("JAR file is missing or empty: " + jarPath);
        }
        loader = new IOSClassLoader(jarFile, IOSRuntime.class.getClassLoader());
        setState("LOADING");
        JarAnalyzer analysis = JarAnalyzer.analyze(jarFile, new File(rmsPath));
        properties.putAll(analysis.properties);
        String className = analysis.entryClass;
        if (className == null) {
            String mainClass = getAppProperty("Main-Class");
            if (mainClass != null && mainClass.trim().length() > 0) {
                throw new IOException("Tệp JAR này là ứng dụng Java SE máy tính (Main-Class: " + mainClass.trim() + "), không phải game Java ME MIDlet");
            }
            throw new IOException("JAR has no MIDlet manifest or runnable MIDlet class");
        }
        int[] viewport = CompatibilityProfile.select(analysis, new File(rmsPath), width, height);
        width = viewport[0]; height = viewport[1];
        MIDletBridge.setMicroEmulator(this);
        device = new IOSDevice(this, width, height);
        DeviceFactory.setDevice(device);
        EventDispatcher.maxFps = 30;
        stores = new IOSRecordStores(new File(rmsPath, suiteKey())); stores.init(this);
        File temporary = new File(rmsPath, "tmp"); temporary.mkdirs();
        if (System.getProperty("java.io.tmpdir") == null) System.setProperty("java.io.tmpdir", temporary.getAbsolutePath());
        System.setProperty("microedition.platform", "MicroEmu-iOS");
        System.setProperty("microedition.configuration", "CLDC-1.1");
        System.setProperty("microedition.profiles", "MIDP-2.0");
        System.setProperty("microedition.locale", "vi-VN");
        System.setProperty("microedition.encoding", "UTF-8");
        Thread.currentThread().setContextClassLoader(loader);
        MIDletBridge.setThreadMIDletContext(new MIDletContext());
        setState("STARTING");
        midlet = (MIDlet)loader.loadClass(className).newInstance();
        if (!running) return;
        MIDletBridge.setCurrentMIDlet(midlet);
        NativeBridge.statusTab(tabId, "Starting " + getSuiteName());
        midletAccess = MIDletBridge.getMIDletAccess(midlet);
        midletAccess.startApp();
        setState("RUNNING");
        int[] event = new int[4];
        while (running) {
            if (input.isPending()) { input.advance(); Thread.sleep(4); }
            else if (NativeBridge.pollTab(tabId, event) != 0) dispatch(event);
            else Thread.sleep(sleeping ? 100 : 8);
        }
        MIDletAccess access = midletAccess;
        if (access != null) {
            if (!destroyed) access.destroyApp(true);
            if (access.getDisplayAccess() != null) access.getDisplayAccess().clean();
        }
    }

    private String suiteKey() throws Exception {
        // This digest is a filesystem namespace, not an authentication primitive.
        java.security.MessageDigest hash = java.security.MessageDigest.getInstance("SHA-1");
        String vendor = getAppProperty("MIDlet-Vendor");
        hash.update(((vendor == null ? "null" : vendor) + "\n" + getSuiteName()).getBytes("UTF-8"));
        byte[] digest = hash.digest();
        StringBuffer key = new StringBuffer();
        for (int i = 0; i < digest.length; i++) { int b = digest[i] & 255; if (b < 16) key.append('0'); key.append(Integer.toHexString(b)); }
        return key.toString();
    }

    private void dispatch(int[] event) throws Exception {
        MIDlet active = MIDletBridge.getActiveMIDlet();
        MIDletAccess access = active == null ? midletAccess : MIDletBridge.getMIDletAccess(active);
        if (access == null) access = midletAccess;
        DisplayAccess display = access == null ? null : access.getDisplayAccess();
        if (event[0] == 10) { System.out.println("[LIFECYCLE] Stop requested tab=" + tabId); running = false; return; }
        if (event[0] == 15) {
            boolean nextSleep = event[1] != 0;
            sleeping = nextSleep;
            EventDispatcher.maxFps = nextSleep ? 2 : 30;
            if (!nextSleep && display != null) {
                if (device != null) device.presentScreen();
                display.repaint();
            }
            return;
        }
        if (event[0] == 8) { if (display != null) display.hideNotify(); access.pauseApp(); return; }
        if (event[0] == 9) { access.startApp(); if (display != null) display.repaint(); return; }
        if (display == null) return;
        switch (event[0]) {
            case 1:
                if (event[1] == -5 && device.editFocusedField(display)) break;
                if ((event[1] == -6 || event[1] == -7) && IOSUI.softKey(display, event[1] == -6 ? 0 : 1)) break;
                Integer key = new Integer(event[1]);
                if (!heldKeys.contains(key)) heldKeys.addElement(key);
                display.keyPressed(event[1]); break;
            case 2:
                if (heldKeys.removeElement(new Integer(event[1]))) display.keyReleased(event[1]); break;
            case 3:
                if (heldKeys.contains(new Integer(event[1]))) display.keyRepeated(event[1]); break;
            case 4:
                pointerDown = true; pointerX = event[1]; pointerY = event[2];
                display.pointerPressed(pointerX, pointerY); break;
            case 5:
                pointerX = event[1]; pointerY = event[2];
                if (pointerDown) display.pointerDragged(pointerX, pointerY); break;
            case 6:
                if (pointerDown) display.pointerReleased(event[1], event[2]); pointerDown = false; break;
            case 7:
                String value = NativeBridge.takeTextTab(tabId);
                if (!device.commitFocusedField(display, event[1], value)) IOSUI.commit(display, event[1], value);
                break;
            case 12:
                String text = NativeBridge.takeTextTab(tabId);
                Displayable target = display.getCurrent();
                System.out.println("[INPUT] tab=" + tabId + " Text length=" + (text == null ? -1 : text.length()) + " screen=" + (target == null ? "null" : target.getClass().getName()));
                if (target instanceof TextBox) IOSUI.commit(display, -1, text);
                else input.text(display, text);
                break;
            case 13:
                if (event[1] == -5 && device.editFocusedField(display)) break;
                if ((event[1] == -6 || event[1] == -7) && IOSUI.softKey(display, event[1] == -6 ? 0 : 1)) break;
                input.tap(display, event[1]);
                break;
            case 16:
                input.cancel();
                for (int i = 0; i < heldKeys.size(); i++) display.keyReleased(((Integer)heldKeys.elementAt(i)).intValue());
                heldKeys.removeAllElements();
                if (pointerDown) display.pointerReleased(pointerX, pointerY);
                pointerDown = false;
                break;
        }
    }
    public RecordStoreManager getRecordStoreManager() { return stores; }
    public Launcher getLauncher() { return null; }
    public String getAppProperty(String key) {
        if (key == null) return null;
        String val = (String) properties.get(key);
        if (val == null) {
            val = (String) properties.get(key.toLowerCase());
        }
        return val;
    }
    public InputStream getResourceAsStream(Class originalClass, String name) {
        if (name.startsWith("/")) name = name.substring(1);
        else if (originalClass != null && !originalClass.getName().startsWith("org.microemu.")) {
            String original = originalClass.getName(); int dot = original.lastIndexOf('.');
            if (dot >= 0) name = original.substring(0, dot).replace('.', '/') + "/" + name;
        }
        return loader.getResourceAsStream(name);
    }
    public void notifyDestroyed(MIDletContext context) {
        if (context != null && (context.getMIDlet() == midlet || (midlet == null && context == MIDletBridge.getMIDletContext()))) {
            destroyed = true; running = false;
        }
    }
    public void destroyMIDletContext(MIDletContext context) { }
    public int checkPermission(String permission) { return 1; }
    public boolean platformRequest(String url) { NativeBridge.browse(url); return false; }
    public String getSuiteName() { String name = getAppProperty("MIDlet-Name"); return name == null ? "MIDlet" : name; }
}
