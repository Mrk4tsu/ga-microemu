package session;

import javax.microedition.midlet.MIDlet;
import javax.microedition.lcdui.*;
import javax.microedition.io.*;
import java.io.*;
import org.microemu.ios.NativeBridge;

public final class SocketSessionMIDlet extends MIDlet {
    private Canvas canvas;
    public void startApp() {
        canvas = new Canvas() { protected void paint(Graphics g) {
            g.setColor(0x335577); g.fillRect(0, 0, getWidth(), getHeight());
        }};
        Display.getDisplay(this).setCurrent(canvas);
        new Thread(new Runnable() { public void run() {
            try {
                SocketConnection connection = (SocketConnection)Connector.open("socket://127.0.0.1:" + getAppProperty("Test-Port"));
                InputStream in = connection.openInputStream(); OutputStream out = connection.openOutputStream();
                boolean peer = "peer".equals(getAppProperty("Test-Mode"));
                out.write(peer ? 1 : 0); out.flush();
                if (!peer) {
                    NativeBridge.status("SESSION_SOCKET_IDLE"); NativeBridge.status("SESSION_ARM");
                    in.read();
                } else {
                    long end = System.currentTimeMillis() + 2500; int tick = 0;
                    while (System.currentTimeMillis() < end) {
                        out.write(tick & 127); out.flush();
                        if (in.read() != (tick++ & 127)) throw new IOException("Peer TCP interrupted");
                        canvas.repaint(); Thread.sleep(50);
                    }
                    NativeBridge.status("SESSION_ISOLATION_PASS"); notifyDestroyed();
                }
                // Deliberately leave streams open: the session registry owns cleanup.
            } catch (Exception error) { throw new RuntimeException(error.toString()); }
        }}).start();
    }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) { }
}
