package org.microemu.ios;

import java.io.*;
import java.util.Properties;

/** Device choices only. Standard Java API fixes apply to every game. */
final class CompatibilityProfile {
    static final String RUNTIME_VERSION = "minijvm-76f904ea-microemu-1";
    static int[] select(JarAnalyzer jar, File dataDirectory, int width, int height) throws IOException {
        return select(jar, dataDirectory, width, height, false);
    }
    static int[] select(JarAnalyzer jar, File dataDirectory, int width, int height, boolean userSelected) throws IOException {
        Properties user = new Properties();
        File file = new File(new File(dataDirectory, "profiles"), jar.sha256 + ".properties");
        if (!userSelected && file.isFile()) {
            InputStream in = new FileInputStream(file);
            try { user.load(in); } finally { in.close(); }
        }
        // Fingerprint rules may be added here only after a corpus regression
        // demonstrates the device difference. Resource directory names are evidence
        // for analysis, never an instruction to resize the game's framebuffer.
        String viewport = user.getProperty("viewport", "requested");
        String source = userSelected ? "user-selection" : file.isFile() ? "user" : "default";
        String w = user.getProperty("width"), h = user.getProperty("height");
        if (w != null || h != null) {
            if (w == null || h == null) throw new IOException("Profile needs both width and height");
            try { width = Integer.parseInt(w); height = Integer.parseInt(h); }
            catch (NumberFormatException error) { throw new IOException("Invalid profile resolution"); }
        }
        if (!NativeBridge.validViewport(width, height))
            throw new IOException("Profile resolution must be between 128 and 1920");
        if ("legacy-x1-budget".equals(viewport)) {
            int[] scaled = NativeBridge.fallbackViewport(width, height); width = scaled[0]; height = scaled[1];
        } else if (!"requested".equals(viewport)) throw new IOException("Unknown viewport profile: " + viewport);
        System.out.println("[PROFILE] schema=" + JarAnalyzer.SCHEMA_VERSION + " runtime=" + RUNTIME_VERSION
            + " sha256=" + jar.sha256 + " source=" + source + " viewport=" + viewport + " size=" + width + "x" + height);
        return new int[]{width, height};
    }
}
