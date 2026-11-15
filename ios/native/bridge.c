#include "emulator.h"
#include "jvm.h"
#include "jvm_util.h"
#include "garbage.h"
#include "jit.h"
#include "miniz.h"
#include "mbedtls/sha256.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_BMP
#define STBI_MAX_DIMENSIONS 4096
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

#if JIT_ENABLE
#error "MicroEmu must be built with JIT_ENABLE=0"
#endif

static once_flag initialized = ONCE_FLAG_INIT;
static mtx_t surface_lock, event_lock, archive_lock;
static int archive_count(uint64_t owner);
static EmSurface *surfaces;
static uint64_t next_surface = 1;
static size_t surface_bytes;
typedef struct EmSession {
    uint64_t id;
    int tab_id, retired, frame_seen;
    volatile u8 cancelled;
    size_t bytes, count;
    struct EmSession *next;
} EmSession;
static EmSession *sessions;
static uint64_t next_session = 1;
extern void microemu_io_release(MiniJVM *jvm, u64 owner);
extern int microemu_io_count(u64 owner);
extern void microemu_io_cancel(u64 owner);
typedef struct { int v[4]; char *text; } Event;
typedef struct TabQueue {
    int tab_id;
    Event events[256];
    int count;
    char *current_text;
    char *launch_jar;
    char *launch_rms;
    int sleeping;
    int stop_requested;
    int user_viewport;
    size_t text_bytes;
    struct TabQueue *next;
} TabQueue;
static TabQueue *tab_queues;
static int execution_failed;

