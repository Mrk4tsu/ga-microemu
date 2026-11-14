package org.microemu.ios;

/** Native functions registered explicitly with the embedded interpreter. */
public final class NativeBridge {
    private NativeBridge() { }
    public static native boolean validViewport(int width, int height);
    public static native boolean userViewportTab(int tabId);
    public static native boolean fullScreenTab(int tabId);
    public static native void prepareViewportRetry(int tabId);
    public static native boolean firstFrameSeen(long generation);
    public static native boolean userStopRequested(int tabId);
    public static final int RETRY_VIEWPORT = 2;
    /** A smaller framebuffer with the same aspect ratio can be enlarged by the frontend. */
    public static int[] fallbackViewport(int width, int height) {
        if ((long)width * height > 153600L) {
            double scale = Math.sqrt(153600.0 / ((double)width * height));
            width = Math.max(128, (int)(width * scale)); height = Math.max(128, (int)(height * scale));
            if ((long)width * height > 153600L) height = 153600 / width;
        }
        return new int[]{width, height};
    }
    public static native String sha256File(String path);
    public static native long beginSession(int tabId);
    public static native void bindSession(long generation);
    public static native boolean stopRequested(int tabId);
    public static native int cancelSession(long generation);
    public static native boolean releaseSession(long generation);
    public static native long create(int width, int height, int argb);
    public static native long decode(byte[] data, int offset, int length);
    public static native void release(long surface);
    public static native int width(long surface);
    public static native int height(long surface);
    public static native void pixels(long surface, int[] data, int offset, int scan,
                                     int x, int y, int width, int height, boolean write, boolean alpha);
    public static native void draw(long target, long source, int operation, int[] arguments, String text);
    public static native void present(long surface);
    public static native void presentTab(int tabId, long surface);
    public static native int textWidth(String text, int size, int style, int face);
    public static native int poll(int[] event);
    public static native int pollTab(int tabId, int[] event);
    public static native String takeText();
    public static native String takeTextTab(int tabId);
    public static native String takeTabJar(int tabId);
    public static native String takeTabRms(int tabId);
    public static native void modal(String title, String value, int maxSize, int constraints, String[] commands);
    public static native void modalTab(int tabId, String title, String value, int maxSize, int constraints, String[] commands);
    public static native void status(String text);
    public static native void statusTab(int tabId, String text);
    public static native void failed(String text);
    public static native void failedTab(int tabId, String text);
    public static native void finishedTab(int tabId, int result);
    public static native void browse(String url);
    public static native void vibrate(int milliseconds);
}
