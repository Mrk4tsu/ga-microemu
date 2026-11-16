#import "AppPlatform.h"
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <AudioToolbox/AudioToolbox.h>
#include "emulator.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

NSString * const EmStatusNotification = @"MicroEmuStatus";
NSString * const EmModalNotification = @"MicroEmuModal";
NSString * const EmTabFinishedNotification = @"MicroEmuTabFinished";
static NSLock *frameLock;
static NSMutableDictionary<NSNumber*, NSDictionary*> *pendingFrames;
static BOOL presentationEnabled=YES;
static void initializeFrames(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        frameLock = [NSLock new];
        pendingFrames = [NSMutableDictionary new];
    });
}
NSData *EmConsumeFrame(int tabId, int *width, int *height) {
    initializeFrames();
    [frameLock lock];
    NSDictionary *entry = pendingFrames[@(tabId)];
    if (entry) [pendingFrames removeObjectForKey:@(tabId)];
    [frameLock unlock];
    if (!entry) return nil;
    *width = [entry[@"w"] intValue];
    *height = [entry[@"h"] intValue];
    return entry[@"data"];
}
void EmClearFrame(int tabId) {
    initializeFrames();
    [frameLock lock];
    [pendingFrames removeObjectForKey:@(tabId)];
    [frameLock unlock];
}
void EmClearAllFrames(void) {
    initializeFrames();
    [frameLock lock];
    [pendingFrames removeAllObjects];
    [frameLock unlock];
}
void EmSetPresentationEnabled(BOOL enabled) {
    initializeFrames();[frameLock lock];presentationEnabled=enabled;
    if(!enabled)[pendingFrames removeAllObjects];[frameLock unlock];
}
void em_platform_present(int tabId, const EmSurface *surface) {
    @autoreleasepool {
        initializeFrames();
        [frameLock lock];BOOL enabled=presentationEnabled;[frameLock unlock];
        if(!enabled)return;
        NSData *frame = [[NSData alloc] initWithBytes:surface->pixels length:(NSUInteger)surface->width * surface->height * 4];
        [frameLock lock];
        if(presentationEnabled)pendingFrames[@(tabId)] = @{@"data": frame, @"w": @(surface->width), @"h": @(surface->height)};
        [frameLock unlock];
    }
}
static CTFontRef fontFor(int size,int style,int face) {
    CFStringRef name=face==32?CFSTR("Menlo"):CFSTR("Helvetica");
    CTFontRef font=CTFontCreateWithName(name,size,NULL);
    CTFontSymbolicTraits traits=0;if(style&1)traits|=kCTFontBoldTrait;if(style&2)traits|=kCTFontItalicTrait;
    if(traits){CTFontRef styled=CTFontCreateCopyWithSymbolicTraits(font,0,NULL,traits,traits);if(styled){CFRelease(font);font=styled;}}
    return font;
}
int em_platform_text_width(const char *text,int size,int style,int face) {
    @autoreleasepool {
        NSString *string=[[NSString alloc] initWithUTF8String:text];if(!string)return 0;
        CTFontRef font=fontFor(size,style,face);
        NSAttributedString *value=[[NSAttributedString alloc] initWithString:string attributes:@{(__bridge NSString*)kCTFontAttributeName:(__bridge id)font}];
        CTLineRef line=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)value);
        int width=(int)ceil(CTLineGetTypographicBounds(line,NULL,NULL,NULL));CFRelease(line);CFRelease(font);return width;
    }
}
void em_platform_text(EmSurface *surface,const char *text,const int *args) {
    @autoreleasepool {
        NSString *string=[[NSString alloc] initWithUTF8String:text];if(!string || !string.length)return;
        CTFontRef font=fontFor(args[14],args[15],args[16]);
        NSAttributedString *value=[[NSAttributedString alloc] initWithString:string attributes:@{
            (__bridge NSString*)kCTFontAttributeName:(__bridge id)font,
            (__bridge NSString*)kCTForegroundColorFromContextAttributeName:@YES}];
        CTLineRef line=CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)value);
        int width=(int)ceil(CTLineGetTypographicBounds(line,NULL,NULL,NULL))+2,height=args[14]+6;
        if(width>0 && width<=8192 && height>0 && height<=128){
            unsigned char *mask=calloc((size_t)width,height);CGColorSpaceRef gray=CGColorSpaceCreateDeviceGray();
            CGContextRef context=mask?CGBitmapContextCreate(mask,width,height,8,width,gray,kCGImageAlphaNone):NULL;
            if(context){
                CGContextSetGrayFillColor(context,1,1);CGContextSetTextPosition(context,0,height-args[14]);CTLineDraw(line,context);
                for(int y=0;y<height;y++)for(int x=0;x<width;x++){
                    // The bitmap buffer is already in image row order. Reversing
                    // these rows mirrors CoreText glyphs vertically in the MIDP surface.
                    uint32_t alpha=mask[y*width+x];
                    em_blend(surface,args[6]+x,args[7]+y,(alpha<<24)|(uint32_t)args[0],args+1);
                }
                if(args[15]&4)for(int x=0;x<width-2;x++)em_blend(surface,args[6]+x,args[7]+args[14]+1,0xff000000u|(uint32_t)args[0],args+1);
                CGContextRelease(context);
            }
            CGColorSpaceRelease(gray);free(mask);
        }
        CFRelease(line);CFRelease(font);
    }
}
void em_platform_status(int tabId, const char *text) {
    @autoreleasepool {
        NSString *value=[[NSString alloc] initWithUTF8String:text]?:@"Runtime error";
        fprintf(stdout,"[STATUS tab=%d] %s\n",tabId,text);fflush(stdout);
        NSDictionary *info=@{@"tabId":@(tabId),@"text":value};
        dispatch_async(dispatch_get_main_queue(), ^{[[NSNotificationCenter defaultCenter] postNotificationName:EmStatusNotification object:info];});
    }
}
void em_platform_modal(int tabId, const char *title,const char *value,int maxSize,int constraints,const char **labels,int count) {
    @autoreleasepool {
        NSString *heading=title?[[NSString alloc] initWithUTF8String:title]:nil;
        NSString *body=value?[[NSString alloc] initWithUTF8String:value]:@"";
        NSMutableArray *commands=[NSMutableArray new];for(int i=0;i<count;i++){
            NSString *label=labels[i]?[[NSString alloc] initWithUTF8String:labels[i]]:@"";[commands addObject:label?:@""];
        }
        NSDictionary *info=@{@"tabId":@(tabId),@"title":heading?:[NSNull null],@"value":body?:@"",@"max":@(maxSize),@"constraints":@(constraints),@"commands":commands};
        dispatch_async(dispatch_get_main_queue(), ^{[[NSNotificationCenter defaultCenter] postNotificationName:EmModalNotification object:info];});
    }
}
void em_platform_tab_finished(int tabId, int result) {
    @autoreleasepool {
        fprintf(stdout,"[TAB_FINISHED tab=%d result=%d]\n",tabId,result);fflush(stdout);
        NSDictionary *info=@{@"tabId":@(tabId),@"result":@(result)};
        dispatch_async(dispatch_get_main_queue(), ^{[[NSNotificationCenter defaultCenter] postNotificationName:EmTabFinishedNotification object:info];});
    }
}
void em_platform_browse(const char *url) {
    @autoreleasepool {
        NSURL *value=[NSURL URLWithString:[[NSString alloc] initWithUTF8String:url]?:@""];
        if(![@[@"http",@"https"] containsObject:value.scheme.lowercaseString])return;
        dispatch_async(dispatch_get_main_queue(), ^{[[UIApplication sharedApplication] openURL:value options:@{} completionHandler:nil];});
    }
}
void em_platform_vibrate(int milliseconds) {if(milliseconds>0)dispatch_async(dispatch_get_main_queue(), ^{AudioServicesPlaySystemSound(kSystemSoundID_Vibrate);});}
void em_platform_tick(void) {
    static double lastHeartbeat;double now=NSProcessInfo.processInfo.systemUptime;
    if(now-lastHeartbeat<30)return;lastHeartbeat=now;
    initializeFrames();[frameLock lock];BOOL hidden=!presentationEnabled;[frameLock unlock];
    if(hidden){fprintf(stdout,"[BACKGROUND] host heartbeat uptime=%.0f\n",now);fflush(stdout);}
}
