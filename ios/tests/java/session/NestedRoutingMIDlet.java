package session;

import javax.microedition.midlet.MIDlet;
import javax.microedition.lcdui.*;
import org.microemu.*;
import org.microemu.ios.NativeBridge;

/** Wrapper invokes children directly through reflection, as GENZ does. */
public final class NestedRoutingMIDlet extends MIDlet {
    private Child first, second;
    private MIDletAccess rootAccess;
    public void startApp() {
        rootAccess = MIDletBridge.getMIDletAccess(this);
        first = new Child(this, 'a'); second = new Child(this, 'b');
        if (MIDletBridge.getMIDletAccess(this) != rootAccess) throw new Error("Root accessor replaced");
        launch(first);
    }
    private void launch(Child child) {
        try { child.getClass().getMethod("startApp", (Class[])null).invoke(child, (Object[])null); }
        catch (Exception error) { throw new RuntimeException(error.toString()); }
    }
    private void received(Child child) {
        if (MIDletBridge.getCurrentMIDlet() != child) throw new Error("Callback has wrong MIDlet context");
        child.notifyDestroyed();
        if (MIDletBridge.getMIDletAccess(this) != rootAccess) throw new Error("Child notifyDestroyed changed root");
        if (child == first) launch(second);
        else {
            NativeBridge.status("SESSION_NESTED_ROUTING_PASS");
            NativeBridge.status("SESSION_ARM");
        }
    }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) { }
    public static final class Child extends MIDlet {
        private final NestedRoutingMIDlet root;
        private final int key;
        Child(NestedRoutingMIDlet root, int key) { this.root = root; this.key = key; }
        public void startApp() {
            Display display = Display.getDisplay(this);
            display.setCurrent(new Canvas() {
                protected void paint(Graphics g) { g.setColor(0x448855); g.fillRect(0, 0, getWidth(), getHeight()); }
                protected void keyPressed(int code) {
                    if (code != key) throw new Error("Input routed to wrong child");
                    root.received(Child.this);
                }
            });
            display.callSerially(new Runnable() { public void run() {
                NativeBridge.status(key == 'a' ? "ROUTE_A_READY" : "ROUTE_B_READY");
            }});
        }
        public void pauseApp() { }
        public void destroyApp(boolean unconditional) { }
    }
}
