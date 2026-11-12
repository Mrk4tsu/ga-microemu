#include "emulator.h"
#include "jvm.h"
#include "jvm_util.h"
#include "garbage.h"
#include "jit.h"
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

static once_flag initialized=ONCE_FLAG_INIT;
static mtx_t surface_lock,event_lock;
static EmSurface *surfaces;
static uint64_t next_surface=1;
static size_t surface_bytes;
typedef struct {int v[4];char *text;} Event;
static Event events[256];
static int event_count;
static char *current_text;
static int execution_failed;

static void initialize(void) { mtx_init(&surface_lock,mtx_plain);mtx_init(&event_lock,mtx_plain);jvm_init_mem_alloc(); }
static char *copy_text(const char *text) {
    if(!text)return NULL; size_t length=strlen(text);char *result=malloc(length+1);
    if(result)memcpy(result,text,length+1);return result;
}
void em_reset_events(void) {
    call_once(&initialized,initialize);mtx_lock(&event_lock);
    for(int i=0;i<event_count;i++)free(events[i].text);event_count=0;
    free(current_text);current_text=NULL;mtx_unlock(&event_lock);
}
void em_event(int type,int a,int b,int c,const char *text) {
    call_once(&initialized,initialize);mtx_lock(&event_lock);
    if(event_count==256) { free(events[0].text);memmove(events,events+1,255*sizeof(Event));event_count--; }
    Event *event=&events[event_count++];event->v[0]=type;event->v[1]=a;event->v[2]=b;event->v[3]=c;event->text=copy_text(text);
    mtx_unlock(&event_lock);
}
static EmSurface *find_surface(uint64_t id) { for(EmSurface*s=surfaces;s;s=s->next)if(s->id==id)return s;return NULL; }
static EmSurface *new_surface(int w,int h,uint32_t fill) {
    if(w<=0 || h<=0 || w>4096 || h>4096 || (size_t)w*h*4>256u*1024u*1024u-surface_bytes)return NULL;
    EmSurface*s=calloc(1,sizeof(*s));if(!s)return NULL;s->pixels=malloc((size_t)w*h*4);
    if(!s->pixels){free(s);return NULL;}
    s->id=next_surface++;s->width=w;s->height=h;s->next=surfaces;surfaces=s;surface_bytes+=(size_t)w*h*4;
    for(int i=0;i<w*h;i++)s->pixels[i]=fill;return s;
}
static char *string_copy(Runtime*r,Instance*value) {
    if(!value)return NULL;Utf8String*utf=utf8_create();jstring_2_utf8(value,utf,r);char*text=copy_text(utf8_cstr(utf));utf8_destroy(utf);return text;
}
static s32 create(Runtime*r,JClass*c) {
    mtx_lock(&surface_lock);EmSurface*s=new_surface(localvar_getInt(r->localvar,0),localvar_getInt(r->localvar,1),localvar_getInt(r->localvar,2));
    push_long(r->stack,s?s->id:0);mtx_unlock(&surface_lock);return 0;
}
static s32 decode(Runtime*r,JClass*c) {
    Instance*bytes=localvar_getRefer(r->localvar,0);int off=localvar_getInt(r->localvar,1),len=localvar_getInt(r->localvar,2),w,h,channels;
    unsigned char*rgba=NULL;
    if(bytes && off>=0 && len>=0 && (int64_t)off+len<=jarray_length(bytes))rgba=stbi_load_from_memory((unsigned char*)jarray_body(bytes)+off,len,&w,&h,&channels,4);
    mtx_lock(&surface_lock);EmSurface*s=rgba?new_surface(w,h,0):NULL;
    if(s)for(int i=0;i<w*h;i++)s->pixels[i]=((uint32_t)rgba[i*4+3]<<24)|((uint32_t)rgba[i*4]<<16)|((uint32_t)rgba[i*4+1]<<8)|rgba[i*4+2];
    push_long(r->stack,s?s->id:0);mtx_unlock(&surface_lock);stbi_image_free(rgba);return 0;
}
static s32 release(Runtime*r,JClass*c) {
    uint64_t id=localvar_getLong(r->localvar,0);mtx_lock(&surface_lock);EmSurface**p=&surfaces;
    while(*p) {EmSurface*s=*p;if(s->id==id){*p=s->next;surface_bytes-=(size_t)s->width*s->height*4;free(s->pixels);free(s);break;}p=&s->next;}
    mtx_unlock(&surface_lock);return 0;
}
static s32 width(Runtime*r,JClass*c) {mtx_lock(&surface_lock);EmSurface*s=find_surface(localvar_getLong(r->localvar,0));push_int(r->stack,s?s->width:0);mtx_unlock(&surface_lock);return 0;}
static s32 height(Runtime*r,JClass*c) {mtx_lock(&surface_lock);EmSurface*s=find_surface(localvar_getLong(r->localvar,0));push_int(r->stack,s?s->height:0);mtx_unlock(&surface_lock);return 0;}
static s32 pixels(Runtime*r,JClass*c) {
    Instance*array=localvar_getRefer(r->localvar,2);int offset=localvar_getInt(r->localvar,3),scan=localvar_getInt(r->localvar,4);
    int x=localvar_getInt(r->localvar,5),y=localvar_getInt(r->localvar,6),w=localvar_getInt(r->localvar,7),h=localvar_getInt(r->localvar,8);
    int write=localvar_getInt(r->localvar,9),alpha=localvar_getInt(r->localvar,10);
    mtx_lock(&surface_lock);EmSurface*s=find_surface(localvar_getLong(r->localvar,0));
    if(s && array && x>=0 && y>=0 && w>=0 && h>=0 && (int64_t)x+w<=s->width && (int64_t)y+h<=s->height) {
        uint32_t*data=(uint32_t*)jarray_body(array);int count=jarray_length(array);
        for(int yy=0;yy<h;yy++)for(int xx=0;xx<w;xx++){
            int64_t index=(int64_t)offset+(int64_t)yy*scan+xx;if(index<0 || index>=count)continue;
            uint32_t*p=&s->pixels[(y+yy)*s->width+x+xx];if(write)*p=alpha?data[index]:data[index]|0xff000000u;else data[index]=*p;
        }
    }
    mtx_unlock(&surface_lock);return 0;
}
static s32 draw(Runtime*r,JClass*c) {
    Instance*array=localvar_getRefer(r->localvar,5);char*text=string_copy(r,localvar_getRefer(r->localvar,6));
    mtx_lock(&surface_lock);EmSurface*s=find_surface(localvar_getLong(r->localvar,0));EmSurface*source=find_surface(localvar_getLong(r->localvar,2));
    if(s && array && jarray_length(array)>=17)em_raster(s,source,localvar_getInt(r->localvar,4),(int*)jarray_body(array),text);
    mtx_unlock(&surface_lock);free(text);return 0;
}
static s32 present(Runtime*r,JClass*c) {mtx_lock(&surface_lock);EmSurface*s=find_surface(localvar_getLong(r->localvar,0));if(s)em_platform_present(s);mtx_unlock(&surface_lock);return 0;}
static s32 text_width(Runtime*r,JClass*c) {
    char*text=string_copy(r,localvar_getRefer(r->localvar,0));push_int(r->stack,em_platform_text_width(text?text:"",localvar_getInt(r->localvar,1),localvar_getInt(r->localvar,2),localvar_getInt(r->localvar,3)));free(text);return 0;
}
static s32 poll_event(Runtime*r,JClass*c) {
    em_platform_tick();Instance*array=localvar_getRefer(r->localvar,0);int found=0;mtx_lock(&event_lock);
    if(array && jarray_length(array)>=4 && event_count) {
        Event e=events[0];memcpy(jarray_body(array),e.v,sizeof(e.v));free(current_text);current_text=e.text;
        memmove(events,events+1,(--event_count)*sizeof(Event));found=1;
    }
    mtx_unlock(&event_lock);push_int(r->stack,found);return 0;
}
static s32 take_text(Runtime*r,JClass*c) {
    mtx_lock(&event_lock);Instance*text=current_text?jstring_create_cstr(current_text,r):NULL;free(current_text);current_text=NULL;
    mtx_unlock(&event_lock);push_ref(r->stack,text);return 0;
}
static s32 modal(Runtime*r,JClass*c) {
    char*title=string_copy(r,localvar_getRefer(r->localvar,0));char*value=string_copy(r,localvar_getRefer(r->localvar,1));
    Instance*array=localvar_getRefer(r->localvar,4);int count=array?jarray_length(array):0;
    char**labels=calloc(count?count:1,sizeof(char*));
    if(labels)for(int i=0;i<count;i++)labels[i]=string_copy(r,(__refer)jarray_get_field(array,i));
    em_platform_modal(title,value,localvar_getInt(r->localvar,2),localvar_getInt(r->localvar,3),(const char**)labels,labels?count:0);
    if(labels)for(int i=0;i<count;i++)free(labels[i]);free(labels);free(title);free(value);return 0;
}
static s32 status(Runtime*r,JClass*c){char*text=string_copy(r,localvar_getRefer(r->localvar,0));em_platform_status(text?text:"");free(text);return 0;}
static s32 failed(Runtime*r,JClass*c){execution_failed=1;return status(r,c);}
static s32 browse(Runtime*r,JClass*c){char*text=string_copy(r,localvar_getRefer(r->localvar,0));if(text)em_platform_browse(text);free(text);return 0;}
static s32 vibrate(Runtime*r,JClass*c){em_platform_vibrate(localvar_getInt(r->localvar,0));return 0;}
#define METHOD(name,signature,fn) {"org/microemu/ios/NativeBridge",name,signature,fn}
static java_native_method methods[]={
    METHOD("create","(III)J",create),METHOD("decode","([BII)J",decode),METHOD("release","(J)V",release),
    METHOD("width","(J)I",width),METHOD("height","(J)I",height),METHOD("pixels","(J[IIIIIIIZZ)V",pixels),
    METHOD("draw","(JJI[ILjava/lang/String;)V",draw),METHOD("present","(J)V",present),
    METHOD("textWidth","(Ljava/lang/String;III)I",text_width),METHOD("poll","([I)I",poll_event),METHOD("takeText","()Ljava/lang/String;",take_text),
    METHOD("modal","(Ljava/lang/String;Ljava/lang/String;II[Ljava/lang/String;)V",modal),
    METHOD("status","(Ljava/lang/String;)V",status),METHOD("failed","(Ljava/lang/String;)V",failed),METHOD("browse","(Ljava/lang/String;)V",browse),METHOD("vibrate","(I)V",vibrate)
};

