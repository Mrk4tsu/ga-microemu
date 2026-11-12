package org.microemu.ios;

import javax.microedition.lcdui.Graphics;
import javax.microedition.lcdui.Image;

final class IOSImage extends Image {
    final long surface;
    private final int width, height;
    private final boolean mutable;

    IOSImage(long surface, boolean mutable) {
        if (surface == 0) throw new IllegalArgumentException("Cannot decode or allocate image");
        this.surface = surface;
        width = NativeBridge.width(surface);
        height = NativeBridge.height(surface);
        this.mutable = mutable;
    }
    public int getWidth() { return width; }
    public int getHeight() { return height; }
    public boolean isMutable() { return mutable; }
    public Graphics getGraphics() {
        if (!mutable) throw new IllegalStateException("Image is immutable");
        return new IOSGraphics(this);
    }
    static void checkPixels(int[] data, int offset, int scan, int width, int height) {
        if (data == null) throw new NullPointerException();
        if (width < 0 || height < 0) throw new IllegalArgumentException();
        if (width == 0 || height == 0) return;
        long end = (long) offset + (long) (height - 1) * scan;
        long first = Math.min(offset, end), last = Math.max(offset, end) + width;
        if (first < 0 || last > data.length) throw new ArrayIndexOutOfBoundsException();
    }
    public void getRGB(int[] data, int offset, int scan, int x, int y, int w, int h) {
        checkPixels(data, offset, scan, w, h);
        if (x < 0 || y < 0 || w < 0 || h < 0 || (long)x + w > width || (long)y + h > height)
            throw new IllegalArgumentException("Image region outside bounds");
        NativeBridge.pixels(surface, data, offset, scan, x, y, w, h, false, true);
    }
    protected void finalize() { NativeBridge.release(surface); }
}
