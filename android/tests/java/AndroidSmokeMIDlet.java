package ga.tests;

import java.io.*;
import javax.microedition.io.*;
import javax.microedition.lcdui.*;
import javax.microedition.midlet.MIDlet;
import javax.microedition.rms.RecordStore;

/** Runs inside miniJVM, not ART: exercises the Android platform adapter end to end. */
public final class AndroidSmokeMIDlet extends MIDlet implements CommandListener {
    private Canvas canvas;
    private TextBox box;
    private volatile boolean input, network;
    private volatile int resumedFrames;
    private final Command ok=new Command("OK",Command.OK,0);
    public void startApp() {
        canvas=new Canvas() {
            protected void paint(Graphics graphics) {
                graphics.setColor(0xffffff); graphics.fillRect(0,0,getWidth(),getHeight());
                graphics.setColor(0x000000);
                graphics.setFont(Font.getFont(Font.FACE_SYSTEM,Font.STYLE_PLAIN,Font.SIZE_LARGE));
                graphics.drawString("F",10,10,Graphics.TOP|Graphics.LEFT);
                graphics.drawString("GaEmulator · tiếng Việt",10,60,Graphics.TOP|Graphics.LEFT);
                if(input) resumedFrames++;
            }
            protected void pointerPressed(int x,int y) {
                if(box!=null) return;
                box=new TextBox("Tài khoản","",32,TextField.ANY); box.addCommand(ok); box.setCommandListener(AndroidSmokeMIDlet.this);
                Display.getDisplay(AndroidSmokeMIDlet.this).setCurrent(box);
            }
        };
        Display.getDisplay(this).setCurrent(canvas);
        new Thread(new Runnable() { public void run() {
            try {
                RecordStore store=RecordStore.openRecordStore("android-smoke",true);
                int count=store.getNumRecords()==0?0:store.getRecord(1)[0]&255;
                if(count==0) store.addRecord(new byte[]{1},0,1); else store.setRecord(1,new byte[]{(byte)(count+1)},0,1);
                store.closeRecordStore(); System.out.println("ANDROID_RMS_COUNT="+(count+1));
                String port=getAppProperty("Test-Port");
                SocketConnection connection=(SocketConnection)Connector.open("socket://127.0.0.1:"+port);
                InputStream in=connection.openInputStream(); OutputStream out=connection.openOutputStream();
                byte[] payload={0,127,(byte)128,(byte)255}; out.write(payload); out.flush();
                for(int i=0;i<payload.length;i++) if(in.read()!=(payload[i]&255)) throw new IOException("TCP binary echo mismatch");
                in.close(); out.close(); connection.close();
                HttpConnection http=(HttpConnection)Connector.open("http://127.0.0.1:"+port+"/test");
                in=http.openInputStream(); ByteArrayOutputStream response=new ByteArrayOutputStream(); int value;
                while((value=in.read())!=-1) response.write(value);
                if(!"HTTP_OK".equals(new String(response.toByteArray(),"UTF-8"))) throw new IOException("HTTP body mismatch");
                in.close(); http.close(); network=true;
            } catch(Throwable error) { error.printStackTrace(); System.out.println("ANDROID_SMOKE_FAIL"); notifyDestroyed(); }
        }},"android-network-test").start();
        new Thread(new Runnable() { public void run() {
            long end=System.currentTimeMillis()+8000;
            try {
                while(System.currentTimeMillis()<end && !(network && input && resumedFrames>=3)) {
                    byte[] garbage=new byte[8192]; garbage[0]=1; System.gc(); canvas.repaint(); Thread.sleep(30);
                }
                System.out.println(network && input && resumedFrames>=3?"ANDROID_SMOKE_PASS":"ANDROID_SMOKE_FAIL");
                notifyDestroyed();
            } catch(InterruptedException expected) { }
        }},"android-input-watchdog").start();
    }
    public void commandAction(Command command,Displayable displayable) {
        if(displayable==box && command==ok && "android-input".equals(box.getString())) {
            input=true; Display.getDisplay(this).setCurrent(canvas);
        }
    }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) { }
}