int em_run(const char*boot,const char*classpath,const char*jar,const char*rms,int width,int height) {
    fprintf(stderr,"[RUNTIME] Initializing interpreter\n");fflush(stderr);
    call_once(&initialized,initialize);
    execution_failed=0;
    MiniJVM*jvm=jvm_create();if(!jvm){em_platform_status("Cannot create JVM");return -1;}
    jvm->max_heap_size=256LL*1024*1024;jvm->max_vm_memory=768LL*1024*1024;jvm->jdwp_enable=0;
    if(jvm_init(jvm,(char*)boot,(char*)classpath)) {em_platform_status("Cannot initialize Java runtime");return -1;}
    native_reg_lib(jvm,methods,sizeof(methods)/sizeof(methods[0]));
    char width_text[16],height_text[16];snprintf(width_text,sizeof(width_text),"%d",width);snprintf(height_text,sizeof(height_text),"%d",height);
    ArrayList*args=arraylist_create(4);arraylist_push_back(args,(void*)jar);arraylist_push_back(args,(void*)rms);
    arraylist_push_back(args,width_text);arraylist_push_back(args,height_text);
    int result=call_main(jvm,"org.microemu.ios.IOSRuntime",args);arraylist_destroy(args);jvm_destroy(jvm);
    mtx_lock(&surface_lock);while(surfaces){EmSurface*s=surfaces;surfaces=s->next;free(s->pixels);free(s);}surface_bytes=0;mtx_unlock(&surface_lock);
    em_reset_events();
    return result?result:execution_failed;
}
