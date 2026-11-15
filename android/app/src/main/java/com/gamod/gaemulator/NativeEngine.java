package com.gamod.gaemulator;

import android.content.Context;
import android.graphics.*;
import android.os.Handler;
import android.os.Looper;
import java.lang.ref.WeakReference;

/** Android JNI only. Game classes remain inside the shared miniJVM interpreter. */
public final class NativeEngine {
    static { System.loadLibrary("gaemulator"); }
    public interface Listener {
        void status(int tab, String text);
        void modal(int tab, String title, String value, int max, int constraints, String[] commands);
        void finished(int tab, int result);
        void browse(String url);
        void vibrate(int milliseconds);
    }
    private static final Handler MAIN = new Handler(Looper.getMainLooper());
    private static volatile WeakReference<Listener> listener = new WeakReference<>(null);
    private static volatile boolean running, shuttingDown;
    private static Thread hostThread;
    public static void listen(Listener value) { listener = new WeakReference<>(value); }
    private interface Delivery { void send(Listener value); }
    private static void deliver(Delivery task) {
        Listener expected=listener.get();
        if(expected!=null)MAIN.post(()->{if(listener.get()==expected)task.send(expected);});
    }
    public static void onStatus(int tab, String text) { deliver(value -> value.status(tab, text)); }
    public static void onModal(int tab, String title, String text, int max, int constraints, String[] commands) {
        deliver(value -> value.modal(tab, title, text, max, constraints, commands));
    }
    public static void onFinished(int tab, int result) { deliver(value -> value.finished(tab, result)); }
    public static void onBrowse(String url) { deliver(value -> value.browse(url)); }
    public static void onVibrate(int ms) { deliver(value -> value.vibrate(ms)); }

    public static synchronized Thread startHost(RuntimeAssets assets, long physicalMemory) {
        if (running && !shuttingDown) return hostThread;
        if (running && hostThread != null) {
            try { hostThread.join(8000); } catch (InterruptedException error) { Thread.currentThread().interrupt(); throw new IllegalStateException(error); }
            if (hostThread.isAlive()) throw new IllegalStateException("Runtime đang dừng; hãy thử lại");
        }
        reset(); shuttingDown = false; running = true;
        Thread thread = new Thread(() -> {
            int result = runHost(assets.bootstrap.getPath(), assets.emulator.getPath(), assets.log.getPath(), physicalMemory);
            running = false; onStatus(0, result == 0 ? "Runtime đã dừng" : "Runtime lỗi: " + result);
        }, "GaEmulator-runtime");
        hostThread = thread; thread.start(); return thread;
    }
    public static boolean isRunning() { return running; }
    private static Paint textPaint(int size, int style, int face) {
        Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        paint.setTextSize(size); paint.setColor(Color.WHITE);
        int traits = (style & 3) == 3 ? Typeface.BOLD_ITALIC : (style & 1) != 0 ? Typeface.BOLD : (style & 2) != 0 ? Typeface.ITALIC : Typeface.NORMAL;
        paint.setTypeface(Typeface.create(face == 32 ? Typeface.MONOSPACE : Typeface.DEFAULT, traits));
        paint.setUnderlineText((style & 4) != 0); return paint;
    }
    public static int textWidth(String text, int size, int style, int face) {
        return (int)Math.ceil(textPaint(size, style, face).measureText(text == null ? "" : text));
    }
    public static int[] textMask(String text, int size, int style, int face) {
        Paint paint = textPaint(size, style, face);
        int width = (int)Math.ceil(paint.measureText(text)) + 2;
        Paint.FontMetrics metrics = paint.getFontMetrics();
        int height = Math.max(size + 6, (int)Math.ceil(metrics.descent - metrics.ascent) + 2);
        if (width < 1 || width > 8192 || height < 1 || height > 128) return new int[0];
        Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
        new Canvas(bitmap).drawText(text, 0, -metrics.ascent, paint);
        int[] pixels = new int[2 + width * height]; pixels[0] = width; pixels[1] = height;
        bitmap.getPixels(pixels, 2, width, 0, 0, width, height); bitmap.recycle(); return pixels;
    }
    private static native void reset();
    private static native int runHost(String bootstrap, String emulator, String log, long physicalMemory);
    public static void openTab(int tab, String jar, String rms, int width, int height) { openTab(tab,jar,rms,width,height,false); }
    public static void openTab(int tab, String jar, String rms, int width, int height, boolean fullScreen) { openTabWithViewport(tab,jar,rms,width,height,fullScreen); }
    private static native void openTabWithViewport(int tab, String jar, String rms, int width, int height, boolean fullScreen);
    public static native long[] resources(int tab);
    public static native void sleepTab(int tab, boolean sleeping);
    public static native void closeTab(int tab);
    public static void shutdown() { shuttingDown = true; requestShutdown(); }
    private static native void requestShutdown();
    public static native void event(int tab, int type, int a, int b, String text);
    public static native int[] takeFrame(int tab);
}
