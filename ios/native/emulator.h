#ifndef MICROEMU_IOS_EMULATOR_H
#define MICROEMU_IOS_EMULATOR_H
#include <stdint.h>
#include <stddef.h>

#define EM_VIEWPORT_MIN 128
#define EM_VIEWPORT_MAX 1920
static inline int em_viewport_valid(int width, int height) {
    return width >= EM_VIEWPORT_MIN && width <= EM_VIEWPORT_MAX &&
           height >= EM_VIEWPORT_MIN && height <= EM_VIEWPORT_MAX;
}

typedef struct EmSurface {
    uint64_t id;
    int width, height;
    uint32_t *pixels; /* straight alpha, 0xAARRGGBB */
    struct EmSurface *next;
    uint64_t owner; /* Session generation, never reused during this process. */
} EmSurface;
typedef struct EmResourceStats {
    uint64_t generation;
    size_t surface_count, surface_bytes, queue_bytes;
    int socket_count;
} EmResourceStats;
void em_tab_resource_stats(int tab_id, EmResourceStats *stats);

int em_run(const char *bootstrap, const char *classpath, const char *jar,
           const char *rms, int width, int height);
int em_host_run(const char *bootstrap, const char *classpath);
void em_host_open_tab(int tab_id, const char *jar, const char *rms, int width, int height);
void em_host_open_tab_with_viewport(int tab_id, const char *jar, const char *rms, int width, int height);
void em_host_open_tab_fullscreen(int tab_id, const char *jar, const char *rms, int width, int height);
void em_host_sleep_tab(int tab_id, int sleeping);
void em_host_close_tab(int tab_id);
void em_host_shutdown(void);
void em_configure_memory_bytes(uint64_t physical_bytes);
void em_event(int type, int a, int b, int c, const char *text);
void em_tab_event(int tab_id, int type, int a, int b, int c, const char *text);
void em_reset_events(void);
void em_tab_reset_events(int tab_id);
void em_blend(EmSurface *surface, int x, int y, uint32_t argb, const int *clip);
void em_raster(EmSurface *target, EmSurface *source, int operation, const int *args, const char *text);
int em_jar_read_entry(const char *jar_path, const char *entry_name, void **out_data, size_t *out_size);
int em_jar_read_manifest(const char *jar_path, void **out_data, size_t *out_size);
void em_jar_free(void *data);

/* Platform functions: UIKit/CoreText in the app; deterministic headless host in tests. */
void em_platform_present(int tab_id, const EmSurface *surface);
int em_platform_text_width(const char *text, int size, int style, int face);
void em_platform_text(EmSurface *surface, const char *text, const int *args);
void em_platform_modal(int tab_id, const char *title, const char *value, int max_size, int constraints, const char **labels, int count);
void em_platform_status(int tab_id, const char *text);
void em_platform_tab_finished(int tab_id, int result);
void em_platform_browse(const char *url);
void em_platform_vibrate(int milliseconds);
void em_platform_tick(void);
#endif
