package org.microemu.ios;

import java.io.ByteArrayInputStream;
import java.io.DataInputStream;
import java.io.IOException;
import java.util.Hashtable;

/** Normalize legacy obfuscator calls without relaxing VM access checks or editing the JAR. */
final class LegacyBytecode {
    private static void check(byte[] b, int p, int n) throws IOException {
        if (p < 0 || n < 0 || p > b.length - n) throw new IOException("Truncated class file");
    }
    private static int u2(byte[] b, int p) throws IOException {
        check(b, p, 2);
        return ((b[p] & 255) << 8) | (b[p + 1] & 255);
    }
    private static int signedInt(byte[] b, int p) throws IOException {
        check(b, p, 4);
        return ((b[p] & 255) << 24) | ((b[p + 1] & 255) << 16)
                | ((b[p + 2] & 255) << 8) | (b[p + 3] & 255);
    }
    private static int u4(byte[] b, int p) throws IOException {
        int n = signedInt(b, p);
        if (n < 0) throw new IOException("Oversized class attribute");
        return n;
    }
    static byte[] adapt(byte[] bytes) throws IOException {
        check(bytes, 0, 10);
        if (signedInt(bytes, 0) != 0xcafebabe) throw new IOException("Invalid class file");
        int count = u2(bytes, 8), pos = 10;
        int[] tags = new int[count], first = new int[count], second = new int[count];
        String[] text = new String[count];
        for (int i = 1; i < count; i++) {
            check(bytes, pos, 1);
            int tag = tags[i] = bytes[pos++] & 255;
            if (tag == 1) {
                int length = u2(bytes, pos);
                check(bytes, pos + 2, length);
                text[i] = new DataInputStream(new ByteArrayInputStream(bytes, pos, length + 2)).readUTF();
                pos += 2 + length;
            } else if (tag == 5 || tag == 6) {
                check(bytes, pos, 8); pos += 8; i++;
            } else if (tag == 3 || tag == 4) {
                check(bytes, pos, 4); pos += 4;
            } else if (tag == 7 || tag == 8 || tag == 16 || tag == 19 || tag == 20) {
                first[i] = u2(bytes, pos); pos += 2;
            } else if (tag == 9 || tag == 10 || tag == 11 || tag == 12 || tag == 17 || tag == 18) {
                first[i] = u2(bytes, pos); second[i] = u2(bytes, pos + 2); pos += 4;
            } else if (tag == 15) {
                check(bytes, pos, 3); pos += 3;
            } else throw new IOException("Unknown constant pool tag " + tag);
        }
        int owner = u2(bytes, pos + 2);
        String ownerName = className(tags, first, text, owner);
        pos += 6;
        int interfaces = u2(bytes, pos); pos += 2 + interfaces * 2;
        int fields = u2(bytes, pos); pos += 2;
        for (int i = 0; i < fields; i++) pos = skipMember(bytes, pos);
        int methods = u2(bytes, pos); pos += 2;
        int methodsStart = pos;
        Hashtable privateMethods = new Hashtable();
        for (int i = 0; i < methods; i++) {
            int flags = u2(bytes, pos), name = u2(bytes, pos + 2), descriptor = u2(bytes, pos + 4);
            String methodName = utf(text, name);
            if ((flags & 0x0002) != 0 && (flags & 0x0008) == 0 && !"<init>".equals(methodName))
                privateMethods.put(methodName + "\n" + utf(text, descriptor), Boolean.TRUE);
            pos = skipMember(bytes, pos);
        }
        if (privateMethods.isEmpty()) return bytes;
        boolean[] privateRefs = new boolean[count];
        for (int ref = 1; ref < count; ref++) {
            if (tags[ref] != 10 || !ownerName.equals(className(tags, first, text, first[ref]))) continue;
            int nt = second[ref];
            if (nt <= 0 || nt >= count || tags[nt] != 12) throw new IOException("Invalid method reference");
            privateRefs[ref] = privateMethods.containsKey(utf(text, first[nt]) + "\n" + utf(text, second[nt]));
        }
        pos = methodsStart;
        byte[] adapted = null;
        for (int i = 0; i < methods; i++) {
            int attrs = u2(bytes, pos + 6); pos += 8;
            for (int a = 0; a < attrs; a++) {
                String name = utf(text, u2(bytes, pos));
                int length = u4(bytes, pos + 2); pos += 6;
                check(bytes, pos, length);
                if ("Code".equals(name)) {
                    if (length < 8) throw new IOException("Invalid Code attribute");
                    int size = u4(bytes, pos + 4), start = pos + 8;
                    if (size > length - 8) throw new IOException("Invalid Code length");
                    int end = start + size;
                    for (int pc = start; pc < end;) {
                        int next = nextInstruction(bytes, pc, start, end);
                        if ((bytes[pc] & 255) == 0xb6) {
                            int ref = u2(bytes, pc + 1);
                            if (ref < count && privateRefs[ref]) {
                                if (adapted == null) {
                                    adapted = new byte[bytes.length];
                                    System.arraycopy(bytes, 0, adapted, 0, bytes.length);
                                }
                                // Same receiver/stack effect and instruction length; offsets remain valid.
                                adapted[pc] = (byte)0xb7;
                            }
                        }
                        pc = next;
                    }
                }
                pos += length;
            }
        }
        return adapted == null ? bytes : adapted;
    }
    private static String utf(String[] text, int i) throws IOException {
        if (i <= 0 || i >= text.length || text[i] == null) throw new IOException("Invalid UTF8 reference");
        return text[i];
    }
    private static String className(int[] tags, int[] first, String[] text, int i) throws IOException {
        if (i <= 0 || i >= tags.length || tags[i] != 7) throw new IOException("Invalid class reference");
        return utf(text, first[i]);
    }
    private static int skipMember(byte[] b, int pos) throws IOException {
        int attrs = u2(b, pos + 6); pos += 8;
        for (int i = 0; i < attrs; i++) {
            int length = u4(b, pos + 2); pos += 6;
            check(b, pos, length); pos += length;
        }
        return pos;
    }
    private static int nextInstruction(byte[] b, int pc, int start, int end) throws IOException {
        int op = b[pc] & 255, length = 1;
        if (op == 0xaa || op == 0xab) {
            int aligned = pc + 1;
            while (((aligned - start) & 3) != 0) aligned++;
            if (aligned > end - 8) throw new IOException("Truncated switch");
            if (op == 0xaa) {
                if (aligned > end - 12) throw new IOException("Truncated tableswitch");
                int low = signedInt(b, aligned + 4), high = signedInt(b, aligned + 8);
                long entries = (long)high - low + 1;
                if (entries <= 0 || entries > (end - aligned - 12) / 4) throw new IOException("Invalid tableswitch");
                return aligned + 12 + (int)entries * 4;
            }
            int entries = u4(b, aligned + 4);
            if (entries > (end - aligned - 8) / 8) throw new IOException("Invalid lookupswitch");
            return aligned + 8 + entries * 8;
        }
        if (op == 0xc4) {
            if (pc >= end - 1) throw new IOException("Truncated wide instruction");
            length = (b[pc + 1] & 255) == 0x84 ? 6 : 4;
        } else if (op == 0x10 || op == 0x12 || (op >= 0x15 && op <= 0x19)
                || (op >= 0x36 && op <= 0x3a) || op == 0xa9 || op == 0xbc) length = 2;
        else if (op == 0x11 || op == 0x13 || op == 0x14 || op == 0x84
                || (op >= 0x99 && op <= 0xa8) || (op >= 0xb2 && op <= 0xb8)
                || op == 0xbb || op == 0xbd || op == 0xc0 || op == 0xc1 || op == 0xc6 || op == 0xc7) length = 3;
        else if (op == 0xc5) length = 4;
        else if (op == 0xb9 || op == 0xba || op == 0xc8 || op == 0xc9) length = 5;
        if (pc > end - length) throw new IOException("Truncated bytecode instruction");
        return pc + length;
    }
}
