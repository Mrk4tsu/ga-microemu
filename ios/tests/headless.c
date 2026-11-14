#include "emulator.h"
#include "tinycthread.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

static const char *frame_path;
static double started, stop_after = 20, last_frame, multi_sleep_at;
static int frames, stopped;
static int multi_tab, multi_stage, tab_frames[8], tab_finished[8];
static int host_mode, stress_sent;
static double stress_scanned;
static mtx_t host_lock;
static once_flag host_lock_once = ONCE_FLAG_INIT;
static void init_host_lock(void) { mtx_init(&host_lock, mtx_plain); }
static stbtt_fontinfo font;
static unsigned char *font_data;
static int have_font;
static long control_offset;
static double control_scanned;
typedef struct { int ms, type, a, b; } Scheduled;
static Scheduled schedule[256];
static int scheduled, next_event;
static double seconds(void) { struct timespec t; timespec_get(&t, TIME_UTC); return t.tv_sec + t.tv_nsec / 1e9; }
static int codepoint(const unsigned char **text) {
    unsigned c = *(*text)++; if (c < 128) return c;
    int n = c < 224 ? 1 : c < 240 ? 2 : 3;
    unsigned value = c & ((1 << (6 - n)) - 1);
    while (n-- && **text) { value = (value << 6) | (*(*text)++ & 63); }
    return value;
}
int em_platform_text_width(const char *text, int size, int style, int face) {
    if (!have_font) return (int)strlen(text) * size * 3 / 5;
    float scale = stbtt_ScaleForPixelHeight(&font, (float)size); float width = 0;
    const unsigned char *p = (const unsigned char *)text;
    while (*p) { int advance; stbtt_GetCodepointHMetrics(&font, codepoint(&p), &advance, NULL); width += advance * scale; }
    return (int)(width + 0.5f);
}
void em_platform_text(EmSurface *s, const char *text, const int *a) {
    if (!have_font) return;
    float scale = stbtt_ScaleForPixelHeight(&font, (float)a[14]); int x = a[6];
    const unsigned char *p = (const unsigned char *)text;
    while (*p) {
        int cp = codepoint(&p), w, h, xoff, yoff, advance;
        unsigned char *bitmap = stbtt_GetCodepointBitmap(&font, 0, scale, cp, &w, &h, &xoff, &yoff);
        for (int y = 0; y < h; y++) for (int xx = 0; xx < w; xx++)
            em_blend(s, x + xoff + xx, a[7] + a[14] + yoff + y, ((uint32_t)bitmap[y * w + xx] << 24) | (uint32_t)a[0], a + 1);
        stbtt_FreeBitmap(bitmap, NULL); stbtt_GetCodepointHMetrics(&font, cp, &advance, NULL);
        x += (int)(advance * scale + 0.5f);
    }
}
void em_platform_present(int tab_id, const EmSurface *s) {
    call_once(&host_lock_once, init_host_lock);
    mtx_lock(&host_lock);
    frames++;
    if (tab_id >= 0 && tab_id < 8) tab_frames[tab_id]++;
    double now = seconds();
    int write_frame = frame_path && now - last_frame >= 1;
    if (write_frame) last_frame = now;
    mtx_unlock(&host_lock);
    if (!write_frame) return;
    unsigned char *rgba = malloc((size_t)s->width * s->height * 4);
    if (!rgba) return;
    for (int i = 0; i < s->width * s->height; i++) {
        uint32_t p = s->pixels[i];
        rgba[4 * i] = p >> 16; rgba[4 * i + 1] = p >> 8; rgba[4 * i + 2] = p; rgba[4 * i + 3] = p >> 24;
    }
    stbi_write_png(frame_path, s->width, s->height, 4, rgba, s->width * 4);
    free(rgba);
}
void em_platform_status(int tab_id, const char *s) { printf("[STATUS tab=%d] %s\n", tab_id, s); fflush(stdout); }
void em_platform_modal(int tab_id, const char *t, const char *v, int max, int constraints, const char **labels, int count) {
    if (!t) return;
    printf("[MODAL tab=%d] %s (%d commands)", tab_id, t, count);
    for (int i = 0; i < count; i++) printf(" [%s]", labels[i] ? labels[i] : "");
    puts("");
    /* Explicit opt-in only. Text is read from a pipe, never from command-line
       arguments or logs; the iOS app does not include this test adapter. */
    if (max > 0 && getenv("MICROEMU_TEST_TEXT_INPUT")) {
        char input[2048];
        if (fgets(input, sizeof(input), stdin)) {
            input[strcspn(input, "\r\n")] = 0; int command = 0;
            for (int i = 0; i < count; i++)
                if (labels[i] && (!strcmp(labels[i], "OK") || !strcmp(labels[i], "Done") || !strcmp(labels[i], "Xong"))) command = i;
            em_tab_event(tab_id, 7, command, 0, 0, input); memset(input, 0, sizeof(input));
        }
    }
}
static void test_event(int type, int a, int b, int c, const char *text) {
    if (host_mode) em_tab_event(1, type, a, b, c, text);
    else em_event(type, a, b, c, text);
}
void em_platform_tab_finished(int tab_id, int result) {
    call_once(&host_lock_once, init_host_lock);
    mtx_lock(&host_lock);
    if (tab_id >= 0 && tab_id < 8) tab_finished[tab_id] = result == 0 ? 1 : -1;
    printf("[TAB_FINISHED tab=%d result=%d]\n", tab_id, result);
    if (host_mode && tab_id == 1) {
        stopped = 1; em_host_shutdown();
    }
    if (multi_tab && tab_finished[1] && tab_finished[2] && !stopped) {
        stopped = 1;
        em_host_shutdown();
    }
    mtx_unlock(&host_lock);
}
void em_platform_browse(const char *s) { printf("[BROWSE] %s\n", s); }
void em_platform_vibrate(int ms) { }
void em_platform_tick(void) {
    double elapsed = (seconds() - started) * 1000;
    const char *control = getenv("MICROEMU_CONTROL_FILE");
    if (control && elapsed - control_scanned >= 100) {
        control_scanned = elapsed; FILE *file = fopen(control, "r");
        if (file) {
            fseek(file, control_offset, SEEK_SET); char line[4096];
            while (fgets(line, sizeof(line), file)) {
                int type, a, b, c, consumed = 0;
                if (sscanf(line, "%d %d %d %d%n", &type, &a, &b, &c, &consumed) == 4) {
                    char *text = line + consumed; while (*text == ' ' || *text == '\t') text++;
                    text[strcspn(text, "\r\n")] = 0;
                    test_event(type, a, b, c, (type == 7 || type == 12) ? text : NULL);
                }
                memset(line, 0, sizeof(line));
            }
            control_offset = ftell(file); fclose(file);
        }
    }
    while (next_event < scheduled && elapsed >= schedule[next_event].ms) {
        Scheduled *e = &schedule[next_event++];
        test_event(e->type, e->a, e->b, 0, NULL);
    }
    if (multi_tab) {
        int action = 0;
        call_once(&host_lock_once, init_host_lock);
        mtx_lock(&host_lock);
        if (multi_stage == 0 && tab_frames[1] > 0 && tab_frames[2] > 0) {
            multi_stage = 1;
            multi_sleep_at = elapsed;
            action = 1;
        } else if (multi_stage == 1 && elapsed - multi_sleep_at >= 50) {
            multi_stage = 2;
            action = 2;
        }
        mtx_unlock(&host_lock);
        if (getenv("MICROEMU_INPUT_STRESS") && multi_stage >= 2 && stress_sent < 48 && elapsed - stress_scanned >= 12) {
            stress_scanned = elapsed; stress_sent++;
            em_tab_event(1, 12, 0, 0, 0, "z");
            em_tab_event(2, 12, 0, 0, 0, "z");
        }
        if (action == 1) {
            em_host_sleep_tab(1, 1);
        } else if (action == 2) {
            em_host_sleep_tab(1, 0);
            em_tab_event(1, 12, 0, 0, 0, "Test42");
            em_tab_event(2, 12, 0, 0, 0, "Test42");
        }
    }
    if (!stopped && elapsed >= stop_after * 1000) {
        stopped = 1;
        if (host_mode) em_host_close_tab(1);
        else if (multi_tab) em_host_shutdown();
        else em_event(10, 0, 0, 0, NULL);
    }
}
int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "Usage: microemu-headless bootstrap.jar emulator.jar game.jar rms-dir [seconds] [frame.png] [events.txt] [font.ttf]\n");
        return 2;
    }
    if (argc > 5) stop_after = atof(argv[5]);
    if (argc > 6) frame_path = argv[6];
    if (argc > 7) {
        FILE *f = fopen(argv[7], "r");
        if (f) {
            while (scheduled < 256 && fscanf(f, "%d %d %d %d", &schedule[scheduled].ms, &schedule[scheduled].type, &schedule[scheduled].a, &schedule[scheduled].b) == 4) scheduled++;
            fclose(f);
        }
    }
    if (argc > 8) {
        FILE *f = fopen(argv[8], "rb");
        if (f) {
            fseek(f, 0, SEEK_END); long length = ftell(f); rewind(f); font_data = malloc(length);
            if (font_data && fread(font_data, 1, length, f) == (size_t)length) have_font = stbtt_InitFont(&font, font_data, 0);
            fclose(f);
        }
    }
    setvbuf(stdout, NULL, _IONBF, 0);
    {
        void *mf = NULL;
        size_t mf_size = 0;
        if (em_jar_read_manifest(argv[3], &mf, &mf_size) && mf && mf_size > 0) {
            em_jar_free(mf);
        } else {
            fprintf(stderr, "[HEADLESS] Note: JAR has no manifest in archive; continuing with runtime auto-detection\n");
        }
    }
    if (getenv("MICROEMU_HOST_MODE")) {
        host_mode = 1;
        started = seconds(); em_reset_events();
        em_host_open_tab(1, argv[3], argv[4], 348, 440);
        int result = em_host_run(argv[1], argv[2]);
        printf("[HOST] result=%d frames=%d finished=%d\n", result, frames, tab_finished[1]);
        free(font_data);
        return result ? result : (tab_finished[1] == 1 && frames > 0 ? 0 : 3);
    }
    if (getenv("MICROEMU_MULTI_TAB")) {
        multi_tab = 1;
        started = seconds();
        em_reset_events();
        char rms1[4096], rms2[4096];
        snprintf(rms1, sizeof(rms1), "%s/tab1", argv[4]);
        snprintf(rms2, sizeof(rms2), "%s/tab2", argv[4]);
        em_host_open_tab(1, argv[3], rms1, 390, 460);
        em_host_open_tab(2, argv[3], rms2, 390, 460);
        int result = em_host_run(argv[1], argv[2]);
        printf("[MULTI_TAB] result=%d tab1_frames=%d tab2_frames=%d tab1_done=%d tab2_done=%d\n",
               result, tab_frames[1], tab_frames[2], tab_finished[1], tab_finished[2]);
        free(font_data);
        if (result || tab_finished[1] != 1 || tab_finished[2] != 1 || tab_frames[1] == 0 || tab_frames[2] == 0) return result ? result : 3;
        return 0;
    }
    const char *repeat = getenv("MICROEMU_TEST_REPEATS");
    int runs = repeat ? atoi(repeat) : 1;
    if (runs < 1 || runs > 3) return 2;
    int result = 0;
    for (int i = 0; i < runs; i++) {
        frames = stopped = next_event = 0; control_offset = 0; control_scanned = 0; last_frame = 0;
        started = seconds(); em_reset_events();
        result = em_run(argv[1], argv[2], argv[3], argv[4], 480, 320);
        printf("[RESULT] status=%d frames=%d elapsed=%.2f interpreter-only=1 run=%d\n", result, frames, seconds() - started, i + 1);
        if (result || (!frames && !getenv("MICROEMU_ALLOW_NO_FRAME"))) { result = result ? result : 3; break; }
    }
    free(font_data);
    return result;
}
