package org.microemu.ios;

import java.io.*;
import java.util.*;
import java.util.jar.*;

/** ZIP/class metadata only: analysis never loads or initializes game classes. */
final class JarAnalyzer {
    static final int SCHEMA_VERSION = 1;
    final Map properties = new HashMap();
    String entryClass, sha256;
    int classCount, maxClassVersion;

    static JarAnalyzer analyze(File file, File dataDirectory) throws Exception {
        JarAnalyzer result = new JarAnalyzer();
        result.sha256 = NativeBridge.sha256File(file.getAbsolutePath());
        if (result.sha256 == null) throw new IOException("Cannot fingerprint JAR");
        String name = file.getName(); int dot = name.lastIndexOf('.');
        String base = dot > 0 ? name.substring(0, dot) : name;
        boolean sidecar = new File(file.getParent(), base + ".jad").isFile() || new File(file.getParent(), base + ".JAD").isFile();
        File cache = new File(new File(dataDirectory, "analysis"), result.sha256 + "-v" + SCHEMA_VERSION + "-" + CompatibilityProfile.RUNTIME_VERSION + ".properties");
        if (!sidecar && result.readCache(cache)) { result.log("hit"); return result; }
        JarFile archive = new JarFile(file.getAbsolutePath());
        try {
            InputStream manifest = result.locateManifest(archive, file);
            if (manifest != null) result.readManifest(manifest);
            result.entryClass = result.resolveMainClassName(archive, file);
        } finally { archive.close(); }
        if (!sidecar) result.writeCache(cache);
        result.log("miss");
        return result;
    }
    private void log(String cache) {
        System.out.println("[ANALYZER] schema=" + SCHEMA_VERSION + " sha256=" + sha256
            + " classes=" + classCount + " major=" + maxClassVersion + " entry=" + entryClass + " cache=" + cache);
    }
    private boolean readCache(File file) {
        if (!file.isFile() || file.length() > 262144) return false;
        try {
            Properties values = new Properties(); InputStream in = new FileInputStream(file);
            try { values.load(in); } finally { in.close(); }
            if (!sha256.equals(values.getProperty("sha256")) || !Integer.toString(SCHEMA_VERSION).equals(values.getProperty("schema"))
                || !CompatibilityProfile.RUNTIME_VERSION.equals(values.getProperty("runtime"))) return false;
            String entry = values.getProperty("entry");
            int count = Integer.parseInt(values.getProperty("classes")), major = Integer.parseInt(values.getProperty("major"));
            if (entry == null || entry.length() == 0 || count < 1 || major < 45) return false;
            Enumeration names = values.propertyNames();
            while (names.hasMoreElements()) {
                String key = (String)names.nextElement();
                if (key.startsWith("manifest.")) putProperty(key.substring(9), values.getProperty(key));
            }
            entryClass = entry; classCount = count; maxClassVersion = major; return true;
        } catch (IOException ignored) { return false; }
          catch (RuntimeException ignored) { properties.clear(); return false; }
    }
    private void writeCache(File file) {
        if (entryClass == null) return;
        try {
            Properties values = new Properties();
            values.setProperty("schema", Integer.toString(SCHEMA_VERSION)); values.setProperty("runtime", CompatibilityProfile.RUNTIME_VERSION);
            values.setProperty("sha256", sha256); values.setProperty("entry", entryClass);
            values.setProperty("classes", Integer.toString(classCount)); values.setProperty("major", Integer.toString(maxClassVersion));
            for (Iterator i = properties.entrySet().iterator(); i.hasNext();) {
                Map.Entry entry = (Map.Entry)i.next(); values.setProperty("manifest." + entry.getKey(), (String)entry.getValue());
            }
            file.getParentFile().mkdirs(); File temporary = new File(file.getPath() + ".tmp");
            OutputStream out = new FileOutputStream(temporary);
            try { values.store(out, "MicroEmu analysis cache"); } finally { out.close(); }
            if (!temporary.renameTo(file)) temporary.delete();
        } catch (IOException ignored) { /* A cache failure must never prevent boot. */ }
    }
    private static Vector entries(JarFile archive) {
        Vector all = new Vector(); Enumeration e = archive.entries();
        while (e.hasMoreElements()) {
            all.addElement(e.nextElement());
        }
        return all;
    }
    String getAppProperty(String key) { return (String)properties.get(key.toLowerCase()); }
    private InputStream locateManifest(JarFile archive, File jarFile) {
        Vector all = entries(archive);
        for (int pass = 0; pass < 2; pass++) for (int i = 0; i < all.size(); i++) {
            JarEntry entry = (JarEntry)all.elementAt(i);
            String name = entry.getName().replace('\\', '/').toLowerCase();
            if ((pass == 0 && name.endsWith("manifest.mf")) || (pass == 1 && name.endsWith(".jad"))) {
                try { return archive.getInputStream(entry); } catch (IOException ignored) { }
            }
        }

        try {
            String parent = jarFile.getParent();
            String name = jarFile.getName();
            int dot = name.lastIndexOf('.');
            String base = dot > 0 ? name.substring(0, dot) : name;
            File jad = new File(parent, base + ".jad");
            if (jad.exists() && jad.length() > 0) {
                return new FileInputStream(jad);
            }
            File jadUpper = new File(parent, base + ".JAD");
            if (jadUpper.exists() && jadUpper.length() > 0) {
                return new FileInputStream(jadUpper);
            }
        } catch (Throwable ignored) { }

        return null;
    }

