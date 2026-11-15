package org.microemu.ios;

import java.io.*;
import java.util.jar.*;

/** Archive data belongs to the current read, never to an indexed ZipEntry. */
final class ArchiveIO {
    static byte[] read(JarFile archive,JarEntry entry) throws IOException {
        ArchiveInputStream input=new ArchiveInputStream(archive.getName(),entry.getName());
        try {
            if(input.length>Integer.MAX_VALUE)throw new IOException("Archive entry is too large: "+entry.getName());
            byte[] data=new byte[(int)input.length];
            if(input.read(data)!=data.length)throw new IOException("Truncated archive entry: "+entry.getName());
            return data;
        } finally { input.close(); }
    }
    static InputStream open(JarFile archive,JarEntry entry) throws IOException {
        return new ArchiveInputStream(archive.getName(),entry.getName());
    }

    /** Fixed read-ahead buffer. mark/reset replays the archive instead of retaining
     * every byte since mark, even when a game requests an unlimited read limit. */
    private static final class ArchiveInputStream extends InputStream {
        private long handle,position,marked,length;
        private byte[] buffer=new byte[8192];
        private int offset,count;
        ArchiveInputStream(String path,String name) throws IOException {
            handle=NativeBridge.archiveOpen(path,name);
            if(handle==0)throw new IOException("Cannot open archive entry: "+name);
            length=NativeBridge.archiveRemaining(handle);
        }
        private void checkOpen() throws IOException { if(handle==0)throw new IOException("Archive stream is closed"); }
        private int fill() throws IOException {
            offset=0;count=NativeBridge.archiveRead(handle,buffer,0,buffer.length);
            if(count < -1)throw new IOException("Cannot decompress archive entry (invalid ZIP data or CRC)");
            return count;
        }
        public synchronized int read() throws IOException {
            checkOpen();
            if(offset>=count && fill()==-1)return -1;
            position++;return buffer[offset++]&255;
        }
        public synchronized int read(byte[] data,int start,int size) throws IOException {
            checkOpen();
            if(data==null)throw new NullPointerException();
            if(start<0 || size<0 || start>data.length-size)throw new IndexOutOfBoundsException();
            if(size==0)return 0;
            // Legacy MIDlets often allocate available() bytes and ignore read's
            // return value. Preserve the previous byte-array stream behaviour
            // while each native operation remains bounded and cancellable.
            int total=0;
            while(total<size) {
                if(offset>=count) {
                    if(size-total>=buffer.length) {
                        int got=NativeBridge.archiveRead(handle,data,start+total,size-total);
                        if(got < -1)throw new IOException("Cannot decompress archive entry (invalid ZIP data or CRC)");
                        if(got==-1)break;
                        total+=got;position+=got;continue;
                    }
                    if(fill()==-1)break;
                }
                int copied=Math.min(size-total,count-offset);
                System.arraycopy(buffer,offset,data,start+total,copied);
                offset+=copied;position+=copied;total+=copied;
            }
            return total==0?-1:total;
        }
        public synchronized long skip(long amount) throws IOException {
            checkOpen();if(amount<=0)return 0;
            long skipped=0;
            while(skipped<amount) {
                if(offset>=count && fill()==-1)break;
                int advance=(int)Math.min(amount-skipped,(long)count-offset);
                offset+=advance;position+=advance;skipped+=advance;
            }
            return skipped;
        }
        public synchronized int available() throws IOException { checkOpen();return (int)Math.min(Integer.MAX_VALUE,length-position); }
        public boolean markSupported() { return true; }
        public synchronized void mark(int limit) { marked=position; }
        public synchronized void reset() throws IOException {
            checkOpen();long target=marked;
            if(!NativeBridge.archiveRewind(handle))throw new IOException("Cannot rewind archive entry");
            offset=count=0;position=0;
            if(skip(target)!=target)throw new IOException("Truncated archive entry during reset");
        }
        public synchronized void close() {
            if(handle!=0) {NativeBridge.archiveClose(handle);handle=0;}
            buffer=null;offset=count=0;
        }
        protected void finalize() { close(); }
    }
}
