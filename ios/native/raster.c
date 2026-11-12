#include "emulator.h"
#include <math.h>
#include <stdlib.h>

static int maximum(int a, int b) { return a > b ? a : b; }
static int minimum(int a, int b) { return a < b ? a : b; }

void em_blend(EmSurface *s, int x, int y, uint32_t color, const int *clip) {
    if (x < 0 || y < 0 || x >= s->width || y >= s->height ||
        x < clip[0] || y < clip[1] || x >= clip[0] + clip[2] || y >= clip[1] + clip[3]) return;
    unsigned sa = color >> 24;
    if (!sa) return;
    uint32_t *pixel = &s->pixels[y * s->width + x];
    if (sa == 255) { *pixel = color; return; }
    uint32_t old = *pixel;
    unsigned da = (old >> 24) * (255 - sa) / 255, alpha = sa + da;
    unsigned r = (((color >> 16) & 255) * sa + ((old >> 16) & 255) * da) / alpha;
    unsigned g = (((color >> 8) & 255) * sa + ((old >> 8) & 255) * da) / alpha;
    unsigned b = ((color & 255) * sa + (old & 255) * da) / alpha;
    *pixel = (alpha << 24) | (r << 16) | (g << 8) | b;
}

static void line(EmSurface *s, int x, int y, int x2, int y2, uint32_t color, const int *clip, int dotted) {
    /* Bound work even when a MIDlet supplies large offscreen coordinates. */
    double dx = (double)x2 - x, dy = (double)y2 - y, lo = 0, hi = 1;
    double p[4] = {-dx, dx, -dy, dy};
    double q[4] = {x - (double)maximum(0, clip[0]), minimum(s->width, clip[0]+clip[2])-1.0-x,
                   y - (double)maximum(0, clip[1]), minimum(s->height, clip[1]+clip[3])-1.0-y};
    for (int i = 0; i < 4; i++) {
        if (p[i] == 0) { if (q[i] < 0) return; continue; }
        double t = q[i] / p[i];
        if (p[i] < 0) { if (t > hi) return; if (t > lo) lo = t; }
        else { if (t < lo) return; if (t < hi) hi = t; }
    }
    x2 = (int)lround(x + hi * dx); y2 = (int)lround(y + hi * dy);
    x = (int)lround(x + lo * dx); y = (int)lround(y + lo * dy);
    int ax = abs(x2-x), ay = -abs(y2-y), sx = x<x2 ? 1 : -1, sy = y<y2 ? 1 : -1;
    int error = ax+ay, phase = 0;
    for (;;) {
        if (!dotted || !(phase++ & 1)) em_blend(s,x,y,color,clip);
        if (x == x2 && y == y2) break;
        int twice = 2*error;
        if (twice >= ay) { error += ay; x += sx; }
        if (twice <= ax) { error += ax; y += sy; }
    }
}

static int rounded(double x, double y, int w, int h, double rx, double ry) {
    if (x<0 || y<0 || x>=w || y>=h) return 0;
    if (rx<=0 || ry<=0 || (x>=rx && x<w-rx) || (y>=ry && y<h-ry)) return 1;
    double dx = (x<rx ? x-rx : x-(w-rx-1))/rx;
    double dy = (y<ry ? y-ry : y-(h-ry-1))/ry;
    return dx*dx+dy*dy<=1;
}