    private String resolveMainClassName(JarFile archive, File jarFile) {
        String autoClass = scanForMidletClass(archive);
        for (int i = 1; i <= 9; i++) {
            String entry = getAppProperty("MIDlet-" + i);
            if (entry != null && entry.trim().length() > 0) {
                entry = entry.trim();
                int comma = entry.lastIndexOf(',');
                String cls = comma >= 0 ? entry.substring(comma + 1).trim() : entry;
                if (cls.length() > 0) return cls;
            }
        }

        if (autoClass != null) {
            String suite = getAppProperty("MIDlet-Name");
            if (suite == null) {
                String fname = jarFile.getName();
                int dot = fname.lastIndexOf('.');
                String base = dot > 0 ? fname.substring(0, dot) : fname;
                putProperty("MIDlet-Name", base);
                putProperty("MIDlet-Vendor", "Auto");
                putProperty("MIDlet-Version", "1.0");
                putProperty("MIDlet-1", base + ",," + autoClass);
            }
            return autoClass;
        }

        return null;
    }

    private String scanForMidletClass(JarFile archive) {
        Vector entries = entries(archive), candidates = new Vector();
        Hashtable parents = new Hashtable();
        for (int i = 0; i < entries.size(); i++) {
            java.util.jar.JarEntry entry = (java.util.jar.JarEntry) entries.elementAt(i);
            String name = entry.getName();
            if (!name.endsWith(".class")) continue;
            try {
                InputStream in = archive.getInputStream(entry);
                if (in == null) continue;
                byte[] data;
                try {
                    ByteArrayOutputStream out = new ByteArrayOutputStream();
                    byte[] buf = new byte[2048]; int n;
                    while ((n = in.read(buf)) != -1) if (n > 0) out.write(buf, 0, n);
                    data = out.toByteArray();
                } finally { in.close(); }
                String[] parsed = parseClassHeader(data);
                if (parsed != null) {
                    classCount++;
                    int major = ((data[6] & 255) << 8) | (data[7] & 255);
                    maxClassVersion = Math.max(maxClassVersion, major);
                    parents.put(parsed[0], parsed[1]);
                    int flags = Integer.parseInt(parsed[2]);
                    if ((flags & 0x0601) == 1 && !name.startsWith("org/microemu/") && !name.startsWith("javax/"))
                        candidates.addElement(parsed[0]);
                }
            } catch (IOException ignored) {
            } catch (RuntimeException ignored) { }
        }
        for (int i = 0; i < candidates.size(); i++) {
            String candidate = (String)candidates.elementAt(i), parent = candidate;
            for (int depth = 0; parent != null && depth <= parents.size(); depth++) {
                if ("javax/microedition/midlet/MIDlet".equals(parent)) return candidate.replace('/', '.');
                parent = (String)parents.get(parent);
            }
        }
        return null;
    }

