package com.gamod.gaemulator;

import java.io.*;
import java.nio.ByteBuffer;
import java.nio.charset.*;
import java.util.*;
import java.util.zip.*;

/** Reads presentation metadata without loading any game classes. */
final class GameMetadata {
    static String author(File file) {
        try(ZipFile zip=new ZipFile(file)) {
            Enumeration<? extends ZipEntry> entries=zip.entries();
            while(entries.hasMoreElements()) {
                ZipEntry entry=entries.nextElement(); String path=entry.getName().replace('\\','/');
                if(!path.equalsIgnoreCase("META-INF/MANIFEST.MF") && !path.equalsIgnoreCase("MANIFEST.MF"))continue;
                ByteArrayOutputStream bytes=new ByteArrayOutputStream();
                try(InputStream input=zip.getInputStream(entry)) {
                    byte[] block=new byte[4096]; int count;
                    while((count=input.read(block))!=-1) {
                        if(bytes.size()+count>128*1024)return "";
                        bytes.write(block,0,count);
                    }
                }
                byte[] data=bytes.toByteArray(); String text;
                try { text=StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(data)).toString(); }
                catch(CharacterCodingException error) { text=new String(data,StandardCharsets.ISO_8859_1); }
                return authorFromManifest(text);
            }
        } catch(IOException ignored) { }
        return "";
    }
    static String authorFromManifest(String text) {
        Map<String,String> headers=new HashMap<>(); String key=null;
        for(String line:text.replace("\uFEFF", "").replace("\r\n","\n").replace('\r','\n').split("\n")) {
            if(line.isEmpty())continue;
            if(line.startsWith(" ") && key!=null) { headers.put(key,headers.get(key)+line.substring(1)); continue; }
            int colon=line.indexOf(':'); key=colon>0?line.substring(0,colon).trim().toLowerCase(Locale.ROOT):null;
            if(key!=null)headers.put(key,line.substring(colon+1).trim());
        }
        for(String candidate:new String[]{"midlet-author","author","midlet-vendor"}) {
            String value=headers.get(candidate); if(value!=null && !value.trim().isEmpty())return value.trim();
        }
        return "";
    }
}
