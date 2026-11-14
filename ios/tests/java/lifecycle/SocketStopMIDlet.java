package lifecycle;
import java.io.InputStream;
import javax.microedition.io.*;
import javax.microedition.lcdui.*;
import javax.microedition.midlet.MIDlet;

/** A stopped MIDlet may leave a blocking reader for VM shutdown to cancel. */
public final class SocketStopMIDlet extends MIDlet {
    public void startApp() {
        try {
            final SocketConnection connection = (SocketConnection)Connector.open(
                    "socket://127.0.0.1:" + getAppProperty("Test-Port"));
            final InputStream input = connection.openInputStream();
            new Thread(new Runnable() {
                public void run() {
                    System.out.println("SOCKET_READER_READY");
                    try { input.read(); } catch (Exception expected) { }
                    finally { try { input.close(); connection.close(); } catch (Exception ignored) { } }
                }
            }, "idle-socket-reader").start();
            Display.getDisplay(this).setCurrent(new Canvas() {
                protected void paint(Graphics graphics) {
                    graphics.setColor(0x2244aa); graphics.fillRect(0, 0, getWidth(), getHeight());
                }
            });
        } catch (Exception error) { error.printStackTrace(); notifyDestroyed(); }
    }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) { }
}