void em_raster(EmSurface *s, EmSurface *source, int op, const int *a, const char *text) {
    const int *clip = a+1;
    uint32_t color = 0xff000000u | (uint32_t)a[0];
    int x=a[6], y=a[7], w=a[8], h=a[9];
    if (clip[2]<=0 || clip[3]<=0) return;
    if (op == 3) { line(s,x,y,w,h,color,clip,a[5]); return; }
    if (op == 2) {
        if (w<0 || h<0) return;
        line(s,x,y,x+w,y,color,clip,a[5]); line(s,x,y+h,x+w,y+h,color,clip,a[5]);
        line(s,x,y,x,y+h,color,clip,a[5]); line(s,x+w,y,x+w,y+h,color,clip,a[5]); return;
    }
    if (op == 10) { em_platform_text(s,text ? text : "",a); return; }
    if (op == 9) {
        if (!source || w<=0 || h<=0) return;
        int tr=a[12], dw=tr>=4?h:w, dh=tr>=4?w:h;
        int left=maximum(maximum(x,clip[0]),0), top=maximum(maximum(y,clip[1]),0);
        int right=minimum(minimum(x+dw,clip[0]+clip[2]),s->width), bottom=minimum(minimum(y+dh,clip[1]+clip[3]),s->height);
        for (int yy=top; yy<bottom; yy++) for(int xx=left; xx<right; xx++) {
            int ox=xx-x,oy=yy-y,sx=0,sy=0;
            switch(tr) {
                case 0:sx=ox;sy=oy;break; case 1:sx=ox;sy=h-1-oy;break;
                case 2:sx=w-1-ox;sy=oy;break; case 3:sx=w-1-ox;sy=h-1-oy;break;
                case 4:sx=oy;sy=ox;break; case 5:sx=oy;sy=h-1-ox;break;
                case 6:sx=w-1-oy;sy=ox;break; case 7:sx=w-1-oy;sy=h-1-ox;break;
                default:return;
            }
            sx+=a[10];sy+=a[11];
            if(sx>=0 && sy>=0 && sx<source->width && sy<source->height)
                em_blend(s,xx,yy,source->pixels[sy*source->width+sx],clip);
        }
        return;
    }
    if (op == 8) {
        int x2=w,y2=h,x3=a[10],y3=a[11];
        int left=maximum(maximum(minimum(x,minimum(x2,x3)),clip[0]),0);
        int top=maximum(maximum(minimum(y,minimum(y2,y3)),clip[1]),0);
        int right=minimum(minimum(maximum(x,maximum(x2,x3)),clip[0]+clip[2]-1),s->width-1);
        int bottom=minimum(minimum(maximum(y,maximum(y2,y3)),clip[1]+clip[3]-1),s->height-1);
        for(int yy=top;yy<=bottom;yy++) for(int xx=left;xx<=right;xx++) {
            int64_t e1=(int64_t)(xx-x)*(y2-y)-(int64_t)(yy-y)*(x2-x);
            int64_t e2=(int64_t)(xx-x2)*(y3-y2)-(int64_t)(yy-y2)*(x3-x2);
            int64_t e3=(int64_t)(xx-x3)*(y-y3)-(int64_t)(yy-y3)*(x-x3);
            if((e1>=0 && e2>=0 && e3>=0)||(e1<=0 && e2<=0 && e3<=0)) em_blend(s,xx,yy,color,clip);
        }
        return;
    }
    if(w<=0 || h<=0) return;
    int left=maximum(maximum(x,clip[0]),0),top=maximum(maximum(y,clip[1]),0);
    int right=minimum(minimum(x+w,clip[0]+clip[2]),s->width),bottom=minimum(minimum(y+h,clip[1]+clip[3]),s->height);
    double rx=minimum(abs(a[10]),w)/2.0,ry=minimum(abs(a[11]),h)/2.0;
    for(int yy=top;yy<bottom;yy++) for(int xx=left;xx<right;xx++) {
        int paint=op==1;
        if(op==4 || op==5) {
            paint=rounded(xx-x,yy-y,w,h,rx,ry);
            if(op==4 && rounded(xx-x-1,yy-y-1,w-2,h-2,rx>1?rx-1:0,ry>1?ry-1:0)) paint=0;
        } else if(op==6 || op==7) {
            double dx=(xx-x+0.5-w/2.0)/(w/2.0),dy=(yy-y+0.5-h/2.0)/(h/2.0);
            double distance=dx*dx+dy*dy;
            double angle=atan2(-dy,dx)*180.0/3.141592653589793;
            double delta=fmod(angle-a[10]+720.0,360.0);
            if(a[11]<0) delta=fmod(a[10]-angle+720.0,360.0);
            paint=distance<=1 && (abs(a[11])>=360 || delta<=abs(a[11]));
            if(op==6 && distance<1.0-4.0/minimum(w,h)) paint=0;
        }
        if(paint) em_blend(s,xx,yy,color,clip);
    }
}