static void initialize(void) {
    mtx_init(&surface_lock, mtx_plain);
    mtx_init(&event_lock, mtx_plain);
    mtx_init(&archive_lock, mtx_plain);
    jvm_init_mem_alloc();
}
static char *copy_text(const char *text) {
    if (!text) return NULL;
    size_t length = strlen(text);
    char *result = malloc(length + 1);
    if (result) memcpy(result, text, length + 1);
    return result;
}
static TabQueue *queue_for(int tab_id, int create_if_missing) {
    for (TabQueue *q = tab_queues; q; q = q->next) {
        if (q->tab_id == tab_id) return q;
    }
    if (!create_if_missing) return NULL;
    TabQueue *q = calloc(1, sizeof(*q));
    if (!q) return NULL;
    q->tab_id = tab_id;
    q->next = tab_queues;
    tab_queues = q;
    return q;
}
static void clear_queue_contents(TabQueue *q) {
    for (int i = 0; i < q->count; i++) free(q->events[i].text);
    q->count = 0;
    q->text_bytes = 0;
    free(q->current_text); q->current_text = NULL;
    free(q->launch_jar); q->launch_jar = NULL;
    free(q->launch_rms); q->launch_rms = NULL;
    q->sleeping = 0;
    q->stop_requested = 0;
    q->user_viewport = 0;
}
void em_tab_reset_events(int tab_id) {
    call_once(&initialized, initialize);
    mtx_lock(&event_lock);
    TabQueue *q = queue_for(tab_id, 0);
    if (q) clear_queue_contents(q);
    mtx_unlock(&event_lock);
}
void em_reset_events(void) {
    call_once(&initialized, initialize);
    mtx_lock(&event_lock);
    for (TabQueue *q = tab_queues; q; q = q->next) clear_queue_contents(q);
    mtx_unlock(&event_lock);
}
void em_tab_event(int tab_id, int type, int a, int b, int c, const char *text) {
    call_once(&initialized, initialize);
    mtx_lock(&event_lock);
    TabQueue *q = queue_for(tab_id, 1);
    if (q) {
        if (type == 10) {
            q->stop_requested = 1;
            mtx_unlock(&event_lock);
            return;
        }
        if (q->stop_requested) { mtx_unlock(&event_lock); return; }
        size_t bytes = text ? strlen(text) + 1 : 0;
        if (bytes > 16384 || bytes + q->text_bytes > 65536) { mtx_unlock(&event_lock); return; }
        /* Coalesce only adjacent motion/lifecycle updates; never reorder keys. */
        if (q->count && (type == 5 || type == 15 || type == 8 || type == 9)) {
            Event *last = &q->events[q->count - 1];
            if (last->v[0] == type || ((type == 8 || type == 9) && (last->v[0] == 8 || last->v[0] == 9))) {
                last->v[0] = type; last->v[1] = a; last->v[2] = b; last->v[3] = c;
                mtx_unlock(&event_lock); return;
            }
        }
        if (q->count == 256) {
            /* Cancel the overloaded gesture and release every delivered key.
             * Stop remains a separate latch and cannot be lost here. */
            for (int i = 0; i < q->count; i++) free(q->events[i].text);
            q->text_bytes = 0; q->count = 1;
            memset(&q->events[0], 0, sizeof(Event)); q->events[0].v[0] = 16;
            mtx_unlock(&event_lock); return;
        }
        Event *event = &q->events[q->count++];
        event->v[0] = type; event->v[1] = a; event->v[2] = b; event->v[3] = c;
        event->text = copy_text(text);
        q->text_bytes += event->text ? bytes : 0;
    }
    mtx_unlock(&event_lock);
}
void em_event(int type, int a, int b, int c, const char *text) {
    em_tab_event(0, type, a, b, c, text);
}
static void open_tab(int tab_id, const char *jar, const char *rms, int width, int height, int user_viewport) {
    call_once(&initialized, initialize);
    mtx_lock(&event_lock);
    TabQueue *q = queue_for(tab_id, 1);
    if (q) {
        clear_queue_contents(q);
        q->launch_jar = copy_text(jar);
        q->launch_rms = copy_text(rms);
        q->user_viewport = user_viewport;
    }
    mtx_unlock(&event_lock);
    em_tab_event(0, 100, tab_id, width, height, NULL);
}
void em_host_open_tab(int tab_id, const char *jar, const char *rms, int width, int height) {
    open_tab(tab_id, jar, rms, width, height, 0);
}
void em_host_open_tab_with_viewport(int tab_id, const char *jar, const char *rms, int width, int height) {
    open_tab(tab_id, jar, rms, width, height, 1);
}
void em_host_open_tab_fullscreen(int tab_id, const char *jar, const char *rms, int width, int height) {
    open_tab(tab_id, jar, rms, width, height, 2);
}
void em_host_sleep_tab(int tab_id, int sleeping) {
    call_once(&initialized, initialize);
    mtx_lock(&event_lock);
    TabQueue *q = queue_for(tab_id, 0);
    if (q) q->sleeping = sleeping ? 1 : 0;
    mtx_unlock(&event_lock);
    em_tab_event(tab_id, 15, sleeping ? 1 : 0, 0, 0, NULL);
}
void em_host_close_tab(int tab_id) {
    em_tab_event(tab_id, 10, 0, 0, 0, NULL);
}
void em_host_shutdown(void) {
    em_tab_event(0, 102, 0, 0, 0, NULL);
}
static EmSurface *find_surface(uint64_t id) {
    for (EmSurface *s = surfaces; s; s = s->next) if (s->id == id) return s;
    return NULL;
}
static EmSession *find_session(uint64_t id) {
    for (EmSession *s = sessions; s; s = s->next) if (s->id == id) return s;
    return NULL;
}
void em_tab_resource_stats(int tab_id, EmResourceStats *stats) {
    memset(stats, 0, sizeof(*stats));
    call_once(&initialized, initialize);
    mtx_lock(&surface_lock);
    for (EmSession *s = sessions; s; s = s->next)
        if (s->tab_id == tab_id && s->id > stats->generation) stats->generation = s->id;
    for (EmSurface *s = surfaces; s; s = s->next) if (s->owner == stats->generation) {
        stats->surface_count++; stats->surface_bytes += (size_t)s->width * s->height * 4;
    }
    stats->socket_count = microemu_io_count(stats->generation);
    mtx_unlock(&surface_lock);
    stats->zip_count = archive_count(stats->generation);
    mtx_lock(&event_lock);
    TabQueue *q = queue_for(tab_id, 0);
    if (q) stats->queue_bytes = q->text_bytes + (q->current_text ? strlen(q->current_text) + 1 : 0);
    mtx_unlock(&event_lock);
}
static EmSurface *new_surface(Runtime *r, int w, int h, uint32_t fill) {
    EmSession *owner = find_session(r->thrd_info->microemu_session);
    if (owner && (owner->cancelled || owner->retired)) return NULL;
    size_t bytes = (size_t)w * h * 4;
    if (owner && bytes > 128u * 1024u * 1024u - owner->bytes) return NULL;
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096 || (size_t)w * h * 4 > 256u * 1024u * 1024u - surface_bytes) return NULL;
    EmSurface *s = calloc(1, sizeof(*s));
    if (!s) return NULL;
    s->pixels = malloc((size_t)w * h * 4);
    if (!s->pixels) { free(s); return NULL; }
    s->id = next_surface++; s->owner = owner ? owner->id : 0;
    s->width = w; s->height = h; s->next = surfaces; surfaces = s;
    surface_bytes += (size_t)w * h * 4;
    if (owner) { owner->bytes += bytes; owner->count++; }
    for (int i = 0; i < w * h; i++) s->pixels[i] = fill;
    return s;
}
static char *string_copy(Runtime *r, Instance *value) {
    if (!value) return NULL;
    Utf8String *utf = utf8_create();
    jstring_2_utf8(value, utf, r);
    char *text = copy_text(utf8_cstr(utf));
    utf8_destroy(utf);
    return text;
}
#include "archive_io.inc"
static s32 create(Runtime *r, JClass *c) {
    mtx_lock(&surface_lock);
    EmSurface *s = new_surface(r, localvar_getInt(r->localvar, 0), localvar_getInt(r->localvar, 1), localvar_getInt(r->localvar, 2));
    push_long(r->stack, s ? s->id : 0);
    mtx_unlock(&surface_lock);
    return 0;
}
static s32 decode(Runtime *r, JClass *c) {
    Instance *bytes = localvar_getRefer(r->localvar, 0);
    int off = localvar_getInt(r->localvar, 1), len = localvar_getInt(r->localvar, 2), w, h, channels;
    unsigned char *rgba = NULL;
    if (bytes && off >= 0 && len >= 0 && (int64_t)off + len <= jarray_length(bytes))
        rgba = stbi_load_from_memory((unsigned char *)jarray_body(bytes) + off, len, &w, &h, &channels, 4);
    mtx_lock(&surface_lock);
    EmSurface *s = rgba ? new_surface(r, w, h, 0) : NULL;
    if (s) for (int i = 0; i < w * h; i++)
        s->pixels[i] = ((uint32_t)rgba[i*4+3]<<24)|((uint32_t)rgba[i*4]<<16)|((uint32_t)rgba[i*4+1]<<8)|rgba[i*4+2];
    push_long(r->stack, s ? s->id : 0);
    mtx_unlock(&surface_lock);
    stbi_image_free(rgba);
    return 0;
}
static s32 release(Runtime *r, JClass *c) {
    uint64_t id = localvar_getLong(r->localvar, 0);
    mtx_lock(&surface_lock);
    EmSurface **p = &surfaces;
    while (*p) {
        EmSurface *s = *p;
        if (s->id == id) {
            *p = s->next; size_t bytes = (size_t)s->width * s->height * 4;
            surface_bytes -= bytes;
            EmSession *owner = find_session(s->owner);
            if (owner) { owner->bytes -= bytes; owner->count--; }
            free(s->pixels); free(s); break;
        }
        p = &s->next;
    }
    mtx_unlock(&surface_lock);
    return 0;
}
static s32 width(Runtime *r, JClass *c) {
    mtx_lock(&surface_lock); EmSurface *s = find_surface(localvar_getLong(r->localvar, 0)); push_int(r->stack, s ? s->width : 0); mtx_unlock(&surface_lock); return 0;
}
static s32 height(Runtime *r, JClass *c) {
    mtx_lock(&surface_lock); EmSurface *s = find_surface(localvar_getLong(r->localvar, 0)); push_int(r->stack, s ? s->height : 0); mtx_unlock(&surface_lock); return 0;
}
static s32 pixels(Runtime *r, JClass *c) {
    Instance *array = localvar_getRefer(r->localvar, 2);
    int offset = localvar_getInt(r->localvar, 3), scan = localvar_getInt(r->localvar, 4);
    int x = localvar_getInt(r->localvar, 5), y = localvar_getInt(r->localvar, 6), w = localvar_getInt(r->localvar, 7), h = localvar_getInt(r->localvar, 8);
    int write = localvar_getInt(r->localvar, 9), alpha = localvar_getInt(r->localvar, 10);
    mtx_lock(&surface_lock); EmSurface *s = find_surface(localvar_getLong(r->localvar, 0));
    if (s && array && x >= 0 && y >= 0 && w >= 0 && h >= 0 && (int64_t)x + w <= s->width && (int64_t)y + h <= s->height) {
        uint32_t *data = (uint32_t *)jarray_body(array); int count = jarray_length(array);
        for (int yy = 0; yy < h; yy++) for (int xx = 0; xx < w; xx++) {
            int64_t index = (int64_t)offset + (int64_t)yy * scan + xx;
            if (index < 0 || index >= count) continue;
            uint32_t *p = &s->pixels[(y + yy) * s->width + x + xx];
            if (write) *p = alpha ? data[index] : data[index] | 0xff000000u; else data[index] = *p;
        }
    }
    mtx_unlock(&surface_lock);
    return 0;
}
static s32 draw(Runtime *r, JClass *c) {
    Instance *array = localvar_getRefer(r->localvar, 5);
    char *text = string_copy(r, localvar_getRefer(r->localvar, 6));
    mtx_lock(&surface_lock);
    EmSurface *s = find_surface(localvar_getLong(r->localvar, 0));
    EmSurface *source = find_surface(localvar_getLong(r->localvar, 2));
    if (s && array && jarray_length(array) >= 17) em_raster(s, source, localvar_getInt(r->localvar, 4), (int *)jarray_body(array), text);
    mtx_unlock(&surface_lock);
    free(text);
    return 0;
}
static void present_for_tab(int tab_id, uint64_t surface_id) {
    if (tab_id > 0) {
        mtx_lock(&event_lock);
        TabQueue *q = queue_for(tab_id, 0);
        int asleep = q ? q->sleeping : 0;
        mtx_unlock(&event_lock);
        if (asleep) return;
    }
    mtx_lock(&surface_lock);
    EmSurface *s = find_surface(surface_id);
    if (s) {
        EmSession *owner = find_session(s->owner);
        if (owner && !owner->frame_seen) {
            owner->frame_seen = 1;
            fprintf(stdout, "[SESSION] first-frame tab=%d generation=%llu size=%dx%d\n",
                tab_id, (unsigned long long)owner->id, s->width, s->height); fflush(stdout);
        }
        em_platform_present(tab_id, s);
    }
    mtx_unlock(&surface_lock);
}
static s32 present(Runtime *r, JClass *c) { present_for_tab(0, localvar_getLong(r->localvar, 0)); return 0; }
static s32 present_tab(Runtime *r, JClass *c) {
    present_for_tab(localvar_getInt(r->localvar, 0), localvar_getLong(r->localvar, 1));
    return 0;
}
static s32 text_width(Runtime *r, JClass *c) {
    char *text = string_copy(r, localvar_getRefer(r->localvar, 0));
    push_int(r->stack, em_platform_text_width(text ? text : "", localvar_getInt(r->localvar, 1), localvar_getInt(r->localvar, 2), localvar_getInt(r->localvar, 3)));
    free(text);
    return 0;
}
static int poll_for_tab(int tab_id, Instance *array) {
    if (tab_id == 0) em_platform_tick();
    int found = 0;
    mtx_lock(&event_lock);
    TabQueue *q = queue_for(tab_id, 0);
    if (q && array && jarray_length(array) >= 4 && q->count) {
        Event e = q->events[0];
        q->text_bytes -= e.text ? strlen(e.text) + 1 : 0;
        memcpy(jarray_body(array), e.v, sizeof(e.v));
        free(q->current_text); q->current_text = e.text;
        memmove(q->events, q->events + 1, (--q->count) * sizeof(Event));
        found = 1;
    }
    mtx_unlock(&event_lock);
    return found;
}
static s32 poll_event(Runtime *r, JClass *c) {
    push_int(r->stack, poll_for_tab(0, localvar_getRefer(r->localvar, 0)));
    return 0;
}
static s32 poll_tab(Runtime *r, JClass *c) {
    push_int(r->stack, poll_for_tab(localvar_getInt(r->localvar, 0), localvar_getRefer(r->localvar, 1)));
    return 0;
}
static s32 take_text_for_tab(Runtime *r, int tab_id) {
    mtx_lock(&event_lock);
    TabQueue *q = queue_for(tab_id, 0);
    char *owned = q ? q->current_text : NULL;
    if (q) q->current_text = NULL;
    mtx_unlock(&event_lock);
    /* Allocating a Java String may wait for GC. The UI/host poller must be
       able to enter event_lock while this thread is at a GC safepoint. */
    Instance *text = owned ? jstring_create_cstr(owned, r) : NULL;
    push_ref(r->stack, text);
    free(owned);
    return 0;
}
static s32 take_text(Runtime *r, JClass *c) { return take_text_for_tab(r, 0); }
static s32 take_text_tab(Runtime *r, JClass *c) { return take_text_for_tab(r, localvar_getInt(r->localvar, 0)); }
static s32 take_launch_path(Runtime *r, int jar) {
    int tab_id = localvar_getInt(r->localvar, 0);
    mtx_lock(&event_lock);
    TabQueue *q = queue_for(tab_id, 0);
    char *owned = q ? (jar ? q->launch_jar : q->launch_rms) : NULL;
    if (q) {
        if (jar) q->launch_jar = NULL;
        else q->launch_rms = NULL;
    }
    mtx_unlock(&event_lock);
    Instance *value = owned ? jstring_create_cstr(owned, r) : NULL;
    push_ref(r->stack, value);
    free(owned);
    return 0;
}
static s32 take_tab_jar(Runtime *r, JClass *c) { return take_launch_path(r, 1); }
static s32 take_tab_rms(Runtime *r, JClass *c) { return take_launch_path(r, 0); }
static void modal_for_tab(Runtime *r, int tab_id, int offset) {
    char *title = string_copy(r, localvar_getRefer(r->localvar, offset));
    char *value = string_copy(r, localvar_getRefer(r->localvar, offset + 1));
    Instance *array = localvar_getRefer(r->localvar, offset + 4);
    int count = array ? jarray_length(array) : 0;
    char **labels = calloc(count ? count : 1, sizeof(char *));
    if (labels) for (int i = 0; i < count; i++) labels[i] = string_copy(r, (__refer)jarray_get_field(array, i));
    em_platform_modal(tab_id, title, value, localvar_getInt(r->localvar, offset + 2), localvar_getInt(r->localvar, offset + 3), (const char **)labels, labels ? count : 0);
    if (labels) for (int i = 0; i < count; i++) free(labels[i]);
    free(labels); free(title); free(value);
}
static s32 modal(Runtime *r, JClass *c) { modal_for_tab(r, 0, 0); return 0; }
static s32 modal_tab(Runtime *r, JClass *c) { modal_for_tab(r, localvar_getInt(r->localvar, 0), 1); return 0; }
static s32 status(Runtime *r, JClass *c) {
    char *text = string_copy(r, localvar_getRefer(r->localvar, 0));
    em_platform_status(0, text ? text : "");
    free(text);
    return 0;
}
static s32 status_tab(Runtime *r, JClass *c) {
    char *text = string_copy(r, localvar_getRefer(r->localvar, 1));
    em_platform_status(localvar_getInt(r->localvar, 0), text ? text : "");
    free(text);
    return 0;
}
static s32 failed(Runtime *r, JClass *c) { execution_failed = 1; return status(r, c); }
static s32 failed_tab(Runtime *r, JClass *c) { return status_tab(r, c); }
static s32 finished_tab(Runtime *r, JClass *c) {
    em_platform_tab_finished(localvar_getInt(r->localvar, 0), localvar_getInt(r->localvar, 1));
    return 0;
}
static s32 browse(Runtime *r, JClass *c) {
    char *text = string_copy(r, localvar_getRefer(r->localvar, 0));
    if (text) em_platform_browse(text);
    free(text);
    return 0;
}
static s32 vibrate(Runtime *r, JClass *c) { em_platform_vibrate(localvar_getInt(r->localvar, 0)); return 0; }
static s32 valid_viewport(Runtime *r, JClass *c) {
    push_int(r->stack, em_viewport_valid(localvar_getInt(r->localvar, 0), localvar_getInt(r->localvar, 1)));
    return 0;
}
static s32 user_viewport_tab(Runtime *r, JClass *c) {
    mtx_lock(&event_lock);
    TabQueue *q = queue_for(localvar_getInt(r->localvar, 0), 0);
    push_int(r->stack, q && q->user_viewport);
    mtx_unlock(&event_lock);
    return 0;
}
static s32 user_stop_requested(Runtime *r, JClass *c) {
    mtx_lock(&event_lock);
    TabQueue *q = queue_for(localvar_getInt(r->localvar, 0), 0);
    push_int(r->stack, q && q->stop_requested);
    mtx_unlock(&event_lock);
    return 0;
}
static s32 fullscreen_tab(Runtime *r, JClass *c) {
    mtx_lock(&event_lock);
    TabQueue *q = queue_for(localvar_getInt(r->localvar, 0), 0);
    push_int(r->stack, q && q->user_viewport == 2);
    mtx_unlock(&event_lock);
    return 0;
}
static s32 prepare_viewport_retry(Runtime *r, JClass *c) {
    if (r->thrd_info->microemu_session) return RUNTIME_STATUS_ERROR;
    mtx_lock(&event_lock);
    TabQueue *q = queue_for(localvar_getInt(r->localvar, 0), 1);
    if (q) q->user_viewport = 2;
    int sleeping = q && q->sleeping;
    mtx_unlock(&event_lock);
    if (sleeping) em_tab_event(localvar_getInt(r->localvar, 0), 15, 1, 0, 0, NULL);
    return 0;
}
static s32 first_frame_seen(Runtime *r, JClass *c) {
    mtx_lock(&surface_lock);
    EmSession *s = find_session(localvar_getLong(r->localvar, 0));
    push_int(r->stack, s && s->frame_seen);
    mtx_unlock(&surface_lock);
    return 0;
}
static s32 sha256_file(Runtime *r, JClass *c) {
    char *path = string_copy(r, localvar_getRefer(r->localvar, 0));
    char hex[65]; int ok = 0;
    jthread_block_enter(r);
    FILE *file = path ? fopen(path, "rb") : NULL;
    if (file) {
        mbedtls_sha256_context hash; unsigned char buffer[8192], digest[32]; size_t n;
        mbedtls_sha256_init(&hash); mbedtls_sha256_starts(&hash, 0);
        while ((n = fread(buffer, 1, sizeof(buffer), file)) != 0) {
            mbedtls_sha256_update(&hash, buffer, n);
            if (r->thrd_info->is_stop) break;
        }
        ok = !ferror(file) && !r->thrd_info->is_stop;
        mbedtls_sha256_finish(&hash, digest); mbedtls_sha256_free(&hash); fclose(file);
        for (int i = 0; i < 32; i++) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    }
    jthread_block_exit(r); free(path);
    push_ref(r->stack, ok ? jstring_create_cstr(hex, r) : NULL);
    return 0;
}
static s32 begin_session(Runtime *r, JClass *c) {
    if (r->thrd_info->microemu_session) return RUNTIME_STATUS_ERROR;
    EmSession *s = calloc(1, sizeof(*s));
    if (!s) return exception_throw_out_of_memory(r);
    mtx_lock(&surface_lock);
    s->id = next_session++; s->tab_id = localvar_getInt(r->localvar, 0);
    s->next = sessions; sessions = s;
    push_long(r->stack, s->id);
    mtx_unlock(&surface_lock);
    return 0;
}
static s32 bind_session(Runtime *r, JClass *c) {
    if (r->thrd_info->microemu_session) return RUNTIME_STATUS_ERROR;
    mtx_lock(&surface_lock);
    EmSession *s = find_session(localvar_getLong(r->localvar, 0));
    if (s) {
        r->thrd_info->microemu_session = s->id;
        r->thrd_info->microemu_cancelled = &s->cancelled;
    }
    int cancelled = !s || s->cancelled || s->retired;
    mtx_unlock(&surface_lock);
    if (cancelled) { r->thrd_info->is_stop = 1; return RUNTIME_STATUS_ERROR; }
    return 0;
}
static s32 stop_requested(Runtime *r, JClass *c) {
    int tab = localvar_getInt(r->localvar, 0);
    if (tab == 0) em_platform_tick();
    mtx_lock(&event_lock);
    TabQueue *q = queue_for(tab, 0);
    int stop = q && q->stop_requested;
    mtx_unlock(&event_lock);
    mtx_lock(&surface_lock);
    for (EmSession *s = sessions; s; s = s->next)
        if (s->tab_id == tab && !s->retired && s->cancelled) stop = 1;
    mtx_unlock(&surface_lock);
    push_int(r->stack, stop);
    return 0;
}
static int session_threads(Runtime *r, uint64_t id, int cancel) {
    int count = 0;
    spin_lock(&r->jvm->thread_list->spinlock);
    for (int i = 0; i < r->jvm->thread_list->length; i++) {
        Runtime *t = arraylist_get_value_unsafe(r->jvm->thread_list, i);
        JavaThreadInfo *ti = t->thrd_info;
        if (ti->microemu_session != id || ti->thread_status == THREAD_STATUS_ZOMBIE) continue;
        count++;
        if (cancel && !ti->microemu_exiting) { ti->is_stop = 1; jthread_wakeup(t); }
    }
    spin_unlock(&r->jvm->thread_list->spinlock);
    return count;
}
static s32 cancel_session(Runtime *r, JClass *c) {
    if (r->thrd_info->microemu_session) return RUNTIME_STATUS_ERROR;
    uint64_t id = localvar_getLong(r->localvar, 0);
    mtx_lock(&surface_lock);
    EmSession *s = find_session(id);
    if (s) s->cancelled = 1;
    mtx_unlock(&surface_lock);
    microemu_io_cancel(id);
    push_int(r->stack, session_threads(r, id, 1));
    return 0;
}
static s32 release_session(Runtime *r, JClass *c) {
    if (r->thrd_info->microemu_session) return RUNTIME_STATUS_ERROR;
    uint64_t id = localvar_getLong(r->localvar, 0);
    if (session_threads(r, id, 0)) { push_int(r->stack, 0); return 0; }
    microemu_io_release(r->jvm, id);
    archive_release(id, 0);
    mtx_lock(&surface_lock);
    EmSession *owner = find_session(id);
    if (owner) {
        owner->cancelled = 1; owner->retired = 1;
        EmSurface **p = &surfaces;
        while (*p) {
            EmSurface *s = *p;
            if (s->owner != id) { p = &s->next; continue; }
            *p = s->next; surface_bytes -= (size_t)s->width * s->height * 4;
            free(s->pixels); free(s);
        }
        owner->bytes = owner->count = 0;
        fprintf(stdout, "[SESSION] reclaimed tab=%d generation=%llu threads=0 tcp_sockets=%d surfaces=0 bytes=0\n",
                owner->tab_id, (unsigned long long)id, microemu_io_count(id)); fflush(stdout);
    }
    mtx_unlock(&surface_lock);
    if (owner) {
        mtx_lock(&event_lock);
        TabQueue *q = queue_for(owner->tab_id, 0);
        if (q) {
            /* A fullscreen retry keeps the tab's Stop/sleep/selection controls.
             * A new external launch resets them through open_tab(). */
            int stop = q->stop_requested, sleep = q->sleeping, mode = q->user_viewport;
            clear_queue_contents(q);
            q->stop_requested = stop; q->sleeping = sleep; q->user_viewport = mode;
        }
        mtx_unlock(&event_lock);
    }
    push_int(r->stack, 1);
    return 0;
}
#define METHOD(name,signature,fn) {"org/microemu/ios/NativeBridge",name,signature,fn}
static java_native_method methods[] = {
    METHOD("archiveOpen","(Ljava/lang/String;Ljava/lang/String;)J",archive_open_native),
    METHOD("archiveRead","(J[BII)I",archive_read_native),METHOD("archiveRemaining","(J)J",archive_remaining_native),
    METHOD("archiveRewind","(J)Z",archive_rewind_native),METHOD("archiveClose","(J)V",archive_close_native),
    METHOD("archiveCount","()I",archive_count_native),
    METHOD("validViewport","(II)Z",valid_viewport),METHOD("userViewportTab","(I)Z",user_viewport_tab),
    METHOD("fullScreenTab","(I)Z",fullscreen_tab),METHOD("prepareViewportRetry","(I)V",prepare_viewport_retry),
    METHOD("firstFrameSeen","(J)Z",first_frame_seen),
    METHOD("userStopRequested","(I)Z",user_stop_requested),
    METHOD("sha256File","(Ljava/lang/String;)Ljava/lang/String;",sha256_file),
    METHOD("beginSession","(I)J",begin_session),METHOD("bindSession","(J)V",bind_session),
    METHOD("stopRequested","(I)Z",stop_requested),METHOD("cancelSession","(J)I",cancel_session),
    METHOD("releaseSession","(J)Z",release_session),
    METHOD("create","(III)J",create),METHOD("decode","([BII)J",decode),METHOD("release","(J)V",release),
    METHOD("width","(J)I",width),METHOD("height","(J)I",height),METHOD("pixels","(J[IIIIIIIZZ)V",pixels),
    METHOD("draw","(JJI[ILjava/lang/String;)V",draw),
    METHOD("present","(J)V",present),METHOD("presentTab","(IJ)V",present_tab),
    METHOD("textWidth","(Ljava/lang/String;III)I",text_width),
    METHOD("poll","([I)I",poll_event),METHOD("pollTab","(I[I)I",poll_tab),
    METHOD("takeText","()Ljava/lang/String;",take_text),METHOD("takeTextTab","(I)Ljava/lang/String;",take_text_tab),
    METHOD("takeTabJar","(I)Ljava/lang/String;",take_tab_jar),METHOD("takeTabRms","(I)Ljava/lang/String;",take_tab_rms),
    METHOD("modal","(Ljava/lang/String;Ljava/lang/String;II[Ljava/lang/String;)V",modal),
    METHOD("modalTab","(ILjava/lang/String;Ljava/lang/String;II[Ljava/lang/String;)V",modal_tab),
    METHOD("status","(Ljava/lang/String;)V",status),METHOD("statusTab","(ILjava/lang/String;)V",status_tab),
    METHOD("failed","(Ljava/lang/String;)V",failed),METHOD("failedTab","(ILjava/lang/String;)V",failed_tab),
    METHOD("finishedTab","(II)V",finished_tab),
    METHOD("browse","(Ljava/lang/String;)V",browse),METHOD("vibrate","(I)V",vibrate)
};

