package org.microemu.ios;

import java.io.*;
import java.util.Enumeration;
import java.util.Hashtable;
import java.util.Vector;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

/** Read bytecode and resources directly from the archive, tolerant of path separators and case. */
final class IOSClassLoader extends ClassLoader {
    private final JarFile archive;
    private final Hashtable exactEntries = new Hashtable();
    private final Hashtable lowerEntries = new Hashtable();
    private final Vector allEntries = new Vector();

    IOSClassLoader(File file, ClassLoader parent) throws IOException {
        super(parent);
        archive = new JarFile(file.getAbsolutePath());
        try {
            Enumeration en = archive.entries();
            if (en != null) {
                while (en.hasMoreElements()) {
                    JarEntry entry = (JarEntry) en.nextElement();
                    String raw = entry.getName();
                    allEntries.addElement(entry);
                    exactEntries.put(raw, entry);
                    String norm = normalize(raw);
                    if (!exactEntries.containsKey(norm)) {
                        exactEntries.put(norm, entry);
                    }
                    String lower = norm.toLowerCase();
                    if (!lowerEntries.containsKey(lower)) {
                        lowerEntries.put(lower, entry);
                    }
                }
            }
        } catch (Throwable ignored) { }
    }

    private static String normalize(String path) {
        if (path == null) return "";
        path = path.replace('\\', '/');
        while (path.startsWith("/")) path = path.substring(1);
        return path;
    }

    JarEntry findEntry(String name) {
        if (name == null) return null;
        String norm = normalize(name);
        JarEntry entry = (JarEntry) exactEntries.get(norm);
        if (entry != null) return entry;
        entry = (JarEntry) exactEntries.get(name);
        if (entry != null) return entry;
        entry = (JarEntry) lowerEntries.get(norm.toLowerCase());
        if (entry != null) return entry;
        try {
            return archive.getJarEntry(norm);
        } catch (Throwable ignored) {
            return null;
        }
    }

    int[] compatibleViewport(int width, int height) {
        boolean one = false, other = false;
        for (int i = 0; i < allEntries.size(); i++) {
            String name = normalize(((JarEntry)allEntries.elementAt(i)).getName()).toLowerCase();
            if (name.startsWith("x1/")) one = true;
            else if (name.startsWith("x2/") || name.startsWith("x3/") || name.startsWith("x4/")) other = true;
        }
        // Legacy packs containing only x1 assets may also encrypt their PNGs.
        // Let the game decode its originals by staying within the x1 pixel budget.
        // Preserve the screen aspect ratio; UIKit scales the completed framebuffer.
        if (one && !other && (long)width * height > 480L * 320) {
            double scale = Math.sqrt((480.0 * 320.0) / ((double)width * height));
            width = Math.max(128, (int)(width * scale));
            height = Math.max(128, (int)(height * scale));
            if ((long)width * height > 480L * 320) height = (480 * 320) / width;
            System.out.println("[JAR] x1-only assets: virtual resolution " + width + "x" + height);
        }
        return new int[]{width, height};
    }

    Vector getAllEntries() {
        return allEntries;
    }

    JarFile getArchive() {
        return archive;
    }

    protected Class findClass(String name) throws ClassNotFoundException {
        String path = name.replace('.', '/') + ".class";
        try {
            InputStream in = ownResource(path);
            if (in == null) throw new ClassNotFoundException(name);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try {
                byte[] buffer = new byte[4096];
                int count;
                while ((count = in.read(buffer)) != -1) {
                    if (count > 0) out.write(buffer, 0, count);
                }
            } finally {
                in.close();
            }
            byte[] bytes = LegacyBytecode.adapt(out.toByteArray());
            return defineClass(name, bytes, 0, bytes.length);
        } catch (IOException error) {
            throw new ClassNotFoundException(name + ": " + error);
        }
    }

    private InputStream ownResource(String name) {
        if (name == null) return null;
        try {
            JarEntry entry = findEntry(name);
            if (entry != null) {
                InputStream in = archive.getInputStream(entry);
                if (in != null) return in;
            }
            String norm = normalize(name);
            JarEntry direct = archive.getJarEntry(norm);
            if (direct != null) {
                return archive.getInputStream(direct);
            }
        } catch (Throwable ignored) { }
        return null;
    }

    public InputStream getResourceAsStream(String name) {
        InputStream in = ownResource(name);
        if (in != null) return in;
        return super.getResourceAsStream(name);
    }

    void close() {
        try { archive.close(); } catch (IOException ignored) { }
    }
}
