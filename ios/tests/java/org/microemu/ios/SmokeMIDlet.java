package org.microemu.ios;

import java.io.*;
import javax.microedition.io.*;
import javax.microedition.lcdui.*;
import javax.microedition.midlet.MIDlet;
import javax.microedition.rms.*;

public final class SmokeMIDlet extends MIDlet {
    private void check(boolean value, String message) { if (!value) throw new RuntimeException("SMOKE_FAIL: " + message); }
    public void startApp() {
        try {
            Image image = Image.createImage(8, 8); Graphics g = image.getGraphics();
            g.setColor(0x123456); g.setClip(1, 1, 2, 2); g.fillRect(0, 0, 8, 8);
            int[] data = new int[64]; image.getRGB(data, 0, 8, 0, 0, 8, 8);
            check(data[9] == 0xff123456 && data[0] == 0xffffffff, "graphics clipping");
            g.translate(2, 3); g.setClip(0, 0, 1, 1); g.setColor(0xabcdef); g.fillRect(0, 0, 1, 1);
            image.getRGB(data, 0, 8, 0, 0, 8, 8); check(data[26] == 0xffabcdef, "graphics translation");
            Image source = Image.createRGBImage(new int[]{0xffff0000,0xff00ff00,0xff0000ff,0xffffff00,0xffff00ff,0xff00ffff},2,3,true);
            int[] first = {0xffff0000,0xffff00ff,0xff00ff00,0xff00ffff,0xffff0000,0xffff00ff,0xff00ff00,0xff00ffff};
            for(int tr=0;tr<8;tr++) {
                Image transformed=Image.createImage(source,0,0,2,3,tr);int[] pixel=new int[1];transformed.getRGB(pixel,0,1,0,0,1,1);
                check(pixel[0]==first[tr],"sprite transform "+tr);
            }
            byte[] saved="Tiếng Việt / RMS".getBytes("UTF-8");
            RecordStore store=RecordStore.openRecordStore("smoke",true);
            int one=store.addRecord(saved,0,saved.length),two=store.addRecord(new byte[0],0,0);
            store.deleteRecord(two);store.closeRecordStore();store=RecordStore.openRecordStore("smoke",false);
            check(store.getNextRecordID()==two+1,"deleted RMS ID must not be reused");
            byte[] loaded=store.getRecord(one);check(new String(loaded,"UTF-8").equals(new String(saved,"UTF-8")),"persistent RMS reopen");
            RecordStore same=RecordStore.openRecordStore("smoke",false);same.closeRecordStore();check(store.getRecord(one).length==saved.length,"RMS open references");store.closeRecordStore();
            String port=getAppProperty("Test-Port");
            if(port!=null) {
                SocketConnection socket=(SocketConnection)Connector.open("socket://127.0.0.1:"+port);
                OutputStream out=socket.openOutputStream();InputStream in=socket.openInputStream();
                byte[] sent={0,1,127,(byte)128,(byte)255,10};out.write(sent);out.flush();
                for(int i=0;i<sent.length;i++)check(in.read()==(sent[i]&255),"TCP binary byte "+i);
                out.close();in.close();socket.close();
                HttpConnection http=(HttpConnection)Connector.open("http://127.0.0.1:"+port+"/test");
                check(http.getResponseCode()==200,"HTTP status");InputStream response=http.openInputStream();
                ByteArrayOutputStream body=new ByteArrayOutputStream();int next;while((next=response.read())!=-1)body.write(next);
                check(new String(body.toByteArray(),"UTF-8").equals("HTTP_OK"),"HTTP body");response.close();http.close();
            }
            final StringBuffer typed = new StringBuffer();
            Display.getDisplay(this).setCurrent(new Canvas() {
                protected void paint(Graphics graphics) { graphics.setColor(0x123456); graphics.fillRect(0,0,getWidth(),getHeight()); graphics.drawImage(source,20,20,Graphics.TOP|Graphics.LEFT); }
                protected void keyPressed(int key) { typed.append((char)key); }
            });
            new Thread(new Runnable() {
                public void run() {
                    try {
                        long deadline = System.currentTimeMillis() + 3000;
                        while (typed.length() < 6 && System.currentTimeMillis() < deadline) Thread.sleep(10);
                        check(typed.toString().equals("Test42"), "Canvas keyboard text input");
                        System.out.println("SMOKE_PASS: graphics, transforms, RMS persistence, TCP bytes, HTTP, Canvas keyboard");
                    } catch(Throwable error) { error.printStackTrace(); NativeBridge.failed("SMOKE_FAIL: " + error); }
                    notifyDestroyed();
                }
            }).start();
            return;
        } catch(Throwable error) { error.printStackTrace(); NativeBridge.status("SMOKE_FAIL: "+error); }
        notifyDestroyed();
    }
    public void pauseApp() { }
    public void destroyApp(boolean unconditional) { }
}
