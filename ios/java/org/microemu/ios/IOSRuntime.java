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
        if (loader != null) {
            loader.close();
            loader = null;
        }
    }

    private void start(String jarPath, String rmsPath, int width, int height) throws Exception {
        if (width < 128 || height < 128 || width > 1920 || height > 1920) throw new IllegalArgumentException("Invalid virtual resolution");
        loader = new IOSClassLoader(new File(jarPath), IOSRuntime.class.getClassLoader());
        InputStream manifest = loader.getResourceAsStream("META-INF/MANIFEST.MF");
        if (manifest == null) throw new IOException("JAR has no MIDlet manifest");
        readManifest(manifest);
        String entry = getAppProperty("MIDlet-1");
        if (entry == null || entry.lastIndexOf(',') < 0) throw new IOException("Missing MIDlet-1 entry");
        String className = entry.substring(entry.lastIndexOf(',') + 1).trim();
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
        midlet = (MIDlet)loader.loadClass(className).newInstance();
        MIDletBridge.setCurrentMIDlet(midlet);
        NativeBridge.statusTab(tabId, "Starting " + getSuiteName());
        midletAccess = MIDletBridge.getMIDletAccess(midlet);
        midletAccess.startApp();
        int[] event = new int[4];
        while (running) {
            if (NativeBridge.pollTab(tabId, event) != 0) dispatch(event);
            else Thread.sleep(sleeping ? 100 : 8);
        }
        stopped = true;
        MIDletAccess access = midletAccess;
        if (access != null) {
            if (!destroyed) access.destroyApp(true);
            if (access.getDisplayAccess() != null) access.getDisplayAccess().clean();
            Thread.sleep(100);
        }
    }
    private void readManifest(InputStream in) throws IOException {
        BufferedReader reader = new BufferedReader(new InputStreamReader(in, "UTF-8"));
        String line, key = null; StringBuffer value = new StringBuffer();
        try {
            while ((line = reader.readLine()) != null) {
                // Be tolerant of CRCRLF generated by old MIDlet build tools.
                if (line.length() == 0) continue;
                if (line.charAt(0) == ' ' && key != null) { value.append(line.substring(1)); continue; }
                if (key != null) properties.put(key, value.toString());
                int colon = line.indexOf(':');
                key = colon > 0 ? line.substring(0, colon) : null;
                value = new StringBuffer(colon > 0 ? line.substring(colon + 1).trim() : "");
            }
            if (key != null) properties.put(key, value.toString());
        } finally { reader.close(); }
    }
    private String suiteKey() throws Exception {
        // This digest is a filesystem namespace, not an authentication primitive.
        java.security.MessageDigest hash = java.security.MessageDigest.getInstance("SHA-1");
        hash.update((getAppProperty("MIDlet-Vendor") + "\n" + getSuiteName()).getBytes("UTF-8"));
        byte[] digest = hash.digest();
        StringBuffer key = new StringBuffer();
        for (int i = 0; i < digest.length; i++) { int b = digest[i] & 255; if (b < 16) key.append('0'); key.append(Integer.toHexString(b)); }
        return key.toString();
    }
    private void dispatch(int[] event) throws Exception {
        MIDletAccess access = midletAccess;
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
                if ((event[1] == -6 || event[1] == -7) && IOSUI.softKey(display, event[1] == -6 ? 0 : 1)) break;
                display.keyPressed(event[1]); break;
            case 2: display.keyReleased(event[1]); break;
            case 3: display.keyRepeated(event[1]); break;
            case 4: display.pointerPressed(event[1], event[2]); break;
            case 5: display.pointerDragged(event[1], event[2]); break;
            case 6: display.pointerReleased(event[1], event[2]); break;
            case 7: IOSUI.commit(display, event[1], NativeBridge.takeTextTab(tabId)); break;
            case 12:
                String text = NativeBridge.takeTextTab(tabId);
                Displayable target = display.getCurrent();
                System.out.println("[INPUT] tab=" + tabId + " Text length=" + (text == null ? -1 : text.length()) + " screen=" + (target == null ? "null" : target.getClass().getName()));
                if (text != null) for (int i = 0; i < text.length(); i++) {
                    display.keyPressed(text.charAt(i));
                    Thread.sleep(20);
                    display.keyReleased(text.charAt(i));
                    Thread.sleep(10);
                }
                break;
            case 13:
                if ((event[1] == -6 || event[1] == -7) && IOSUI.softKey(display, event[1] == -6 ? 0 : 1)) break;
                display.keyPressed(event[1]);
                Thread.sleep(40);
                display.keyReleased(event[1]);
                Thread.sleep(10);
                break;
        }
    }
    public RecordStoreManager getRecordStoreManager() { return stores; }
    public Launcher getLauncher() { return null; }
    public String getAppProperty(String key) { return (String)properties.get(key); }
    public InputStream getResourceAsStream(Class originalClass, String name) {
        if (name.startsWith("/")) name = name.substring(1);
        else if (originalClass != null && !originalClass.getName().startsWith("org.microemu.")) {
            String original = originalClass.getName(); int dot = original.lastIndexOf('.');
            if (dot >= 0) name = original.substring(0, dot).replace('.', '/') + "/" + name;
        }
        return loader.getResourceAsStream(name);
    }
    public void notifyDestroyed(MIDletContext context) { destroyed = true; running = false; }
    public void destroyMIDletContext(MIDletContext context) { }
    public int checkPermission(String permission) { return 1; }
    public boolean platformRequest(String url) { NativeBridge.browse(url); return false; }
    public String getSuiteName() { String name = getAppProperty("MIDlet-Name"); return name == null ? "MIDlet" : name; }
}
