#!/usr/bin/env python3
"""Fetch the pinned miniJVM and force the interpreter on every build host."""
import argparse
from pathlib import Path
import subprocess

REVISION = "76f904ea4008a8058db5155bf5ee2cfe94d19e60"
IOS = Path(__file__).resolve().parents[1]


def prepare(destination):
    destination = destination.resolve()
    if not (destination / ".git").exists():
        destination.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", str(destination)], check=True)
        subprocess.run(["git", "-C", str(destination), "remote", "add", "origin",
                        "https://github.com/digitalgust/miniJVM.git"], check=True)
        subprocess.run(["git", "-C", str(destination), "fetch", "--depth", "1", "origin", REVISION], check=True)
        subprocess.run(["git", "-C", str(destination), "checkout", "--detach", "FETCH_HEAD"], check=True)
    revision = subprocess.check_output(["git", "-C", str(destination), "rev-parse", "HEAD"], text=True).strip()
    if revision != REVISION:
        raise RuntimeError("miniJVM revision mismatch: " + revision)
    header = destination / "minijvm/c/jvm/jit.h"
    text = header.read_text(encoding="utf-8")
    old = "#if __JVM_OS_IOS__ || __JVM_OS_CYGWIN__ || __JVM_ARCH_32__\n#define JIT_ENABLE 0\n#else\n#define JIT_ENABLE 01\n#endif"
    new = "/* MicroEmu iOS: interpreter only, including host compatibility tests. */\n#define JIT_ENABLE 0"
    if old in text:
        header.write_text(text.replace(old, new, 1), encoding="utf-8")
    elif new not in text:
        raise RuntimeError("Pinned JIT configuration changed unexpectedly")
    # Process creation is unavailable in the iOS SDK and outside the MIDP profile.
    posix = destination / "minijvm/c/jvm/os_posix.c"
    text = posix.read_text(encoding="utf-8")
    marker = "/* MicroEmu iOS: no subprocesses in the app sandbox. */"
    if marker not in text:
        start = text.index("s32 os_execute(")
        body = text.index("{", start) + 1
        end = text.index("\ns32 os_kill_process", body)
        close = text.rfind("}", body, end)
        text = text[:body] + "\n" + marker + "\n#if __JVM_OS_IOS__\n    exception_throw(JVM_EXCEPTION_IO, runtime, NULL);\n    return RUNTIME_STATUS_EXCEPTION;\n#else\n" + text[body:close] + "\n#endif\n" + text[close:]
        posix.write_text(text, encoding="utf-8")
    # Thread.exit() can acquire a monitor after miniJVM's first exit cleanup.
    # Release on the owning OS thread before its metadata is destroyed.
    utility = destination / "minijvm/c/jvm/jvm_util.c"
    text = utility.read_text(encoding="utf-8")
    old_exit = "    runtime->thrd_info->thread_status = THREAD_STATUS_ZOMBIE;\n    jthread_assert_no_owned_locks(runtime->thrd_info);"
    new_exit = "    jthread_release_all_owned(runtime); /* MicroEmu: also clean Thread.exit() monitors. */\n" + old_exit
    if new_exit not in text:
        if text.count(old_exit) != 1:
            raise RuntimeError("Thread-exit compatibility patch no longer matches")
        utility.write_text(text.replace(old_exit, new_exit, 1), encoding="utf-8")
    network = destination / "minijvm/c/jvm/jni_io.c"
    text = network.read_text(encoding="utf-8")
    connect = "        ret = mbedtls_net_connect(ctx, jarray_body(host), jarray_body(port), proto);"
    logged = connect + '\n        jvm_printf("[NET] connect %s:%s result=%d\\n", jarray_body(host), jarray_body(port), ret);'
    if logged not in text:
        if text.count(connect) != 1:
            raise RuntimeError("Network diagnostic patch no longer matches")
        network.write_text(text.replace(connect, logged, 1), encoding="utf-8")
    zipwrap = destination / "minijvm/c/utils/miniz_wrapper.c"
    ztext = zipwrap.read_text(encoding="utf-8")
    zmarker = "/* MicroEmu iOS: ChaCha20 encrypted runtime archive loader. */"
    if zmarker not in ztext:
        helper = zmarker + """
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tinycthread.h"

static once_flag gemu_lock_once = ONCE_FLAG_INIT;
static mtx_t gemu_lock;
static void gemu_init_lock(void) { mtx_init(&gemu_lock, mtx_plain); }
typedef struct { char *path; unsigned char *data; size_t size; } GemuZipCache;
static GemuZipCache gemu_cache[8];
static int gemu_cache_count = 0;

static uint32_t gemu_rotl32(uint32_t v, int n) { return (v << n) | (v >> (32 - n)); }
static uint32_t gemu_load32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void gemu_store32(unsigned char *p, uint32_t v) {
    p[0] = (unsigned char)(v); p[1] = (unsigned char)(v >> 8);
    p[2] = (unsigned char)(v >> 16); p[3] = (unsigned char)(v >> 24);
}
#define GEMU_QR(s, a, b, c, d) do { \\
    s[a] += s[b]; s[d] = gemu_rotl32(s[d] ^ s[a], 16); \\
    s[c] += s[d]; s[b] = gemu_rotl32(s[b] ^ s[c], 12); \\
    s[a] += s[b]; s[d] = gemu_rotl32(s[d] ^ s[a], 8); \\
    s[c] += s[d]; s[b] = gemu_rotl32(s[b] ^ s[c], 7); \\
} while (0)

static void gemu_chacha20_xor(unsigned char *buf, size_t len, const unsigned char *nonce) {
    static const unsigned char sa[32] = {
        0x73,0x19,0xA4,0x5C,0xE2,0x0B,0x67,0x91,0x3D,0x88,0x4F,0xC6,0x12,0xEA,0x55,0x70,
        0xB9,0x24,0x6E,0xD3,0x08,0x9F,0x41,0xAC,0x57,0xE0,0x33,0x8A,0x1D,0x64,0xC9,0x2F
    };
    static const unsigned char sb[32] = {
        0xC4,0xA2,0x31,0x8F,0x59,0x7E,0xD0,0x26,0x95,0x41,0xFA,0x13,0xA7,0x3C,0x8E,0x19,
        0x0E,0x77,0xB5,0x42,0x6D,0x28,0xF4,0x19,0x92,0x5B,0x86,0x3F,0xA4,0xD1,0x78,0xE3
    };
    unsigned char key[32];
    for (int i = 0; i < 32; i++) key[i] = sa[i] ^ sb[i];
    uint32_t ctr = 1;
    size_t off = 0;
    while (off < len) {
        uint32_t st[16], wk[16];
        st[0] = 0x61707865u; st[1] = 0x3320646Eu; st[2] = 0x79622D32u; st[3] = 0x6B206574u;
        for (int i = 0; i < 8; i++) st[4 + i] = gemu_load32(key + i * 4);
        st[12] = ctr++;
        for (int i = 0; i < 3; i++) st[13 + i] = gemu_load32(nonce + i * 4);
        for (int i = 0; i < 16; i++) wk[i] = st[i];
        for (int r = 0; r < 10; r++) {
            GEMU_QR(wk, 0, 4, 8, 12); GEMU_QR(wk, 1, 5, 9, 13);
            GEMU_QR(wk, 2, 6, 10, 14); GEMU_QR(wk, 3, 7, 11, 15);
            GEMU_QR(wk, 0, 5, 10, 15); GEMU_QR(wk, 1, 6, 11, 12);
            GEMU_QR(wk, 2, 7, 8, 13); GEMU_QR(wk, 3, 4, 9, 14);
        }
        unsigned char stream[64];
        for (int i = 0; i < 16; i++) gemu_store32(stream + i * 4, wk[i] + st[i]);
        size_t chunk = len - off < 64 ? len - off : 64;
        for (size_t i = 0; i < chunk; i++) buf[off + i] ^= stream[i];
        off += chunk;
    }
    memset(key, 0, sizeof(key));
}

static mz_bool gemu_zip_reader_open(mz_zip_archive *archive, const char *jarpath) {
    static const unsigned char magic[8] = {'G','E','M','U','0','1',1,0};
    if (!jarpath) return MZ_FALSE;
    FILE *fp = fopen(jarpath, "rb");
    if (!fp) return MZ_FALSE;
    unsigned char hdr[20];
    size_t got = fread(hdr, 1, sizeof(hdr), fp);
    if (got < sizeof(hdr) || memcmp(hdr, magic, 8) != 0) {
        fclose(fp);
        return mz_zip_reader_init_file(archive, jarpath, 0);
    }
    call_once(&gemu_lock_once, gemu_init_lock);
    mtx_lock(&gemu_lock);
    unsigned char *cached_data = NULL;
    size_t cached_size = 0;
    for (int i = 0; i < gemu_cache_count; i++) {
        if (strcmp(gemu_cache[i].path, jarpath) == 0) {
            cached_data = gemu_cache[i].data;
            cached_size = gemu_cache[i].size;
            break;
        }
    }
    if (!cached_data) {
        fseek(fp, 0, SEEK_END);
        long fsize = ftell(fp);
        if (fsize > 20) {
            size_t payload = (size_t)(fsize - 20);
            unsigned char *plain = (unsigned char *)malloc(payload);
            if (plain) {
                fseek(fp, 20, SEEK_SET);
                if (fread(plain, 1, payload, fp) == payload) {
                    gemu_chacha20_xor(plain, payload, hdr + 8);
                    cached_data = plain;
                    cached_size = payload;
                    if (gemu_cache_count < 8) {
                        size_t plen = strlen(jarpath) + 1;
                        char *pcopy = (char *)malloc(plen);
                        if (pcopy) {
                            memcpy(pcopy, jarpath, plen);
                            gemu_cache[gemu_cache_count].path = pcopy;
                            gemu_cache[gemu_cache_count].data = cached_data;
                            gemu_cache[gemu_cache_count].size = cached_size;
                            gemu_cache_count++;
                        }
                    }
                } else {
                    free(plain);
                }
            }
        }
    }
    fclose(fp);
    mtx_unlock(&gemu_lock);
    if (!cached_data) return MZ_FALSE;
    return mz_zip_reader_init_mem(archive, cached_data, cached_size, 0);
}
"""
        zinclude = '#include "miniz_wrapper.h"\n'
        if zinclude not in ztext:
            raise RuntimeError("miniz_wrapper.c include marker no longer matches")
        ztext = ztext.replace(zinclude, zinclude + helper + "\n", 1)
        old_call = "mz_zip_reader_init_file(&zipArchive, jarpath, 0)"
        save_marker = "s32 zip_savefile_mem("
        save_pos = ztext.index(save_marker)
        save_end = ztext.index("s32 zip_savefile(", save_pos)
        before_save = ztext[:save_pos].replace(old_call, "gemu_zip_reader_open(&zipArchive, jarpath)")
        in_save = ztext[save_pos:save_end]
        after_save = ztext[save_end:].replace(old_call, "gemu_zip_reader_open(&zipArchive, jarpath)")
        ztext = before_save + in_save + after_save
        if ztext.count("gemu_zip_reader_open(&zipArchive, jarpath)") != 7:
            raise RuntimeError("Unexpected zip reader replacement count in miniz_wrapper.c")
        zipwrap.write_text(ztext, encoding="utf-8")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", type=Path, default=IOS / ".deps/miniJVM")
    print(prepare(parser.parse_args().runtime))
