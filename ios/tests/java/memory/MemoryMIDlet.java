package memory;

import java.io.*;
import javax.microedition.midlet.MIDlet;
import javax.microedition.lcdui.*;
import org.microemu.ios.NativeBridge;

/** Real loader pressure: resource buffers must not stay live after streams close. */
public final class MemoryMIDlet extends MIDlet {
    private InputStream[] abandoned;
    private static void require(boolean condition,String message) throws IOException { if(!condition)throw new IOException(message); }
    private static long used() { Runtime rt=Runtime.getRuntime();return rt.totalMemory()-rt.freeMemory(); }
    private static long settled() throws Exception {
        long minimum=Long.MAX_VALUE;
        for(int i=0;i<6;i++) { System.gc();Thread.sleep(160);minimum=Math.min(minimum,used()); }
        return minimum;
    }
    private void readAsset(int index) throws Exception {
        InputStream input=getClass().getResourceAsStream("/bulk/asset"+index+".bin");
        if(input==null)throw new IOException("Missing asset "+index);
        try {
            byte[] buffer=new byte[16384];int count,total=0;
            while((count=input.read(buffer))!=-1) {
                if(count>0 && ((buffer[0]&255)!=index || (buffer[count-1]&255)!=index))throw new IOException("Corrupt asset");
                total+=count;
            }
            if(total!=1024*1024)throw new IOException("Truncated resource");
        } finally { input.close(); }
    }
    private void streams() throws Exception {
        long before=settled();
        InputStream first=getClass().getResourceAsStream("/bulk/asset0.bin"),second=getClass().getResourceAsStream("/bulk/asset0.bin");
        require(first!=null && second!=null,"Open independent readers");
        try {
            long delta=settled()-before;
            System.out.println("STREAM_MEMORY open_delta="+delta);
            require(delta<512*1024,"Opening streams eagerly allocated the resource payloads");
            require(first.available()==1024*1024 && first.read()==0,"Initial available/read");
            first.mark(Integer.MAX_VALUE);
            require(first.skip(1024*1024L-2)==1024*1024L-2 && first.read()==0 && first.read()==-1,"Skip and EOF");
            first.reset();require(first.available()==1024*1024-1 && first.read()==0,"Reset beyond read-ahead buffer");
            require(second.read()==0 && second.available()==1024*1024-1,"Independent stream positions");
            require(second.read(new byte[0],0,0)==0 && second.skip(-1)==0,"Zero-length and negative skip");
            try { second.read(new byte[2],2,1);throw new IOException("Accepted bad bounds"); }
            catch(IndexOutOfBoundsException expected) { }
        } finally { first.close();second.close(); }
        first.close();
        boolean closed=false;try { first.read(); } catch(IOException expected) { closed=true; }
        require(closed,"Read after close accepted");
        InputStream single=getClass().getResourceAsStream("/bulk/asset1.bin");
        try {
            byte[] all=new byte[single.available()];
            require(single.read(all)==all.length && all[0]==1 && all[all.length-1]==1,"Legacy single-read resource contract");
        } finally { single.close(); }
        InputStream empty=getClass().getResourceAsStream("/bulk/empty.bin");
        try { require(empty.read()==-1 && empty.available()==0,"Empty archive entry"); } finally { empty.close(); }
        InputStream stored=getClass().getResourceAsStream("/bulk/stored.bin");
        try { int count=0,next;while((next=stored.read())!=-1) {require(next==90,"Stored bytes");count++;}require(count==16384,"Stored entry length"); }
        finally { stored.close(); }
        InputStream bad=getClass().getResourceAsStream("/bulk/corrupt.bin");boolean failed=false;
        try { byte[] data=new byte[8192];while(bad.read(data)!=-1) { } }
        catch(IOException expected) { failed=true; } finally { bad.close(); }
        require(failed,"Corrupt ZIP CRC was accepted");
        require(NativeBridge.archiveCount()==0,"Closed stream handles retained");
        System.out.println("STREAM_PASS");
    }
    public void startApp() {
        Display.getDisplay(this).setCurrent(new Canvas() { protected void paint(Graphics graphics) {
            graphics.setColor(0x234567);graphics.fillRect(0,0,getWidth(),getHeight());
        }});
        new Thread(new Runnable() { public void run() {
            try {
                String mode=getAppProperty("Test-Mode");
                if("streams".equals(mode)) { streams();NativeBridge.status("SESSION_ARM");return; }
                if("abandon".equals(mode)) {
                    abandoned=new InputStream[8];
                    for(int i=0;i<abandoned.length;i++)abandoned[i]=getClass().getResourceAsStream("/bulk/asset"+i+".bin");
                    require(NativeBridge.archiveCount()==8,"Abandoned stream registration");
                    System.out.println("ABANDONED_STREAMS_READY");NativeBridge.status("SESSION_ARM");return;
                }
                if("cancel-read".equals(mode)) {
                    Thread.currentThread().setContextClassLoader(null);
                    InputStream active=getClass().getResourceAsStream("/bulk/asset0.bin");
                    require(active!=null && active.read()==0,"Active ZIP reader started");settled();
                    require(NativeBridge.archiveCount()==1,"Reader owner survives CCL replacement and GC");
                    byte[] data=new byte[16384];System.out.println("ACTIVE_STREAM_READY");NativeBridge.status("SESSION_ARM");
                    for(;;) {if(active.read(data)==-1)active.reset();}
                }
                long before=settled();
                for(int i=0;i<24;i++)readAsset(i);
                long after=settled();
                System.out.println("MEMORY_RESULT before="+before+" after="+after+" retained="+(after-before)+" payload=25165824");
                NativeBridge.status("SESSION_ARM");
            } catch(Throwable error) { error.printStackTrace();System.out.println("MEMORY_FAIL");notifyDestroyed(); }
        }}).start();
    }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) { }
}
