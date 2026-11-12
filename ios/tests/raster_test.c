#include "emulator.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
void em_platform_text(EmSurface*s,const char*t,const int*a){}
static void check(int condition,const char*message){if(!condition){fprintf(stderr,"FAIL: %s\n",message);exit(1);}}
int main(void){
    uint32_t pixels[64]={0},source_pixels[]={0xffff0000,0xff00ff00,0xff0000ff,0xffffff00,0xffff00ff,0xff00ffff};
    EmSurface dst={1,8,8,pixels,NULL},src={2,2,3,source_pixels,NULL};
    int a[17]={0x123456,1,1,3,2,0,0,0,8,8};em_raster(&dst,NULL,1,a,NULL);
    check(pixels[9]==0xff123456 && pixels[0]==0 && pixels[4]==0 && pixels[25]==0,"clip rectangle");
    const uint32_t first[]={0xffff0000,0xffff00ff,0xff00ff00,0xff00ffff,0xffff0000,0xffff00ff,0xff00ff00,0xff00ffff};
    for(int transform=0;transform<8;transform++){
        memset(pixels,0,sizeof(pixels));memset(a,0,sizeof(a));a[3]=a[4]=8;a[8]=2;a[9]=3;a[12]=transform;
        em_raster(&dst,&src,9,a,NULL);check(pixels[0]==first[transform],"MIDP sprite transform");
        int dw=transform>=4?3:2,dh=transform>=4?2:3;check(pixels[(dh-1)*8+dw-1]!=0 && pixels[dw]==0,"transformed dimensions");
    }
    memset(pixels,0,sizeof(pixels));int clip[]={0,0,8,8};pixels[0]=0xff0000ff;
    em_blend(&dst,0,0,0x80ff0000,clip);check(pixels[0]==0xff80007f,"straight alpha blend");
    puts("PASS: clipping, all 8 MIDP transforms, alpha blending");return 0;
}
