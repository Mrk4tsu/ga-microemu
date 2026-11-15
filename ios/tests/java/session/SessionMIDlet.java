package session;

import javax.microedition.midlet.MIDlet;
import javax.microedition.lcdui.*;
import org.microemu.*;
import org.microemu.ios.NativeBridge;

/** Deliberately hostile lifecycle callbacks, executed by the real interpreter. */
public final class SessionMIDlet extends MIDlet {
    private Image[] images;
    private String mode() { return getAppProperty("Test-Mode"); }
    public SessionMIDlet() {
        if ("constructor".equals(mode())) block("constructor");
    }
    private static void block(String stage) {
        System.out.println("SESSION_BLOCK " + stage);
        NativeBridge.status("SESSION_ARM");
        for (;;) try { Thread.sleep(1000); } catch (Throwable ignored) { }
    }
    public void startApp() throws javax.microedition.midlet.MIDletStateChangeException {
        if ("failure".equals(mode())) throw new Error() {
            public String toString() { block("error-toString"); return "unreachable"; }
            public void printStackTrace() { block("error-print"); }
        };
        if ("exit".equals(mode())) { System.out.println("SESSION_EXIT"); System.exit(0); }
        if ("start".equals(mode())) block("start");
        if ("wait".equals(mode())) {
            Object monitor = new Object();
            synchronized (monitor) {
                System.out.println("SESSION_BLOCK wait"); NativeBridge.status("SESSION_ARM");
                for (;;) try { monitor.wait(); } catch (Throwable ignored) { }
            }
        }
        if ("cpu".equals(mode())) {
            new Thread(new Runnable() { public void run() {
                try { Thread.sleep(50); } catch (InterruptedException ignored) { }
                System.gc();
            }}).start();
            System.out.println("SESSION_BLOCK cpu");
            NativeBridge.status("SESSION_ARM");
            for (;;) { }
        }
        if ("reflection".equals(mode())) {
            try { ReflectionChecks.main(new String[0]); }
            catch (Exception error) { throw new RuntimeException(error.toString()); }
        }
        if ("nested".equals(mode())) {
            MIDletAccess before = MIDletBridge.getMIDletAccess(this);
            Child child = new Child();
            if (MIDletBridge.getMIDletAccess(this) != before) throw new Error("Parent context replaced");
            MIDletBridge.getMIDletAccess(child).startApp();
            child.notifyDestroyed();
            if (MIDletBridge.getMIDletAccess(this) != before) throw new Error("Child destroyed parent");
            System.out.println("SESSION_CONTEXT_PASS");
        }
        if ("thread".equals(mode())) {
            new Thread(new Runnable() { public void run() {
                Thread.currentThread().setContextClassLoader(null);
                block("child-thread");
            }}).start();
        }
        if ("resources".equals(mode())) {
            images = new Image[40];
            for (int i = 0; i < images.length; i++) images[i] = Image.createImage(64, 64);
            new Thread(new Runnable() { public void run() {
                try { Thread.sleep(100); } catch (InterruptedException ignored) { }
                System.gc();
                System.out.println("SESSION_RESOURCES_READY");
                notifyDestroyed();
            }}).start();
        }
        final Canvas canvas=new Canvas() {
            private boolean typed;
            private boolean held;
            private boolean queuePassed;
            protected void keyPressed(int key) {
                if (key == 'z') held = true;
                if (key == 'q' && "queue".equals(mode()) && !queuePassed) {
                    if (held) throw new Error("Queue overflow left key held");
                    queuePassed = true;
                    System.out.println("SESSION_QUEUE_PASS"); NativeBridge.status("SESSION_ARM");
                }
                // The flood test stops as soon as text delivery begins. The
                // queue test must stay alive until the final held-key probe.
                if (key == 'z' && "flood".equals(mode()) && !typed) {
                    typed = true; System.out.println("SESSION_TEXT_STARTED"); NativeBridge.status("SESSION_ARM");
                }
            }
            protected void keyReleased(int key) { if (key == 'z') held = false; }
            protected void paint(Graphics g) {
                g.setColor(0x224466); g.fillRect(0, 0, getWidth(), getHeight());
            }
        };
        Display.getDisplay(this).setCurrent(canvas);
        if("paint-stop".equals(mode())) {
            new Thread(new Runnable() { public void run() {
                for(;;) {
                    canvas.repaint();canvas.serviceRepaints();
                    try { Thread.sleep(1); } catch(InterruptedException ignored) { }
                }
            }}).start();
            System.out.println("SESSION_PAINT_STOP_READY");
        }
        System.out.println("SESSION_READY");
        if (!"flood".equals(mode()) && !"queue".equals(mode()) && !"resources".equals(mode())) NativeBridge.status("SESSION_ARM");
    }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) {
        System.out.println("SESSION_DESTROY");
        if ("destroy".equals(mode())) block("destroy");
    }
    public static final class Child extends MIDlet {
        public void startApp() { }
        public void pauseApp() { }
        public void destroyApp(boolean unconditional) { }
    }
}
