#include <jni.h>
#include <pthread.h>
#include <android/log.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "emulator.h"

static JavaVM *art_vm;
static jclass engine_class;
static jmethodID status_method, modal_method, finished_method, browse_method, vibrate_method, width_method, text_method;
static pthread_key_t attached_key;
static pthread_mutex_t frame_lock = PTHREAD_MUTEX_INITIALIZER;
typedef struct Frame { int id, width, height, closed; uint32_t *pixels; struct Frame *next; } Frame;
static Frame *frames;

static void detach_thread(void *attached) { if (attached) (*art_vm)->DetachCurrentThread(art_vm); }
static JNIEnv *environment(void) {
    JNIEnv *env = NULL;
    if ((*art_vm)->GetEnv(art_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*art_vm)->AttachCurrentThread(art_vm, &env, NULL) != JNI_OK) return NULL;
        pthread_setspecific(attached_key, (void *)1);
    }
    return env;
}
/* miniJVM emits standard UTF-8; JNI NewStringUTF expects modified UTF-8. */
static jstring java_string(JNIEnv *env, const char *utf8) {
    if (!utf8) return NULL;
    size_t bytes = strlen(utf8); jchar *chars = malloc((bytes + 1) * sizeof(jchar));
    if (!chars) return NULL;
    size_t n = 0, i = 0;
    while (i < bytes) {
        uint32_t cp = (unsigned char)utf8[i++]; int more = 0;
        if (cp >= 0xf0 && cp <= 0xf4) { cp &= 7; more = 3; }
        else if (cp >= 0xe0 && cp <= 0xef) { cp &= 15; more = 2; }
        else if (cp >= 0xc2 && cp <= 0xdf) { cp &= 31; more = 1; }
        else if (cp >= 0x80) cp = 0xfffd;
        while (more > 0 && i < bytes && ((unsigned char)utf8[i] & 0xc0) == 0x80) {
            cp = (cp << 6) | ((unsigned char)utf8[i++] & 63); more--;
        }
        if (more || cp > 0x10ffff) cp = 0xfffd;
        if (cp > 0xffff) { cp -= 0x10000; chars[n++] = 0xd800 | (cp >> 10); chars[n++] = 0xdc00 | (cp & 1023); }
        else chars[n++] = (jchar)cp;
    }
    jstring result = (*env)->NewString(env, chars, (jsize)n); free(chars); return result;
}
static void callback_error(JNIEnv *env) {
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); }
}
JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    art_vm = vm; JNIEnv *env = environment();
    if (!env || pthread_key_create(&attached_key, detach_thread)) return JNI_ERR;
    jclass cls = (*env)->FindClass(env, "com/gamod/gaemulator/NativeEngine");
    if (!cls) return JNI_ERR;
    engine_class = (*env)->NewGlobalRef(env, cls); (*env)->DeleteLocalRef(env, cls);
    status_method = (*env)->GetStaticMethodID(env, engine_class, "onStatus", "(ILjava/lang/String;)V");
    modal_method = (*env)->GetStaticMethodID(env, engine_class, "onModal", "(ILjava/lang/String;Ljava/lang/String;II[Ljava/lang/String;)V");
    finished_method = (*env)->GetStaticMethodID(env, engine_class, "onFinished", "(II)V");
    browse_method = (*env)->GetStaticMethodID(env, engine_class, "onBrowse", "(Ljava/lang/String;)V");
    vibrate_method = (*env)->GetStaticMethodID(env, engine_class, "onVibrate", "(I)V");
    width_method = (*env)->GetStaticMethodID(env, engine_class, "textWidth", "(Ljava/lang/String;III)I");
    text_method = (*env)->GetStaticMethodID(env, engine_class, "textMask", "(Ljava/lang/String;III)[I");
    if ((*env)->ExceptionCheck(env)) return JNI_ERR;
    return JNI_VERSION_1_6;
}
void em_platform_present(int id, const EmSurface *surface) {
    size_t size = (size_t)surface->width * surface->height * sizeof(uint32_t);
    uint32_t *copy = malloc(size); if (!copy) return;
    memcpy(copy, surface->pixels, size);
    pthread_mutex_lock(&frame_lock);
    Frame *frame = frames;
    while (frame && frame->id != id) frame = frame->next;
    if (!frame) { frame = calloc(1, sizeof(Frame)); if (frame) { frame->id = id; frame->next = frames; frames = frame; } }
    if (frame && !frame->closed) { free(frame->pixels); frame->pixels = copy; frame->width = surface->width; frame->height = surface->height; }
    else free(copy);
    pthread_mutex_unlock(&frame_lock);
}
JNIEXPORT jintArray JNICALL Java_com_gamod_gaemulator_NativeEngine_takeFrame(JNIEnv *env, jclass cls, jint id) {
    uint32_t *owned = NULL; int w = 0, h = 0;
    pthread_mutex_lock(&frame_lock);
    for (Frame *frame = frames; frame; frame = frame->next) if (frame->id == id) {
        owned = frame->pixels; frame->pixels = NULL; w = frame->width; h = frame->height; break;
    }
    pthread_mutex_unlock(&frame_lock);
    if (!owned) return NULL;
    jintArray result = (*env)->NewIntArray(env, 2 + w * h);
    if (result) {
        jint dimensions[] = {w, h}; (*env)->SetIntArrayRegion(env, result, 0, 2, dimensions);
        (*env)->SetIntArrayRegion(env, result, 2, w * h, (const jint *)owned);
    }
    free(owned); return result;
}
int em_platform_text_width(const char *text, int size, int style, int face) {
    JNIEnv *env = environment(); if (!env) return 0;
    jstring string = java_string(env, text); if (!string) return 0;
    jint width = (*env)->CallStaticIntMethod(env, engine_class, width_method, string, size, style, face);
    (*env)->DeleteLocalRef(env, string); callback_error(env); return width;
}
void em_platform_text(EmSurface *surface, const char *text, const int *a) {
    JNIEnv *env = environment(); if (!env) return;
    jstring string = java_string(env, text); if (!string) return;
    jintArray mask = (*env)->CallStaticObjectMethod(env, engine_class, text_method, string, a[14], a[15], a[16]);
    (*env)->DeleteLocalRef(env, string);
    if (mask && !(*env)->ExceptionCheck(env)) {
        jsize length = (*env)->GetArrayLength(env, mask);
        jint *pixels = (*env)->GetIntArrayElements(env, mask, NULL);
        if (pixels && length >= 2) {
            int w = pixels[0], h = pixels[1];
            if (w > 0 && h > 0 && (int64_t)w * h <= length - 2) {
                for (int y = 0; y < h; y++) for (int x = 0; x < w; x++)
                    em_blend(surface, a[6] + x, a[7] + y, ((uint32_t)pixels[2 + y*w + x] & 0xff000000u) | (uint32_t)a[0], a+1);
            }
        }
        if (pixels) (*env)->ReleaseIntArrayElements(env, mask, pixels, JNI_ABORT);
    }
    if (mask) (*env)->DeleteLocalRef(env, mask); callback_error(env);
}
void em_platform_status(int id, const char *text) {
    JNIEnv *env = environment(); if (!env) return;
    jstring string = java_string(env, text);
    (*env)->CallStaticVoidMethod(env, engine_class, status_method, id, string);
    if (string) (*env)->DeleteLocalRef(env, string); callback_error(env);
}
void em_platform_modal(int id, const char *title, const char *value, int max, int constraints, const char **labels, int count) {
    JNIEnv *env = environment(); if (!env) return;
    jstring heading = java_string(env, title), body = java_string(env, value);
    jclass cls = (*env)->FindClass(env, "java/lang/String");
    jobjectArray commands = cls ? (*env)->NewObjectArray(env, count, cls, NULL) : NULL;
    if (commands) for (int i = 0; i < count; i++) {
        jstring label = java_string(env, labels[i] ? labels[i] : "");
        (*env)->SetObjectArrayElement(env, commands, i, label);
        if (label) (*env)->DeleteLocalRef(env, label);
    }
    (*env)->CallStaticVoidMethod(env, engine_class, modal_method, id, heading, body, max, constraints, commands);
    if (heading) (*env)->DeleteLocalRef(env, heading); if (body) (*env)->DeleteLocalRef(env, body);
    if (commands) (*env)->DeleteLocalRef(env, commands); if (cls) (*env)->DeleteLocalRef(env, cls); callback_error(env);
}
void em_platform_tab_finished(int id, int result) {
    pthread_mutex_lock(&frame_lock);
    for (Frame *frame = frames; frame; frame = frame->next) if (frame->id == id) { free(frame->pixels); frame->pixels = NULL; frame->closed = 1; }
    pthread_mutex_unlock(&frame_lock);
    JNIEnv *env = environment(); if (!env) return;
    (*env)->CallStaticVoidMethod(env, engine_class, finished_method, id, result); callback_error(env);
}
void em_platform_browse(const char *url) {
    JNIEnv *env = environment(); if (!env) return;
    jstring string = java_string(env, url); (*env)->CallStaticVoidMethod(env, engine_class, browse_method, string);
    if (string) (*env)->DeleteLocalRef(env, string); callback_error(env);
}
void em_platform_vibrate(int ms) {
    JNIEnv *env = environment(); if (env) { (*env)->CallStaticVoidMethod(env, engine_class, vibrate_method, ms); callback_error(env); }
}
void em_platform_tick(void) { }

