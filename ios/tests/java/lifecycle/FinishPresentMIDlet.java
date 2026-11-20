package lifecycle;
import javax.microedition.lcdui.*;
import javax.microedition.midlet.MIDlet;

/** Keep one tab painting while the other reports completion to the host. */
public final class FinishPresentMIDlet extends MIDlet {
    private volatile boolean done, painted;
    public void startApp() {
        final Canvas canvas = new Canvas() {
            protected void paint(Graphics graphics) {
                graphics.setColor(0x335522);
                graphics.fillRect(0, 0, getWidth(), getHeight());
                painted = true;
            }
        };
        Display.getDisplay(this).setCurrent(canvas);
        new Thread(new Runnable() {
            public void run() {
                try {
                    while (!done) { canvas.repaint(); Thread.sleep(10); }
                } catch (InterruptedException expected) { }
            }
        }, "finish-present-painter").start();
        if (!"true".equals(getAppProperty("Test-Keep-Running"))) {
            new Thread(new Runnable() {
                public void run() {
                    try {
                        while (!painted) Thread.sleep(10);
                        Thread.sleep(150);
                    } catch (InterruptedException expected) { return; }
                    done = true;
                    notifyDestroyed();
                }
            }, "finish-present-finisher").start();
        }
    }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) { done = true; }
}
