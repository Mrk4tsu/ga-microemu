package org.microemu.ios;

import java.io.*;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;

/** Read bytecode directly from the archive, including paths containing spaces. */
final class IOSClassLoader extends ClassLoader {
    private final JarFile archive;
    IOSClassLoader(File file, ClassLoader parent) throws IOException { super(parent); archive = new JarFile(file.getAbsolutePath()); }
    protected Class findClass(String name) throws ClassNotFoundException {
        String path = name.replace('.', '/') + ".class";
        try {
            InputStream in = ownResource(path);
            if (in == null) throw new ClassNotFoundException(name);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            try { byte[] buffer = new byte[4096]; int count; while ((count = in.read(buffer)) != -1) if (count > 0) out.write(buffer,0,count); }
            finally { in.close(); }
            byte[] bytes = out.toByteArray(); return defineClass(name,bytes,0,bytes.length);
        } catch(IOException error) { throw new ClassNotFoundException(name+": "+error); }
    }
    private InputStream ownResource(String name) throws IOException {
        while (name.startsWith("/")) name = name.substring(1);
        JarEntry entry = archive.getJarEntry(name); return entry == null ? null : archive.getInputStream(entry);
    }
    public InputStream getResourceAsStream(String name) {
        try { InputStream in = ownResource(name); return in != null ? in : super.getResourceAsStream(name); }
        catch(IOException error) { return null; }
    }
    void close() {
        try { archive.close(); } catch (IOException ignored) { }
    }
}
