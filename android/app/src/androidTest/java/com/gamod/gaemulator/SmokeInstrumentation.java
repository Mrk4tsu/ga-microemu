package com.gamod.gaemulator;

import android.app.*;
import android.content.Context;
import android.os.Bundle;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.ConcurrentHashMap;

/** No AndroidX dependency; am instrument executes the actual packaged JNI library. */
public final class SmokeInstrumentation extends Instrumentation implements NativeEngine.Listener {
    private final ConcurrentHashMap<Integer,Integer> finished=new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Integer,Boolean> accepted=new ConcurrentHashMap<>();
    private final ConcurrentHashMap<Integer,String> statuses=new ConcurrentHashMap<>();
    private volatile Throwable callbackFailure;
    private ServerSocket server;
    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
    @Override public void onStart() {
        Bundle report=new Bundle(); Thread runtime=null;
        try {
            Context target=getTargetContext();
            RuntimeAssets assets=RuntimeAssets.install(target);
            server=new ServerSocket(41041,16,InetAddress.getByName("127.0.0.1"));
            Thread accept=new Thread(()->{ while(!server.isClosed()) try {
                Socket socket=server.accept(); Thread handler=new Thread(()->serve(socket)); handler.setDaemon(true); handler.start();
            } catch(IOException ignored) { } },"android-smoke-server"); accept.setDaemon(true); accept.start();
            NativeEngine.listen(this); runtime=NativeEngine.startHost(assets,1024L*1024*1024);
            File directory=new File(target.getCacheDir(),"instrumentation-"+System.nanoTime());
            require(directory.mkdirs(),"Create test directory");
            File smoke=copy("smoke.jar",directory), idle=copy("idle-socket.jar",directory);
            verifySettingsAndMetadata(target,smoke);
            File rms=new File(directory,"rms"); require(rms.mkdirs(),"Create RMS");
            for(int tab=1;tab<=2;tab++) {
                NativeEngine.openTab(tab,smoke.getPath(),rms.getPath(),320,400);
                int[] frame=waitFrame(tab);
                require(frame[0]==320 && frame[1]==400,"Framebuffer dimensions");
                assertTextUpright(frame);
                NativeEngine.event(tab,4,50,100,null); Thread.sleep(100); NativeEngine.event(tab,6,50,100,null);
                waitFinished(tab);
                require(accepted.containsKey(tab),"TextBox callback returned input");
            }
            String log=read(assets.log);
            require(log.contains("ANDROID_RMS_COUNT=1") && log.contains("ANDROID_RMS_COUNT=2"),"RMS persisted across tabs");
            require(log.contains("ANDROID_SMOKE_PASS") && !log.contains("ANDROID_SMOKE_FAIL"),"TCP/HTTP/input/repaint fixture");
            NativeEngine.openTab(3,idle.getPath(),new File(directory,"idle-rms").getPath(),320,400);
            long deadline=System.currentTimeMillis()+8000;
            while(!read(assets.log).contains("SOCKET_READER_READY") && System.currentTimeMillis()<deadline) Thread.sleep(30);
            require(read(assets.log).contains("SOCKET_READER_READY"),"Idle socket reader started");
            NativeEngine.closeTab(3); waitFinished(3);
            requireEmpty(3);
            File full=copy("full-screen.jar",directory);
            NativeEngine.openTab(4,full.getPath(),new File(directory,"full-rms").getPath(),428,541,true);
            int[] scaled=waitFrame(4);
            require(scaled[0]==348 && scaled[1]==440,"Full screen recovered encrypted x1 assets");
            NativeEngine.closeTab(4);waitFinished(4);requireEmpty(4);
            require(read(assets.log).contains("retry-render=348x440 upscale-to=428x541"),"Full screen retry diagnostic");
            File peer=copy("peer.jar",directory),blocked=copy("blocked.jar",directory);
            NativeEngine.openTab(5,peer.getPath(),new File(directory,"peer-rms").getPath(),320,400);
            waitFrame(5);long peerGeneration=NativeEngine.resources(5)[0];
            NativeEngine.openTab(6,blocked.getPath(),new File(directory,"blocked-rms").getPath(),320,400);
            deadline=System.currentTimeMillis()+20000;
            while(!"SESSION_ARM".equals(statuses.get(6)) && System.currentTimeMillis()<deadline)Thread.sleep(30);
            require("SESSION_ARM".equals(statuses.get(6)),"Blocked startApp reached");
            NativeEngine.closeTab(6);waitFinished(6);requireEmpty(6);
            NativeEngine.sleepTab(5,false);waitFrame(5);
            require(NativeEngine.resources(5)[0]==peerGeneration,"Stop kept the neighbouring session alive");
            NativeEngine.closeTab(5);waitFinished(5);requireEmpty(5);
            NativeEngine.shutdown(); runtime.join(8000);
            require(!runtime.isAlive(),"Interpreter shutdown with idle socket");
            if(callbackFailure!=null) throw new AssertionError("Platform callback",callbackFailure);
            report.putString("stream","GA_ANDROID_INSTRUMENTATION_PASS\n");
            finish(Activity.RESULT_OK,report);
        } catch(Throwable error) {
            report.putString("stream","GA_ANDROID_INSTRUMENTATION_FAIL\n"+android.util.Log.getStackTraceString(error));
            finish(Activity.RESULT_CANCELED,report);
        } finally {
            NativeEngine.listen(null); NativeEngine.shutdown();
            if(server!=null) try { server.close(); } catch(IOException ignored) { }
        }
    }
    private File copy(String asset,File directory) throws IOException {
        File file=new File(directory,asset);
        try(InputStream in=getContext().getAssets().open(asset); OutputStream out=new FileOutputStream(file)) {
            byte[] bytes=new byte[16384]; int n; while((n=in.read(bytes))!=-1) out.write(bytes,0,n);
        }
        return file;
    }
    private void verifySettingsAndMetadata(Context target,File jar) {
        GameStore.Game game=new GameStore.Game("instrumentation-settings","fixture.jar",jar);
        clearTestSettings(target);
        GameSettings settings=new GameSettings(target);
        require(settings.load(game)==null,"First launch requires setup");
        settings.save(game,new GameSettings.Choice(320,480,false));
        GameSettings.Choice saved=new GameSettings(target).load(game);
        require(saved!=null && saved.width==320 && saved.height==480 && !saved.full,"Next launch restores settings");
        settings.save(game,new GameSettings.Choice(240,320,true));
        require(new GameSettings(target).load(game).full,"Full screen choice persisted");
        try { settings.save(game,new GameSettings.Choice(1921,320,false));throw new AssertionError("Oversized screen accepted"); }
        catch(IllegalArgumentException expected) { }
        require(GameMetadata.authorFromManifest("MIDlet-Vendor: Vendor\r\nAuthor: Author\r\nMIDlet-Author: MrK\r\n 4tsu\r\n").equals("MrK4tsu"),"Explicit author precedence and folded lines");
        require(GameMetadata.authorFromManifest("Author: \nmidlet-vendor: MrK4tsu\n").equals("MrK4tsu"),"Vendor fallback and case-insensitive headers");
        require(GameMetadata.authorFromManifest("MIDlet-Name: No author\n").isEmpty(),"Missing author fallback");
        require(game.author.equals("GaEmulator"),"Read author from packaged JAR");
        clearTestSettings(target);
    }
    private void clearTestSettings(Context target) {
        target.getSharedPreferences("game-screens",Context.MODE_PRIVATE).edit().remove("instrumentation-settings.width")
            .remove("instrumentation-settings.height").remove("instrumentation-settings.full").commit();
    }
    private void requireEmpty(int tab) {
        long[] values=NativeEngine.resources(tab);
        require(values.length==5 && values[1]==0 && values[2]==0 && values[3]==0 && values[4]==0,"Session resources reclaimed for tab "+tab);
    }
    private void serve(Socket socket) {
        try(Socket client=socket) {
            client.setSoTimeout(15000); InputStream input=client.getInputStream(); OutputStream output=client.getOutputStream();
            int first=input.read(); if(first<0) return;
            if(first=='G') {
                StringBuilder header=new StringBuilder("G"); int b;
                while(header.length()<8192 && !header.toString().endsWith("\r\n\r\n") && (b=input.read())!=-1) header.append((char)b);
                output.write("HTTP/1.1 200 OK\r\nContent-Length: 7\r\nConnection: close\r\n\r\nHTTP_OK".getBytes(StandardCharsets.US_ASCII)); output.flush();
            } else {
                output.write(first); output.flush(); byte[] bytes=new byte[256]; int n;
                while((n=input.read(bytes))!=-1) { output.write(bytes,0,n); output.flush(); }
            }
        } catch(IOException ignored) { }
    }
    private int[] waitFrame(int tab) throws Exception {
        long end=System.currentTimeMillis()+20000;
        while(System.currentTimeMillis()<end) { int[] frame=NativeEngine.takeFrame(tab); if(frame!=null) return frame; Thread.sleep(30); }
        throw new AssertionError("No native frame for tab "+tab);
    }
    private void waitFinished(int tab) throws Exception {
        long end=System.currentTimeMillis()+10000;
        while(!finished.containsKey(tab) && System.currentTimeMillis()<end) Thread.sleep(30);
        require(finished.containsKey(tab) && finished.get(tab)==0,"Tab "+tab+" stopped successfully");
    }
    private void assertTextUpright(int[] frame) {
        int w=frame[0], top=1000,bottom=-1; int[] rows=new int[35];
        for(int y=10;y<45;y++) for(int x=10;x<40;x++)
            if((frame[2+y*w+x]&0xffffff)<0x808080) { rows[y-10]++; top=Math.min(top,y-10); bottom=Math.max(bottom,y-10); }
        require(bottom>top,"Android system font was rasterized");
        int band=Math.max(1,(bottom-top+1)/4), upper=0,lower=0;
        for(int y=0;y<band;y++) { upper+=rows[top+y]; lower+=rows[bottom-y]; }
        require(upper>lower,"Asymmetric F glyph is upright");
    }
    private String read(File file) throws IOException {
        try(InputStream input=new FileInputStream(file); ByteArrayOutputStream output=new ByteArrayOutputStream()) {
            byte[] bytes=new byte[8192]; int n; while((n=input.read(bytes))!=-1) output.write(bytes,0,n);
            return new String(output.toByteArray(),StandardCharsets.UTF_8);
        }
    }
    private static void require(boolean value,String message) { if(!value) throw new AssertionError(message); }
    @Override public void modal(int tab,String title,String value,int max,int constraints,String[] commands) {
        if(title!=null && max>0 && accepted.putIfAbsent(tab,Boolean.TRUE)==null) {
            if(!"Tài khoản".equals(title)) callbackFailure=new AssertionError("UTF-8 modal heading");
            NativeEngine.event(tab,7,0,0,"android-input");
        }
    }
    @Override public void status(int tab,String text) { statuses.put(tab,text); }
    @Override public void finished(int tab,int result) { finished.put(tab,result); }
    @Override public void browse(String url) { }
    @Override public void vibrate(int milliseconds) { }
}
