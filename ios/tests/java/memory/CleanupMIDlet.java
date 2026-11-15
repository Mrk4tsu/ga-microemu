package memory;
import javax.microedition.midlet.MIDlet;
import javax.microedition.lcdui.*;
import org.microemu.ios.NativeBridge;

public final class CleanupMIDlet extends MIDlet {
    private byte[][] live;
    private void makeGarbage() {
        byte[][] discarded=new byte[24][];
        for(int i=0;i<discarded.length;i++){discarded[i]=new byte[1024*1024];discarded[i][0]=(byte)i;}
    }
    public void startApp() {
        Display.getDisplay(this).setCurrent(new Canvas(){
            protected void paint(Graphics g){g.setColor(0x123456);g.fillRect(0,0,getWidth(),getHeight());}
            protected void keyPressed(int key){
                if(key!='v')return;
                for(int i=0;i<live.length;i++)if(live[i][0]!=(byte)(i+1) || live[i][live[i].length-1]!=(byte)(i+1)){
                    System.out.println("CLEANUP_LIVE_FAIL");notifyDestroyed();return;
                }
                System.out.println("CLEANUP_LIVE_PASS bytes=8388608");NativeBridge.status("SESSION_ARM");
            }
        });
        new Thread(new Runnable(){public void run(){
            live=new byte[8][];
            for(int i=0;i<live.length;i++){live[i]=new byte[1024*1024];live[i][0]=live[i][live[i].length-1]=(byte)(i+1);}
            makeGarbage();NativeBridge.status("CLEANUP_READY");
        }}).start();
    }
    public void pauseApp(){}
    public void destroyApp(boolean force){}
}