JNIEXPORT void JNICALL Java_com_gamod_gaemulator_NativeEngine_reset(JNIEnv *env, jclass cls) { em_reset_events(); }
JNIEXPORT jint JNICALL Java_com_gamod_gaemulator_NativeEngine_runHost(JNIEnv *env, jclass cls, jstring boot, jstring emulator, jstring log, jlong memory) {
    const char *b = (*env)->GetStringUTFChars(env, boot, NULL), *e = (*env)->GetStringUTFChars(env, emulator, NULL);
    const char *l = (*env)->GetStringUTFChars(env, log, NULL);
    FILE *fresh = fopen(l, "w"); if (fresh) fclose(fresh);
    freopen(l, "a", stdout); freopen(l, "a", stderr); setvbuf(stdout, NULL, _IOLBF, 0); setvbuf(stderr, NULL, _IOLBF, 0);
    em_configure_memory_bytes((uint64_t)memory);
    int result = em_host_run(b, e);
    (*env)->ReleaseStringUTFChars(env, boot, b); (*env)->ReleaseStringUTFChars(env, emulator, e); (*env)->ReleaseStringUTFChars(env, log, l);
    return result;
}
JNIEXPORT void JNICALL Java_com_gamod_gaemulator_NativeEngine_openTabWithViewport(JNIEnv *env, jclass cls, jint id, jstring jar, jstring rms, jint w, jint h, jboolean full) {
    const char *j = (*env)->GetStringUTFChars(env, jar, NULL), *r = (*env)->GetStringUTFChars(env, rms, NULL);
    pthread_mutex_lock(&frame_lock);
    for (Frame *frame = frames; frame; frame = frame->next) if (frame->id == id) frame->closed = 0;
    pthread_mutex_unlock(&frame_lock);
    if(full) em_host_open_tab_fullscreen(id, j, r, w, h);
    else em_host_open_tab_with_viewport(id, j, r, w, h);
    (*env)->ReleaseStringUTFChars(env, jar, j); (*env)->ReleaseStringUTFChars(env, rms, r);
}
JNIEXPORT jlongArray JNICALL Java_com_gamod_gaemulator_NativeEngine_resources(JNIEnv *env, jclass cls, jint id) {
    EmResourceStats stats={0};em_tab_resource_stats(id,&stats);
    jlong values[]={stats.generation,stats.surface_count,stats.surface_bytes,stats.socket_count,stats.queue_bytes};
    jlongArray result=(*env)->NewLongArray(env,5);
    if(result)(*env)->SetLongArrayRegion(env,result,0,5,values);
    return result;
}
JNIEXPORT void JNICALL Java_com_gamod_gaemulator_NativeEngine_sleepTab(JNIEnv *env, jclass cls, jint id, jboolean sleep) { em_host_sleep_tab(id, sleep); }
JNIEXPORT void JNICALL Java_com_gamod_gaemulator_NativeEngine_closeTab(JNIEnv *env, jclass cls, jint id) { em_host_close_tab(id); }
JNIEXPORT void JNICALL Java_com_gamod_gaemulator_NativeEngine_requestShutdown(JNIEnv *env, jclass cls) { em_host_shutdown(); }
JNIEXPORT void JNICALL Java_com_gamod_gaemulator_NativeEngine_event(JNIEnv *env, jclass cls, jint id, jint type, jint a, jint b, jstring text) {
    const char *t = text ? (*env)->GetStringUTFChars(env, text, NULL) : NULL;
    em_tab_event(id, type, a, b, 0, t); if (t) (*env)->ReleaseStringUTFChars(env, text, t);
}
