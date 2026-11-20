package lifecycle;
import javax.microedition.lcdui.*;
import javax.microedition.midlet.MIDlet;
import org.microemu.ios.NativeBridge;

/** Open account/password editors from a Canvas and repaint after both callbacks. */
public final class TextBoxMIDlet extends MIDlet implements CommandListener {
    private final Command ok = new Command("OK", Command.OK, 0);
    private Canvas canvas;
    private TextBox editor;
    private volatile int phase, resumedFrames;
    public void startApp() {
        canvas = new Canvas() {
            protected void paint(Graphics graphics) {
                graphics.setColor(phase == 2 ? 0x22aa44 : 0x2244aa);
                graphics.fillRect(0, 0, getWidth(), getHeight());
                if (phase == 2) resumedFrames++;
            }
            protected void pointerPressed(int x, int y) { if (editor == null) open(false); }
        };
        Display.getDisplay(this).setCurrent(canvas);
        NativeBridge.status("UI_ARM_SCHEDULE");
        new Thread(new Runnable() {
            public void run() {
                long end = System.currentTimeMillis() + 5000;
                try {
                    while (resumedFrames < 3 && System.currentTimeMillis() < end) {
                        canvas.repaint(); Thread.sleep(20);
                    }
                    if ("true".equals(getAppProperty("Test-Stop"))) return;
                    System.out.println(resumedFrames >= 3 ? "TEXTBOX_PASS" : "TEXTBOX_FAIL");
                    notifyDestroyed();
                } catch (InterruptedException expected) { }
            }
        }, "textbox-watchdog").start();
    }
    private void open(boolean password) {
        editor = new TextBox(password ? "Password" : "Account", "seed", 32,
                TextField.ANY | (password ? TextField.PASSWORD : 0));
        if (!"seed".equals(editor.getString()) || editor.getMaxSize() != 32)
            throw new RuntimeException("TextBox model initialization failed");
        editor.addCommand(ok); editor.setCommandListener(this);
        Display.getDisplay(this).setCurrent(editor);
        System.out.println("TEXTBOX_OPEN");
    }
    public void commandAction(Command command, Displayable current) {
        String expected = phase == 0 ? "inputtest" : "testpass";
        if (command != ok || current != editor || !expected.equals(editor.getString())) {
            System.out.println("TEXTBOX_FAIL"); notifyDestroyed(); return;
        }
        phase++;
        if (phase == 1) open(true);
        else Display.getDisplay(this).setCurrent(canvas);
    }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) { }
}
