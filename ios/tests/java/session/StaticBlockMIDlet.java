package session;
import javax.microedition.midlet.MIDlet;
public final class StaticBlockMIDlet extends MIDlet {
    static { block(); }
    private static void block() {
        System.out.println("SESSION_BLOCK clinit");
        org.microemu.ios.NativeBridge.status("SESSION_ARM");
        for (;;) try { Thread.sleep(1000); } catch (Throwable ignored) { }
    }
    public void startApp() { }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) { }
}
