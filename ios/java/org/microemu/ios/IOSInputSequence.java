package org.microemu.ios;

import org.microemu.DisplayAccess;

/** Timed Canvas key pairs. The control thread never waits for a text sequence. */
final class IOSInputSequence {
    private DisplayAccess display;
    private String text;
    private int offset, key, hold;
    private boolean pressed;
    private long due;

    boolean isPending() { return display != null; }
    void cancel() {
        if (display != null && pressed) display.keyReleased(key);
        display = null; text = null; pressed = false;
    }
    void text(DisplayAccess target, String value) {
        if (value == null || value.length() == 0) return;
        display = target; text = value; offset = 0; hold = 20; due = 0; pressed = false;
    }
    void tap(DisplayAccess target, int value) {
        display = target; text = null; key = value; hold = 40; due = 0; pressed = false;
    }
    void advance() {
        if (display == null || System.currentTimeMillis() < due) return;
        if (!pressed) {
            if (text != null && offset == text.length()) { display = null; text = null; return; }
            if (text != null) key = text.charAt(offset++);
            display.keyPressed(key); pressed = true;
            due = System.currentTimeMillis() + hold;
        } else {
            display.keyReleased(key); pressed = false;
            due = System.currentTimeMillis() + 10;
            if (text == null) display = null;
        }
    }
}
