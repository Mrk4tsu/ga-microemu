#include "background_policy.h"
#include <stdio.h>
#include <stdlib.h>
#define CHECK(test) do { if(!(test)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#test);exit(1);} } while(0)
static uint32_t u32(const uint8_t *p) { return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24); }
int main(void) {
    EmBackgroundDecision d=em_background_decide(0,0,0,0);
    CHECK(!d.paused && !d.lifecycle && !d.sleeping);
    d=em_background_decide(1,1,0,0); // Home/lock with audio: no lifecycle restart
    CHECK(!d.paused && !d.lifecycle && d.sleeping);
    d=em_background_decide(0,1,0,d.paused);
    CHECK(!d.paused && !d.lifecycle && !d.sleeping);
    d=em_background_decide(1,0,0,d.paused); // disabled or audio interrupted
    CHECK(d.paused && d.lifecycle==8 && d.sleeping);
    d=em_background_decide(1,0,0,d.paused);
    CHECK(d.paused && !d.lifecycle && d.sleeping);
    d=em_background_decide(1,1,0,d.paused); // interruption ends while hidden
    CHECK(!d.paused && d.lifecycle==9 && d.sleeping);
    d=em_background_decide(1,1,1,d.paused);
    CHECK(!d.paused && !d.lifecycle && d.sleeping);
    d=em_background_decide(0,1,1,d.paused); // retain user tab sleep choice
    CHECK(!d.paused && !d.lifecycle && d.sleeping);
    d=em_background_decide(1,0,1,d.paused);
    CHECK(d.paused && d.lifecycle==8);
    d=em_background_decide(0,0,1,d.paused); // foreground recovers paused game once
    CHECK(!d.paused && d.lifecycle==9 && d.sleeping);
    d=em_background_decide(0,0,0,d.paused);
    CHECK(!d.paused && !d.lifecycle && !d.sleeping);

    CHECK(em_background_status(0,2,1,0)==EM_BACKGROUND_OFF);
    CHECK(em_background_status(1,0,1,0)==EM_BACKGROUND_OFF); // last tab ended
    CHECK(em_background_status(1,2,1,0)==EM_BACKGROUND_RUNNING);
    CHECK(em_background_status(1,2,0,0)==EM_BACKGROUND_INTERRUPTED);
    CHECK(em_background_status(1,2,0,1)==EM_BACKGROUND_PAUSED);
    CHECK(em_background_status(1,2,1,1)==EM_BACKGROUND_PAUSED); // user pause wins
    char metrics[128];
    CHECK(em_background_metrics(metrics,sizeof(metrics),120ULL*1048576,8,3)>0);
    CHECK(!strcmp(metrics,"RAM 120MB | CPU 8% | Tab 3"));
    em_background_metrics(metrics,sizeof(metrics),0,-1,0);
    CHECK(!strcmp(metrics,"RAM -- | CPU -- | Tab 0"));
    em_background_metrics(metrics,sizeof(metrics),2048ULL*1048576,175,12);
    CHECK(!strcmp(metrics,"RAM 2048MB | CPU 175% | Tab 12")); // do not cap multicore CPU
    em_background_metrics(metrics,sizeof(metrics),1,NAN,1);
    CHECK(!strcmp(metrics,"RAM 0MB | CPU -- | Tab 1"));
    em_background_metrics(metrics,sizeof(metrics),0,INFINITY,1);CHECK(strstr(metrics,"CPU --")!=NULL);
    char tiny[5];memset(tiny,0x7f,sizeof(tiny));
    CHECK(em_background_metrics(tiny,4,120ULL*1048576,8,3)>3);
    CHECK(tiny[3]==0 && tiny[4]==0x7f);
    CHECK(!em_background_metrics(NULL,0,0,0,0));

    uint8_t wave[EM_BACKGROUND_WAVE_SIZE+1];memset(wave,0xaa,sizeof(wave));
    CHECK(!em_background_wave(NULL,sizeof(wave)));
    CHECK(!em_background_wave(wave,EM_BACKGROUND_WAVE_SIZE-1));CHECK(wave[0]==0xaa);
    CHECK(em_background_wave(wave,sizeof(wave)));CHECK(wave[EM_BACKGROUND_WAVE_SIZE]==0xaa);
    CHECK(!memcmp(wave,"RIFF",4) && u32(wave+4)==EM_BACKGROUND_WAVE_SIZE-8);
    CHECK(!memcmp(wave+8,"WAVEfmt ",8) && u32(wave+16)==16);
    CHECK(wave[20]==1 && !wave[21] && wave[22]==1 && !wave[23]);
    CHECK(u32(wave+24)==8000 && u32(wave+28)==16000);
    CHECK(wave[32]==2 && !wave[33] && wave[34]==16 && !wave[35]);
    CHECK(!memcmp(wave+36,"data",4) && u32(wave+40)==32000);
    for(size_t i=44;i<EM_BACKGROUND_WAVE_SIZE;i++)CHECK(wave[i]==0);
    puts("PASS: background lifecycle, Now Playing states/metrics and bounded PCM WAV");return 0;
}