    private static String[] parseClassHeader(byte[] data) {
        if (data == null || data.length < 16) return null;
        if ((data[0] & 0xFF) != 0xCA || (data[1] & 0xFF) != 0xFE || (data[2] & 0xFF) != 0xBA || (data[3] & 0xFF) != 0xBE) {
            return null;
        }
        int count = ((data[8] & 0xFF) << 8) | (data[9] & 0xFF);
        Object[] pool = new Object[count];
        int offset = 10;
        int index = 1;
        while (index < count && offset < data.length) {
            int tag = data[offset++] & 0xFF;
            if (tag == 1) {
                if (offset + 2 > data.length) return null;
                int len = ((data[offset] & 0xFF) << 8) | (data[offset + 1] & 0xFF);
                offset += 2;
                if (offset + len > data.length) return null;
                try {
                    pool[index] = new String(data, offset, len, "UTF-8");
                } catch (Exception e) {
                    pool[index] = "";
                }
                offset += len;
            } else if (tag == 3 || tag == 4) {
                offset += 4;
            } else if (tag == 5 || tag == 6) {
                offset += 8;
                index++;
            } else if (tag == 7) {
                if (offset + 2 > data.length) return null;
                int nameIdx = ((data[offset] & 0xFF) << 8) | (data[offset + 1] & 0xFF);
                offset += 2;
                pool[index] = new Integer(nameIdx);
            } else if (tag == 8 || tag == 16 || tag == 19 || tag == 20) {
                offset += 2;
            } else if (tag == 9 || tag == 10 || tag == 11 || tag == 12 || tag == 17 || tag == 18) {
                offset += 4;
            } else if (tag == 15) {
                offset += 3;
            } else {
                return null;
            }
            index++;
        }
        if (offset + 6 > data.length) return null;
        int accessFlags = ((data[offset] & 0xFF) << 8) | (data[offset + 1] & 0xFF);
        offset += 2;
        int thisClassIdx = ((data[offset] & 0xFF) << 8) | (data[offset + 1] & 0xFF);
        offset += 2;
        int superClassIdx = ((data[offset] & 0xFF) << 8) | (data[offset + 1] & 0xFF);

        String thisClassName = resolveClassName(pool, thisClassIdx);
        String superClassName = resolveClassName(pool, superClassIdx);
        if (thisClassName != null && superClassName != null) {
            return new String[] { thisClassName, superClassName, Integer.toString(accessFlags) };
        }
        return null;
    }

    private static String resolveClassName(Object[] pool, int classIndex) {
        if (classIndex <= 0 || classIndex >= pool.length) return null;
        Object entry = pool[classIndex];
        if (entry instanceof Integer) {
            int nameIdx = ((Integer) entry).intValue();
            if (nameIdx > 0 && nameIdx < pool.length && pool[nameIdx] instanceof String) {
                return (String) pool[nameIdx];
            }
        }
        return null;
    }

    private void readManifest(InputStream in) throws IOException {
        BufferedReader reader = new BufferedReader(new InputStreamReader(in, "UTF-8"));
        String line, key = null; StringBuffer value = new StringBuffer();
        boolean firstLine = true;
        try {
            while ((line = reader.readLine()) != null) {
                if (firstLine) {
                    firstLine = false;
                    if (line.length() > 0 && line.charAt(0) == '\uFEFF') {
                        line = line.substring(1);
                    }
                }
                // Be tolerant of CRCRLF generated by old MIDlet build tools.
                if (line.length() == 0) continue;
                if (line.charAt(0) == ' ' && key != null) { value.append(line.substring(1)); continue; }
                if (key != null) putProperty(key, value.toString());
                int colon = line.indexOf(':');
                key = colon > 0 ? line.substring(0, colon).trim() : null;
                value = new StringBuffer(colon > 0 ? line.substring(colon + 1).trim() : "");
            }
            if (key != null) putProperty(key, value.toString());
        } finally { reader.close(); }
    }

    private void putProperty(String key, String val) {
        if (key == null) return;
        properties.put(key, val);
        properties.put(key.toLowerCase(), val);
    }

}
