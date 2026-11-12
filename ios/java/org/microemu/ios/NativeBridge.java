package org.microemu.ios;

/** Native functions registered explicitly with the embedded interpreter. */
public final class NativeBridge {
    private NativeBridge() { }
    static native long create(int width, int height, int argb);
    static native long decode(byte[] data, int offset, int length);
    static native void release(long surface);
    static native int width(long surface);
    static native int height(long surface);
    static native void pixels(long surface, int[] data, int offset, int scan,
                              int x, int y, int width, int height, boolean write, boolean alpha);
    static native void draw(long target, long source, int operation, int[] arguments, String text);
    static native void present(long surface);
    static native int textWidth(String text, int size, int style, int face);
    static native int poll(int[] event);
    static native String takeText();
    static native void modal(String title, String value, int maxSize, int constraints, String[] commands);
    static native void status(String text);
    static native void failed(String text);
    static native void browse(String url);
    static native void vibrate(int milliseconds);
}
