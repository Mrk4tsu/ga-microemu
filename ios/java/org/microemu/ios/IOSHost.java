package org.microemu.ios;

import java.io.*;
import java.lang.reflect.Array;
import java.util.*;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

/** Hosts multiple isolated MIDP emulator tabs inside a single miniJVM instance. */
public final class IOSHost {
    private static final int EVENT_OPEN_TAB = 100;
    private static final int EVENT_SHUTDOWN = 102;
    private static final Object BOOT_LOCK = new Object();

    static final class TabClassLoader extends ClassLoader {
        private final JarFile[] archives;
        private final Map loaded = new HashMap();

        TabClassLoader(File[] jarFiles, ClassLoader parent) throws IOException {
            super(parent);
            List opened = new ArrayList();
            try {
                for (int i = 0; i < jarFiles.length; i++) {
                    if (jarFiles[i].isFile()) opened.add(new JarFile(jarFiles[i].getAbsolutePath()));
                }
                archives = (JarFile[]) opened.toArray(new JarFile[opened.size()]);
            } catch (IOException error) {
                for (int i = 0; i < opened.size(); i++) {
                    try { ((JarFile) opened.get(i)).close(); } catch (IOException ignored) { }
                }
                throw error;
            }
        }

        private byte[] readEntry(String path) throws IOException {
            while (path.startsWith("/")) path = path.substring(1);
            for (int i = 0; i < archives.length; i++) {
                JarEntry entry = archives[i].getJarEntry(path);
                if (entry == null) continue;
                return ArchiveIO.read(archives[i],entry);
            }
            return null;
        }

        protected synchronized Class loadClass(String name, boolean resolve) throws ClassNotFoundException {
            Class existing = (Class) loaded.get(name);
            if (existing != null) return existing;
            if (name.startsWith("java.") || name.startsWith("sun.") || name.startsWith("org.mini.")
                    || name.equals("org.microemu.ios.NativeBridge")
                    || name.equals("org.microemu.ios.TabRunner")) {
                return super.loadClass(name, resolve);
            }
            try {
                byte[] bytes = readEntry(name.replace('.', '/') + ".class");
                if (bytes != null) {
                    Class defined = defineClass(name, bytes, 0, bytes.length);
                    loaded.put(name, defined);
                    if (resolve) resolveClass(defined);
                    return defined;
                }
            } catch (IOException error) {
                throw new ClassNotFoundException(name + ": " + error);
            }
            return super.loadClass(name, resolve);
        }

        public InputStream getResourceAsStream(String name) {
            try {
                while(name.startsWith("/"))name=name.substring(1);
                for(int i=0;i<archives.length;i++) {
                    JarEntry entry=archives[i].getJarEntry(name);
                    if(entry!=null)return ArchiveIO.open(archives[i],entry);
                }
            } catch (IOException ignored) {
            }
            return super.getResourceAsStream(name);
        }

        void close() {
            for (int i = 0; i < archives.length; i++) {
                try { archives[i].close(); } catch (IOException ignored) { }
            }
        }
    }

    public static void main(String[] args) {
        try {
            Array.newInstance(Object.class, 0);
            String classpath = args.length > 0 && args[0] != null && args[0].length() > 0
                    ? args[0]
                    : System.getProperty("java.class.path");
            if (classpath == null || classpath.length() == 0) throw new IllegalArgumentException("Missing emulator classpath");
            String[] parts = classpath.split(File.pathSeparator);
            List files = new ArrayList();
            for (int i = 0; i < parts.length; i++) {
                if (parts[i].length() > 0) files.add(new File(parts[i]));
            }
            final File[] emulatorJars = (File[]) files.toArray(new File[files.size()]);
            int[] event = new int[4];
            boolean running = true;
            while (running) {
                if (NativeBridge.pollTab(0, event) != 0) {
                    if (event[0] == EVENT_OPEN_TAB) {
                        final int tabId = event[1];
                        final int width = event[2];
                        final int height = event[3];
                        final String jarPath = NativeBridge.takeTabJar(tabId);
                        final String rmsPath = NativeBridge.takeTabRms(tabId);
                        startTab(emulatorJars, tabId, jarPath, rmsPath, width, height);
                    } else if (event[0] == EVENT_SHUTDOWN) {
                        running = false;
                    }
                } else {
                    Thread.sleep(20);
                }
            }
        } catch (Throwable error) {
            error.printStackTrace();
            NativeBridge.failed(error.toString());
        } finally {
            System.exit(0);
        }
    }

    private static void startTab(final File[] emulatorJars, final int tabId, final String jarPath,
                                 final String rmsPath, final int width, final int height) {
        Thread thread = new Thread(new Runnable() {
            public void run() {
                int result = -1;
                TabClassLoader cl = null;
                TabRunner runner = null;
                try {
                    if (jarPath == null || rmsPath == null) throw new IllegalArgumentException("Missing tab arguments");
                    final boolean fullScreen = NativeBridge.fullScreenTab(tabId);
                    int renderWidth = width, renderHeight = height;
                    for (int attempt = 0; attempt < 2; attempt++) {
                        if (attempt > 0 && NativeBridge.stopRequested(tabId)) { result = 0; break; }
                        synchronized (BOOT_LOCK) {
                            cl = new TabClassLoader(emulatorJars, IOSHost.class.getClassLoader());
                            Thread.currentThread().setContextClassLoader(cl);
                            runner = (TabRunner) cl.loadClass("org.microemu.ios.IOSRuntime").newInstance();
                        }
                        result = runner.runTab(tabId, jarPath, rmsPath, renderWidth, renderHeight);
                        cl.close(); cl = null; runner = null;
                        if (result != NativeBridge.RETRY_VIEWPORT) break;
                        if (!fullScreen || attempt != 0) { result = -1; break; }
                        if (NativeBridge.stopRequested(tabId)) { result = 0; break; }
                        int[] fallback = NativeBridge.fallbackViewport(width, height);
                        if (fallback[0] == renderWidth && fallback[1] == renderHeight) { result = -1; break; }
                        renderWidth = fallback[0]; renderHeight = fallback[1];
                        System.out.println("[FULLSCREEN] tab=" + tabId + " requested=" + width + "x" + height
                            + " retry-render=" + renderWidth + "x" + renderHeight + " upscale-to=" + width + "x" + height
                            + " reason=image-load-before-first-frame");
                        NativeBridge.statusTab(tabId, "Full screen: loading smaller images and scaling to fit");
                        NativeBridge.prepareViewportRetry(tabId);
                    }
                } catch (Throwable error) {
                    error.printStackTrace();
                    NativeBridge.failedTab(tabId, error.toString());
                    result = -1;
                } finally {
                    if (cl != null) cl.close();
                    NativeBridge.finishedTab(tabId, result);
                }
            }
        }, "tab-" + tabId);
        thread.start();
    }
}