static int64_t configured_heap_mb = 256;
static int64_t configured_vm_mb = 768;

void em_configure_memory_bytes(uint64_t physical_bytes) {
    uint64_t ram_mb = physical_bytes / (1024ULL * 1024ULL);
    if (ram_mb > 0 && ram_mb <= 1536) {
        configured_heap_mb = 96;
        configured_vm_mb = 256;
    } else if (ram_mb > 0 && ram_mb <= 2560) {
        configured_heap_mb = 160;
        configured_vm_mb = 384;
    } else {
        configured_heap_mb = 256;
        configured_vm_mb = 768;
    }
}

static void configure_jvm_memory(MiniJVM *jvm) {
    jvm->max_heap_size = configured_heap_mb * 1024LL * 1024LL;
    jvm->max_vm_memory = configured_vm_mb * 1024LL * 1024LL;
}

int em_jar_read_entry(const char *jar_path, const char *entry_name, void **out_data, size_t *out_size) {
    if (out_data) *out_data = NULL;
    if (out_size) *out_size = 0;
    if (!jar_path || !entry_name || !out_data || !out_size) return 0;
    while (*entry_name == '/') entry_name++;
    if (!*entry_name) return 0;
    mz_zip_archive zip;
    memset(&zip, 0, sizeof(zip));
    if (!mz_zip_reader_init_file(&zip, jar_path, 0)) return 0;
    size_t size = 0;
    void *data = mz_zip_reader_extract_file_to_heap(&zip, entry_name, &size, MZ_ZIP_FLAG_CASE_SENSITIVE);
    if (!data) data = mz_zip_reader_extract_file_to_heap(&zip, entry_name, &size, 0);
    mz_zip_reader_end(&zip);
    if (!data) return 0;
    *out_data = data;
    *out_size = size;
    return 1;
}

