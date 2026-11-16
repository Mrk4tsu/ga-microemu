package lifecycle;

import java.io.*;
import javax.microedition.io.*;
import javax.microedition.lcdui.*;
import javax.microedition.midlet.MIDlet;
import org.microemu.ios.NativeBridge;

/** Real paint logic and TCP progress through Home, audio interruption and return. */
public final class BackgroundMIDlet extends MIDlet {
    private volatile int starts, pauses, paints, exchanges;
    private volatile boolean paused, done;
    private int savedExchanges, savedPaints;
    public void startApp() {
        starts++;paused=false;
        if(starts!=1)return;
        final Canvas canvas=new Canvas() {
            protected void paint(Graphics g) {
                paints++;g.setColor(0x224466);g.fillRect(0,0,getWidth(),getHeight());
            }
            protected void keyPressed(int key) { checkpoint(key); }
        };
        Display.getDisplay(this).setCurrent(canvas);
        new Thread(new Runnable() { public void run() {
            try {
                SocketConnection connection=(SocketConnection)Connector.open("socket://127.0.0.1:"+getAppProperty("Test-Port"));
                InputStream in=connection.openInputStream();OutputStream out=connection.openOutputStream();
                boolean armed=false;
                while(!done) {
                    if(!paused) {
                        int value=exchanges&255;out.write(value);out.flush();
                        if(in.read()!=value)throw new IOException("TCP echo mismatch");
                        exchanges++;canvas.repaint();
                        if(!armed && paints>0) {
                            savedExchanges=exchanges;savedPaints=paints;armed=true;
                            NativeBridge.status("UI_ARM_SCHEDULE");
                        }
                    }
                    Thread.sleep(40);
                }
                // Leave handles registered until Stop reclaims the session.
            }catch(Exception error){System.out.println("BACKGROUND_FAIL "+error);notifyDestroyed();}
        }},"background-tcp").start();
    }
    private void checkpoint(int key) {
        int expectedStarts=key=='c'?2:key=='d'?3:1;
        int expectedPauses=key=='c'?1:key=='d'?2:0;
        if(starts!=expectedStarts || pauses!=expectedPauses || exchanges<=savedExchanges+2 || paints<=savedPaints) {
            System.out.println("BACKGROUND_FAIL key="+key+" starts="+starts+" pauses="+pauses+" tcp="+exchanges+" paints="+paints);
            notifyDestroyed();return;
        }
        savedExchanges=exchanges;savedPaints=paints;
        System.out.println("BACKGROUND_CHECK_"+(char)key+" tcp="+exchanges+" paints="+paints);
        if(key=='d')System.out.println("BACKGROUND_PASS");
    }
    public void pauseApp() { pauses++;paused=true; }
    public void destroyApp(boolean unconditional) { done=true; }
}
