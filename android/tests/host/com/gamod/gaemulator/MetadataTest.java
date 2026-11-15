package com.gamod.gaemulator;

import java.io.*;
import java.nio.charset.*;
import java.util.zip.*;

/** Runs the production metadata reader on a host JVM, with real archive entries. */
public final class MetadataTest {
    private static File archive(File root,String name,String path,byte[] data) throws IOException {
        File file=new File(root,name+".jar");
        try(ZipOutputStream zip=new ZipOutputStream(new FileOutputStream(file))) {
            zip.putNextEntry(new ZipEntry(path));zip.write(data);zip.closeEntry();
        }
        return file;
    }
    private static void require(boolean value,String message) { if(!value)throw new AssertionError(message); }
    public static void main(String[] args) throws Exception {
        File root=new File(args[0]);
        File folded=archive(root,"folded","meta-inf/manifest.mf",("\uFEFFMIDlet-Vendor: Vendor\r\r\nAuthor: Other\r\r\nMIDlet-Author: MrK\r\r\n 4tsu\r\r\n").getBytes(StandardCharsets.UTF_8));
        require(GameMetadata.author(folded).equals("MrK4tsu"),"BOM, case-insensitive path, continuation, author precedence");
        File latin=archive(root,"latin","MANIFEST.MF",("Author: \nmidlet-vendor: José\n").getBytes(StandardCharsets.ISO_8859_1));
        require(GameMetadata.author(latin).equals("José"),"Latin-1 and empty-author vendor fallback");
        File missing=archive(root,"missing","readme.txt",new byte[0]);
        require(GameMetadata.author(missing).isEmpty(),"Manifest-free games keep default subtitle");
        byte[] oversized=new byte[128*1024+1];
        File large=archive(root,"large","META-INF/MANIFEST.MF",oversized);
        require(GameMetadata.author(large).isEmpty(),"Untrusted metadata has a bounded read");
        require(GameMetadata.author(new File(root,"absent.jar")).isEmpty(),"Unreadable JAR is safe to list");
        System.out.println("PASS: Android production metadata reader (real ZIP, author priority, BOM/folding, Latin-1, no manifest, size limit)");
    }
}