static int em_case_ends_with(const char *str, const char *suffix) {
    size_t slen = strlen(str);
    size_t xlen = strlen(suffix);
    if (slen < xlen) return 0;
    const char *p = str + slen - xlen;
    while (*p && *suffix) {
        char a = (*p >= 'A' && *p <= 'Z') ? *p + 32 : *p;
        char b = (*suffix >= 'A' && *suffix <= 'Z') ? *suffix + 32 : *suffix;
        if (a != b) return 0;
        p++; suffix++;
    }
    return 1;
}

int em_jar_read_manifest(const char *jar_path, void **out_data, size_t *out_size) {
    if (out_data) *out_data = NULL;
    if (out_size) *out_size = 0;
    if (!jar_path || !out_data || !out_size) return 0;
    if (em_jar_read_entry(jar_path, "META-INF/MANIFEST.MF", out_data, out_size)) return 1;
    if (em_jar_read_entry(jar_path, "MANIFEST.MF", out_data, out_size)) return 1;
    mz_zip_archive zip;
    memset(&zip, 0, sizeof(zip));
    if (!mz_zip_reader_init_file(&zip, jar_path, 0)) return 0;
    int found_index = -1;
    for (mz_uint i = 0; i < zip.m_total_files; i++) {
        mz_zip_archive_file_stat st;
        if (mz_zip_reader_file_stat(&zip, i, &st)) {
            const char *fn = st.m_filename;
            if (em_case_ends_with(fn, "manifest.mf")) {
                found_index = (int)i;
                break;
            }
            if (found_index < 0 && em_case_ends_with(fn, ".jad")) {
                found_index = (int)i;
            }
        }
    }
    if (found_index >= 0) {
        size_t size = 0;
        void *data = mz_zip_reader_extract_to_heap(&zip, (mz_uint)found_index, &size, 0);
        mz_zip_reader_end(&zip);
        if (data) {
            *out_data = data;
            *out_size = size;
            return 1;
        }
        return 0;
    }
    mz_zip_reader_end(&zip);
    return 0;
}

