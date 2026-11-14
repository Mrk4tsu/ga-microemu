package session;

import java.io.*;
import javax.microedition.midlet.MIDlet;
import javax.microedition.lcdui.*;
import org.microemu.ios.NativeBridge;

/** A game decrypts its x1 image itself; high-density raw data is absent. */
public final class FullScreenMIDlet extends MIDlet {
    public void startApp() {
        final boolean lazy="paint".equals(getAppProperty("Test-Mode"));
        final boolean late="late-paint".equals(getAppProperty("Test-Mode"));
        final boolean broken="unrecoverable".equals(getAppProperty("Test-Mode"));
        Canvas canvas = new Canvas() {
            private boolean armed;
            private boolean tested;
            protected void paint(Graphics g) {
                if(lazy && !armed)load((long)getWidth()*getHeight()>153600L?2:1);
                if(late && armed && !tested) { tested=true; load(2); }
                g.setColor(0x225577); g.fillRect(0,0,getWidth(),getHeight());
                if (!armed) { armed=true; NativeBridge.status("SESSION_ARM"); }
            }
        };
        int density = (long)canvas.getWidth()*canvas.getHeight()>153600L ? 2 : 1;
        if(!lazy && !late)load(broken?2:density);
        Display.getDisplay(this).setCurrent(canvas);
        if(late) {
            final Canvas target=canvas;
            new Thread(new Runnable() { public void run() {
                while(true) {
                    target.repaint(); target.serviceRepaints();
                    try { Thread.sleep(20); } catch(InterruptedException ignored) { }
                }
            }}).start();
        }
    }
    private void load(int density) {
        String path = "/x" + density + "/encoded.png";
        Image image = null;
        try {
            InputStream in = getClass().getResourceAsStream(path);
            if (in != null) {
                ByteArrayOutputStream bytes = new ByteArrayOutputStream(); int next;
                try { while ((next=in.read())!=-1) bytes.write(next ^ 0x5a); }
                finally { in.close(); }
                byte[] data = bytes.toByteArray(); image=Image.createImage(data,0,data.length);
            } else image=Image.createImage(path);
        } catch (Exception ignored) { }
        // Match games that swallow an image exception then dereference null.
        if(image.getWidth()!=2)throw new Error("Wrong decoded texture");
    }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) { }
}
