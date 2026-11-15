package com.gamod.gaemulator;

import android.content.Context;
import android.util.AtomicFile;
import java.io.*;
import java.security.MessageDigest;
import java.util.Arrays;

public final class RuntimeAssets {
    public final File bootstrap, emulator, log;
    private RuntimeAssets(File root) {
        bootstrap = new File(root, "minijvm_rt.jar"); emulator = new File(root, "microemu-ios.jar");
        log = new File(root.getParentFile(), "runtime.log");
    }
    public static synchronized RuntimeAssets install(Context context) throws Exception {
        File root = new File(context.getFilesDir(), "runtime");
        if (!root.isDirectory() && !root.mkdirs()) throw new IOException("Không tạo được thư mục runtime");
        for (String name : new String[]{"minijvm_rt.jar", "microemu-ios.jar"}) {
            ByteArrayOutputStream bytes = new ByteArrayOutputStream();
            try (InputStream input = context.getAssets().open("runtime/" + name)) {
                byte[] block = new byte[16384]; int n; while ((n = input.read(block)) != -1) bytes.write(block, 0, n);
            }
            byte[] data = bytes.toByteArray(); File target = new File(root, name);
            boolean identical = false;
            if (target.isFile() && target.length() == data.length) {
                MessageDigest hash = MessageDigest.getInstance("SHA-256");
                try (InputStream input = new FileInputStream(target)) { byte[] block = new byte[16384]; int n; while ((n=input.read(block))!=-1) hash.update(block,0,n); }
                identical = Arrays.equals(hash.digest(), MessageDigest.getInstance("SHA-256").digest(data));
            }
            if (!identical) {
                AtomicFile file = new AtomicFile(target); FileOutputStream output = null;
                try { output = file.startWrite(); output.write(data); file.finishWrite(output); }
                catch (IOException error) { if (output != null) file.failWrite(output); throw error; }
            }
        }
        return new RuntimeAssets(root);
    }
}