void em_jar_free(void *data) {
    if (data) mz_free(data);
}

static int run_jvm_entry(const char *boot, const char *classpath, const char *entry, ArrayList *args) {
    fprintf(stderr, "[RUNTIME] Initializing interpreter (%s)\n", entry); fflush(stderr);
    call_once(&initialized, initialize);
    execution_failed = 0;
    MiniJVM *jvm = jvm_create();
    if (!jvm) { em_platform_status(0, "Cannot create JVM"); return -1; }
    configure_jvm_memory(jvm);
    jvm->jdwp_enable = 0;
    if (jvm_init(jvm, (char *)boot, (char *)classpath)) { em_platform_status(0, "Cannot initialize Java runtime"); return -1; }
#if defined(__ANDROID__)
    sys_properties_set_c(jvm, "microemu.platform", "MicroEmu-Android");
#endif
    native_reg_lib(jvm, methods, sizeof(methods) / sizeof(methods[0]));
    int result = call_main(jvm, (char *)entry, args);
    if (result == RUNTIME_STATUS_ERROR && jvm->collector->exit_flag) result = jvm->collector->exit_code;
    /* JVM shutdown has joined its Java threads before destroying their heap. */
    jvm_destroy(jvm);
    archive_release(0, 1);
    mtx_lock(&surface_lock);
    while (surfaces) { EmSurface *s = surfaces; surfaces = s->next; free(s->pixels); free(s); }
    surface_bytes = 0;
    while (sessions) { EmSession *s = sessions; sessions = s->next; free(s); }
    mtx_unlock(&surface_lock);
    em_reset_events();
    return result ? result : execution_failed;
}

int em_run(const char *boot, const char *classpath, const char *jar, const char *rms, int width, int height) {
    char width_text[16], height_text[16];
    snprintf(width_text, sizeof(width_text), "%d", width);
    snprintf(height_text, sizeof(height_text), "%d", height);
    ArrayList *args = arraylist_create(4);
    arraylist_push_back(args, (void *)jar);
    arraylist_push_back(args, (void *)rms);
    arraylist_push_back(args, width_text);
    arraylist_push_back(args, height_text);
    int result = run_jvm_entry(boot, classpath, "org.microemu.ios.IOSRuntime", args);
    arraylist_destroy(args);
    return result;
}

int em_host_run(const char *boot, const char *classpath) {
    ArrayList *args = arraylist_create(1);
    arraylist_push_back(args, (void *)classpath);
    int result = run_jvm_entry(boot, classpath, "org.microemu.ios.IOSHost", args);
    arraylist_destroy(args);
    return result;
}
