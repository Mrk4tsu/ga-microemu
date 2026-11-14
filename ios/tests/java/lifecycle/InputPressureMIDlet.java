package lifecycle;
import javax.microedition.lcdui.*;
import javax.microedition.midlet.MIDlet;

/** Exercise native text ownership while the host polls and GC suspends other tabs. */
public final class InputPressureMIDlet extends MIDlet {
    private volatile int typed;
    private volatile boolean done;
    public void startApp() {
        final Canvas canvas = new Canvas() {
            protected void paint(Graphics graphics) {
                graphics.setColor(0x335522); graphics.fillRect(0, 0, getWidth(), getHeight());
            }
            protected void keyPressed(int code) { if (code == 'z') typed++; }
        };
        Display.getDisplay(this).setCurrent(canvas);
        new Thread(new Runnable() {
            public void run() {
                long end = System.currentTimeMillis() + 5000;
                while (!done && System.currentTimeMillis() < end) {
                    byte[] garbage = new byte[32768]; garbage[0] = 1;
                    System.gc(); canvas.repaint();
                    try { Thread.sleep(10); } catch (InterruptedException error) { break; }
                }
            }
        }, "text-gc-pressure").start();
        new Thread(new Runnable() {
            public void run() {
                long end = System.currentTimeMillis() + 5000;
                try { while (typed < 20 && System.currentTimeMillis() < end) Thread.sleep(10); }
                catch (InterruptedException error) { }
                done = true;
                System.out.println(typed >= 20 ? "INPUT_PRESSURE_PASS" : "INPUT_PRESSURE_FAIL");
                notifyDestroyed();
            }
        }, "text-input-watchdog").start();
    }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) { done = true; }
}
