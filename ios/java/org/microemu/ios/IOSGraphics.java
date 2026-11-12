package org.microemu.ios;

import javax.microedition.lcdui.Font;
import javax.microedition.lcdui.Graphics;
import javax.microedition.lcdui.Image;

/** MIDP drawing state. Pixels and sprite transforms use the same C renderer on iOS and in tests. */
final class IOSGraphics extends Graphics {
    private final IOSImage image;
    private final int[] args = new int[17];
    private int color, cx, cy, cw, ch, stroke;
    private Font font = Font.getDefaultFont();

    IOSGraphics(IOSImage image) { this.image = image; cw = image.getWidth(); ch = image.getHeight(); }
    private void draw(int op, long source, int x, int y, int w, int h, int a, int b, int c, int d, String text) {
        args[0] = color; args[1] = cx; args[2] = cy; args[3] = cw; args[4] = ch; args[5] = stroke;
        args[6] = x + getTranslateX(); args[7] = y + getTranslateY(); args[8] = w; args[9] = h;
        args[10] = a; args[11] = b; args[12] = c; args[13] = d;
        args[14] = IOSDevice.fontSize(font); args[15] = font.getStyle(); args[16] = font.getFace();
        NativeBridge.draw(image.surface, source, op, args, text);
    }
    static int anchorX(int x, int width, int anchor) {
        if ((anchor & RIGHT) != 0) return x - width;
        if ((anchor & HCENTER) != 0) return x - width / 2;
        return x;
    }
    static int anchorY(int y, int height, int anchor) {
        if ((anchor & BOTTOM) != 0) return y - height;
        if ((anchor & VCENTER) != 0) return y - height / 2;
        return y;
    }
    public synchronized void clipRect(int x, int y, int w, int h) {
        int nx = Math.max(cx, x + getTranslateX()), ny = Math.max(cy, y + getTranslateY());
        int right = Math.min(cx + cw, x + getTranslateX() + Math.max(0, w));
        int bottom = Math.min(cy + ch, y + getTranslateY() + Math.max(0, h));
        cx = nx; cy = ny; cw = Math.max(0, right - nx); ch = Math.max(0, bottom - ny);
    }
    public synchronized void setClip(int x, int y, int w, int h) {
        cx = 0; cy = 0; cw = image.getWidth(); ch = image.getHeight(); clipRect(x, y, w, h);
    }
    public int getClipX() { return cx - getTranslateX(); }
    public int getClipY() { return cy - getTranslateY(); }
    public int getClipWidth() { return cw; }
    public int getClipHeight() { return ch; }
    public int getColor() { return color; }
    public void setColor(int value) { color = value & 0xffffff; }
    public Font getFont() { return font; }
    public void setFont(Font value) { font = value == null ? Font.getDefaultFont() : value; }
    public int getStrokeStyle() { return stroke; }
    public void setStrokeStyle(int value) {
        if (value != SOLID && value != DOTTED) throw new IllegalArgumentException();
        stroke = value;
    }
    public int getDisplayColor(int value) { return value & 0xffffff; }
    public synchronized void fillRect(int x, int y, int w, int h) { draw(1, 0, x, y, w, h, 0, 0, 0, 0, null); }
    public synchronized void drawRect(int x, int y, int w, int h) { draw(2, 0, x, y, w, h, 0, 0, 0, 0, null); }
    public synchronized void drawLine(int x, int y, int x2, int y2) { draw(3, 0, x, y, x2 + getTranslateX(), y2 + getTranslateY(), 0, 0, 0, 0, null); }
    public synchronized void drawRoundRect(int x, int y, int w, int h, int aw, int ah) { draw(4, 0, x, y, w, h, aw, ah, 0, 0, null); }
    public synchronized void fillRoundRect(int x, int y, int w, int h, int aw, int ah) { draw(5, 0, x, y, w, h, aw, ah, 0, 0, null); }
    public synchronized void drawArc(int x, int y, int w, int h, int start, int arc) { draw(6, 0, x, y, w, h, start, arc, 0, 0, null); }
    public synchronized void fillArc(int x, int y, int w, int h, int start, int arc) { draw(7, 0, x, y, w, h, start, arc, 0, 0, null); }
    public synchronized void fillTriangle(int x, int y, int x2, int y2, int x3, int y3) {
        draw(8, 0, x, y, x2 + getTranslateX(), y2 + getTranslateY(), x3 + getTranslateX(), y3 + getTranslateY(), 0, 0, null);
    }
    public void drawImage(Image source, int x, int y, int anchor) {
        drawRegion(source, 0, 0, source.getWidth(), source.getHeight(), 0, x, y, anchor);
    }
    public synchronized void drawRegion(Image source, int sx, int sy, int w, int h, int transform, int x, int y, int anchor) {
        if (source == image || sx < 0 || sy < 0 || w < 0 || h < 0 || sx + (long)w > source.getWidth()
                || sy + (long)h > source.getHeight() || transform < 0 || transform > 7) throw new IllegalArgumentException();
        int dw = transform >= 4 ? h : w, dh = transform >= 4 ? w : h;
        draw(9, ((IOSImage) source).surface, anchorX(x, dw, anchor), anchorY(y, dh, anchor), w, h, sx, sy, transform, 0, null);
    }
    public synchronized void drawString(String text, int x, int y, int anchor) {
        if (text == null) throw new NullPointerException();
        x = anchorX(x, font.stringWidth(text), anchor);
        y = (anchor & BASELINE) != 0 ? y - font.getBaselinePosition() : anchorY(y, font.getHeight(), anchor);
        draw(10, 0, x, y, 0, 0, 0, 0, 0, 0, text);
    }
    public void drawSubstring(String text, int offset, int length, int x, int y, int anchor) { drawString(text.substring(offset, offset + length), x, y, anchor); }
    public void drawRGB(int[] data, int offset, int scan, int x, int y, int w, int h, boolean alpha) {
        IOSImage.checkPixels(data, offset, scan, w, h);
        if (w == 0 || h == 0) return;
        IOSImage temp = new IOSImage(NativeBridge.create(w, h, 0), true);
        try {
            NativeBridge.pixels(temp.surface, data, offset, scan, 0, 0, w, h, true, alpha);
            drawImage(temp, x, y, TOP | LEFT);
        } finally { NativeBridge.release(temp.surface); }
    }
    public void copyArea(int sx, int sy, int w, int h, int x, int y, int anchor) {
        int[] data = new int[w * h]; image.getRGB(data, 0, w, sx + getTranslateX(), sy + getTranslateY(), w, h);
        drawRGB(data, 0, w, anchorX(x, w, anchor), anchorY(y, h, anchor), w, h, true);
    }
}
