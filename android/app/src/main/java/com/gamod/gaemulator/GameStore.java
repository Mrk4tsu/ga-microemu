package com.gamod.gaemulator;

import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.util.AtomicFile;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.*;
import java.security.MessageDigest;
import java.util.*;
import java.util.zip.ZipFile;

final class GameStore {
    static final class Game {
        final String hash, name, author; final File file;
        Game(String hash, String name, File file) { this.hash=hash; this.name=name; this.file=file;this.author=GameMetadata.author(file); }
        public String toString() { return name; }
    }
    private final Context context;
    private final File root;
    private final AtomicFile index;
    GameStore(Context context) throws IOException {
        this.context=context.getApplicationContext(); root=new File(context.getFilesDir(),"games");
        if (!root.isDirectory() && !root.mkdirs()) throw new IOException("Không tạo được thư viện game");
        index=new AtomicFile(new File(root,"library.json"));
    }
    synchronized List<Game> list() throws Exception {
        List<Game> games=new ArrayList<>();
        if (!index.getBaseFile().exists()) return games;
        JSONArray array=new JSONArray(new String(index.readFully(), java.nio.charset.StandardCharsets.UTF_8));
        for(int i=0;i<array.length();i++) {
            JSONObject item=array.getJSONObject(i); String hash=item.getString("hash");
            if(!hash.matches("[a-f0-9]{64}")) continue;
            File file=new File(root,hash+".jar"); if(file.isFile()) games.add(new Game(hash,item.getString("name"),file));
        }
        games.sort((a,b)->a.name.compareToIgnoreCase(b.name)); return games;
    }
    synchronized Game importJar(Uri uri) throws Exception {
        String name=uri.getLastPathSegment();
        try(Cursor cursor=context.getContentResolver().query(uri,new String[]{OpenableColumns.DISPLAY_NAME},null,null,null)) {
            if(cursor!=null && cursor.moveToFirst()) name=cursor.getString(0);
        } catch(RuntimeException ignored) { }
        if(name==null || !name.toLowerCase(Locale.ROOT).endsWith(".jar")) throw new IOException("Hãy chọn tệp game Java ME có đuôi .jar");
        name=new File(name.replace('\\','/')).getName();
        File temporary=File.createTempFile("import-",".tmp",root);
        try {
            MessageDigest hash=MessageDigest.getInstance("SHA-256"); long length=0;
            try(InputStream input=context.getContentResolver().openInputStream(uri); OutputStream output=new FileOutputStream(temporary)) {
                if(input==null) throw new IOException("Không đọc được tệp");
                byte[] block=new byte[65536]; int n;
                while((n=input.read(block))!=-1) {
                    length+=n; if(length>256L*1024*1024) throw new IOException("Tệp JAR vượt quá 256 MB");
                    hash.update(block,0,n); output.write(block,0,n);
                }
            }
            if(length==0) throw new IOException("Tệp JAR rỗng");
            try(ZipFile zip=new ZipFile(temporary)) {
                boolean classes=false; java.util.Enumeration<? extends java.util.zip.ZipEntry> entries=zip.entries();
                while(entries.hasMoreElements()) if(entries.nextElement().getName().endsWith(".class")) { classes=true; break; }
                if(!classes) throw new IOException("Tệp không chứa chương trình Java");
            }
            StringBuilder key=new StringBuilder(); for(byte b:hash.digest()) key.append(String.format(Locale.ROOT,"%02x",b&255));
            String id=key.toString(); List<Game> games=list();
            for(Game game:games) if(game.hash.equals(id)) return game;
            File target=new File(root,id+".jar");
            if(!target.isFile() && !temporary.renameTo(target)) throw new IOException("Không lưu được JAR");
            Game game=new Game(id,name,target); games.add(game); save(games); return game;
        } finally { temporary.delete(); }
    }
    private void save(List<Game> games) throws Exception {
        JSONArray array=new JSONArray();
        for(Game game:games) array.put(new JSONObject().put("hash",game.hash).put("name",game.name));
        FileOutputStream output=null;
        try { output=index.startWrite(); output.write(array.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)); index.finishWrite(output); }
        catch(Exception error) { if(output!=null) index.failWrite(output); throw error; }
    }
    File rms(Game game) throws IOException {
        File folder=new File(context.getFilesDir(),"rms/"+game.hash);
        if(!folder.isDirectory() && !folder.mkdirs()) throw new IOException("Không tạo được dữ liệu game"); return folder;
    }
}
