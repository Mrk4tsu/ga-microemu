package lifecycle;
import java.io.IOException;
import javax.microedition.lcdui.*;
import javax.microedition.midlet.MIDlet;

/** Reproduce an asset-loading thread taking the device lock while paint waits for the game lock. */
public final class RenderLockMIDlet extends MIDlet {
    private final Object gameLock = new Object();
    private volatile boolean loaderReady, paintEntered, imageDone, frameDone;
    public void startApp() {
        new Thread(new Runnable() {
            public void run() {
                synchronized (gameLock) {
                    loaderReady = true;
                    while (!paintEntered) {
                        try { Thread.sleep(5); } catch (InterruptedException error) { return; }
                    }
                    try { Image.createImage("/missing-login-texture.png"); }
                    catch (IOException expected) { }
                    imageDone = true;
                }
            }
        }, "login-assets").start();
        try { while (!loaderReady) Thread.sleep(5); } catch (InterruptedException error) { return; }
        Display.getDisplay(this).setCurrent(new Canvas() {
            protected void paint(Graphics graphics) {
                paintEntered = true;
                synchronized (gameLock) {
                    graphics.setColor(0x00aa44);
                    graphics.fillRect(0, 0, getWidth(), getHeight());
                    frameDone = true;
                }
            }
        });
        new Thread(new Runnable() {
            public void run() {
                long end = System.currentTimeMillis() + 2500;
                try {
                    while ((!imageDone || !frameDone) && System.currentTimeMillis() < end) Thread.sleep(5);
                    System.out.println(imageDone && frameDone ? "RENDER_LOCK_PASS" : "RENDER_LOCK_FAIL");
                } catch (InterruptedException error) { System.out.println("RENDER_LOCK_FAIL"); }
                notifyDestroyed();
            }
        }, "render-watchdog").start();
    }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) { }
}
