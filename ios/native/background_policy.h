#ifndef EM_BACKGROUND_POLICY_H
#define EM_BACKGROUND_POLICY_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>
#include <math.h>

typedef enum { EM_BACKGROUND_OFF, EM_BACKGROUND_RUNNING, EM_BACKGROUND_PAUSED, EM_BACKGROUND_INTERRUPTED } EmBackgroundStatus;
static inline EmBackgroundStatus em_background_status(int enabled,size_t games,int audio_active,int user_paused) {
    if(!enabled || !games)return EM_BACKGROUND_OFF;
    if(user_paused)return EM_BACKGROUND_PAUSED;
    return audio_active?EM_BACKGROUND_RUNNING:EM_BACKGROUND_INTERRUPTED;
}
static inline int em_background_metrics(char *text,size_t size,uint64_t memory_bytes,double cpu,size_t tabs) {
    if(!text || !size)return 0;
    char memory[32],usage[32];
    if(memory_bytes)snprintf(memory,sizeof(memory),"RAM %.0fMB",memory_bytes/1048576.0);
    else snprintf(memory,sizeof(memory),"RAM --");
    if(isfinite(cpu) && cpu>=0)snprintf(usage,sizeof(usage),"CPU %.0f%%",cpu);
    else snprintf(usage,sizeof(usage),"CPU --");
    return snprintf(text,size,"%s | %s | Tab %zu",memory,usage,tabs);
}

typedef struct EmBackgroundDecision { int paused, lifecycle, sleeping; } EmBackgroundDecision;
/* Lifecycle callbacks are edge-triggered: a kept-alive game must not receive
 * pauseApp/startApp simply because the app left/reentered the foreground. */
static inline EmBackgroundDecision em_background_decide(int hidden,int keep_alive,int tab_sleeping,int was_paused) {
    EmBackgroundDecision result;
    result.paused=hidden && !keep_alive;
    result.lifecycle=result.paused==was_paused?0:(result.paused?8:9);
    result.sleeping=hidden || tab_sleeping;
    return result;
}

/* A small in-memory PCM WAV. No microphone, file access or downloaded media. */
#define EM_BACKGROUND_WAVE_SIZE (44 + 8000 * 2 * 2)
static inline void em_wave_u32(uint8_t *p,uint32_t value) {
    p[0]=(uint8_t)value;p[1]=(uint8_t)(value>>8);p[2]=(uint8_t)(value>>16);p[3]=(uint8_t)(value>>24);
}
static inline int em_background_wave(uint8_t *data,size_t size) {
    if(!data || size<EM_BACKGROUND_WAVE_SIZE)return 0;
    memset(data,0,EM_BACKGROUND_WAVE_SIZE);
    memcpy(data,"RIFF",4);em_wave_u32(data+4,EM_BACKGROUND_WAVE_SIZE-8);memcpy(data+8,"WAVEfmt ",8);
    em_wave_u32(data+16,16);data[20]=1;data[22]=1; // PCM, mono
    em_wave_u32(data+24,8000);em_wave_u32(data+28,16000);data[32]=2;data[34]=16;
    memcpy(data+36,"data",4);em_wave_u32(data+40,EM_BACKGROUND_WAVE_SIZE-44);return 1;
}
#endif
