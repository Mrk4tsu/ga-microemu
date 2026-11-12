package org.microemu.ios;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.Vector;
import javax.microedition.lcdui.*;
import javax.microedition.lcdui.game.GameCanvas;
import org.microemu.MIDletAccess;
import org.microemu.MIDletBridge;
import org.microemu.device.*;
import org.microemu.device.ui.UIFactory;

final class IOSDevice implements Device, DeviceDisplay, FontManager {
    final int width, height;
    final IOSImage screen;
    private final IOSRuntime runtime;
    private final IOSUI ui = new IOSUI();
    private final Map properties = new HashMap();
    private final Map gameBuffers = new java.util.WeakHashMap();
    private final InputMethod input = new InputMethod() {
        public void dispose() { }
        public int getGameAction(int code) {
            switch (code) {
                case -1: case '2': return Canvas.UP;
                case -2: case '8': return Canvas.DOWN;
                case -3: case '4': return Canvas.LEFT;
                case -4: case '6': return Canvas.RIGHT;
                case -5: case '5': return Canvas.FIRE;
                case '7': return Canvas.GAME_A;
                case '9': return Canvas.GAME_B;
                case '*': return Canvas.GAME_C;
                case '#': return Canvas.GAME_D;
                default: return 0;
            }
        }
        public int getKeyCode(int action) {
            switch (action) {
                case Canvas.UP: return -1; case Canvas.DOWN: return -2;
                case Canvas.LEFT: return -3; case Canvas.RIGHT: return -4;
                case Canvas.FIRE: return -5; case Canvas.GAME_A: return '7';
                case Canvas.GAME_B: return '9'; case Canvas.GAME_C: return '*';
                case Canvas.GAME_D: return '#'; default: throw new IllegalArgumentException();
            }
        }
        public String getKeyName(int code) { return code >= 32 ? String.valueOf((char)code) : "Key " + code; }
    };
    IOSDevice(IOSRuntime runtime, int width, int height) {
        this.runtime = runtime;
        this.width = width; this.height = height;
        screen = new IOSImage(NativeBridge.create(width, height, 0xff000000), true);
        properties.put("microedition.platform", "MicroEmu-iOS");
    }
    public void init() { }
    public void destroy() { input.dispose(); }
    public String getName() { return "MicroEmu iOS"; }
    public InputMethod getInputMethod() { return input; }
    public FontManager getFontManager() { return this; }
    public DeviceDisplay getDeviceDisplay() { return this; }
    public UIFactory getUIFactory() { return ui; }
    public Image getNormalImage() { return screen; }
    public Image getOverImage() { return screen; }
    public Image getPressedImage() { return screen; }
    public Vector getSoftButtons() { return new Vector(); }
    public Vector getButtons() { return new Vector(); }
    public boolean hasPointerEvents() { return true; }
    public boolean hasPointerMotionEvents() { return true; }
    public boolean hasRepeatEvents() { return true; }
    public boolean vibrate(int duration) {
        if (duration < 0) throw new IllegalArgumentException();
        if (runtime.isSleeping() || runtime.isStopped()) return false;
        NativeBridge.vibrate(duration); return true;
    }
    public Map getSystemProperties() { return properties; }
    public boolean flashBacklight(int duration) { return false; }
    public int getWidth() { return width; }
    public int getHeight() { return height; }
    public int getFullWidth() { return width; }
    public int getFullHeight() { return height; }
    public boolean isColor() { return true; }
    public boolean isFullScreenMode() { return true; }
    public int numAlphaLevels() { return 256; }
    public int numColors() { return 16777216; }
    public void setScrollDown(boolean value) { }
    public void setScrollUp(boolean value) { }
    public void repaint(int x, int y, int w, int h) {
        if (runtime.isStopped()) return;
        if (runtime.isSleeping()) { runtime.sleepThrottle(); return; }
        synchronized (this) {
            MIDletAccess access = MIDletBridge.getMIDletAccess();
            if (access != null && access.getDisplayAccess() != null) {
                access.getDisplayAccess().paint(new IOSGraphics(screen));
                NativeBridge.presentTab(runtime.tabId, screen.surface);
            }
        }
    }
    synchronized void presentScreen() {
        if (!runtime.isSleeping() && !runtime.isStopped()) NativeBridge.presentTab(runtime.tabId, screen.surface);
    }
    public Image createImage(int w, int h, boolean alpha, int fill) {
        return new IOSImage(NativeBridge.create(w, h, alpha ? fill : 0xff000000 | fill), true);
    }
    public Image createImage(String name) throws IOException {
        InputStream in = IOSRuntime.instance.getResourceAsStream(IOSRuntime.class, name);
        if (in == null) throw new IOException("Missing image: " + name);
        try { return createImage(in); } finally { in.close(); }
    }
    public Image createImage(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream(); byte[] buffer = new byte[4096]; int count;
        while ((count = in.read(buffer)) != -1) { if (count > 0) out.write(buffer, 0, count); }
        byte[] data = out.toByteArray(); return createImage(data, 0, data.length);
    }
    public Image createImage(byte[] data, int offset, int length) {
        if (data == null) throw new NullPointerException();
        if (offset < 0 || length < 0 || offset + (long)length > data.length) throw new ArrayIndexOutOfBoundsException();
        return new IOSImage(NativeBridge.decode(data, offset, length), false);
    }
    public Image createImage(Image source) { return createImage(source, 0, 0, source.getWidth(), source.getHeight(), 0); }
    public Image createRGBImage(int[] data, int w, int h, boolean alpha) {
        if (w <= 0 || h <= 0) throw new IllegalArgumentException();
        IOSImage.checkPixels(data, 0, w, w, h);
        IOSImage result = new IOSImage(NativeBridge.create(w, h, 0), false);
        NativeBridge.pixels(result.surface, data, 0, w, 0, 0, w, h, true, alpha); return result;
    }
    public Image createImage(Image source, int x, int y, int w, int h, int transform) {
        IOSImage result = new IOSImage(NativeBridge.create(transform >= 4 ? h : w, transform >= 4 ? w : h, 0), false);
        new IOSGraphics(result).drawRegion(source, x, y, w, h, transform, 0, 0, Graphics.TOP | Graphics.LEFT); return result;
    }
    private IOSImage gameBuffer(GameCanvas canvas) {
        IOSImage buffer = (IOSImage) gameBuffers.get(canvas);
        if (buffer == null) { buffer = (IOSImage)createImage(width, height, false, 0); gameBuffers.put(canvas, buffer); }
        return buffer;
    }
    public Graphics getGraphics(GameCanvas canvas) { return new IOSGraphics(gameBuffer(canvas)); }
    public void flushGraphics(GameCanvas canvas, int x, int y, int w, int h) {
        if (runtime.isStopped()) return;
        if (runtime.isSleeping()) { runtime.sleepThrottle(); return; }
        synchronized (this) {
            IOSGraphics graphics = new IOSGraphics(screen); graphics.setClip(x, y, w, h);
            graphics.drawImage(gameBuffer(canvas), 0, 0, Graphics.TOP | Graphics.LEFT);
            NativeBridge.presentTab(runtime.tabId, screen.surface);
        }
    }
    static int fontSize(Font font) { return font.getSize() == Font.SIZE_SMALL ? 12 : font.getSize() == Font.SIZE_LARGE ? 20 : 16; }
    public int charWidth(Font f, char c) { return stringWidth(f, String.valueOf(c)); }
    public int charsWidth(Font f, char[] c, int off, int len) { return stringWidth(f, new String(c, off, len)); }
    public int getBaselinePosition(Font f) { return fontSize(f); }
    public int getHeight(Font f) { return fontSize(f) + 4; }
    public int stringWidth(Font f, String text) { return NativeBridge.textWidth(text, fontSize(f), f.getStyle(), f.getFace()); }
    public int substringWidth(Font f, String text, int off, int len) { return stringWidth(f, text.substring(off, off + len)); }
}
