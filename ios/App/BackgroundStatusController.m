#import "BackgroundStatusController.h"
#import "MemoryManager.h"
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UserNotifications/UserNotifications.h>
#include "background_policy.h"
#include <stdio.h>

static NSString *const notificationID=@"GaEmulator.BackgroundStatus";
// A selector-only boundary avoids linking the iOS 12 executable against Swift
// or ActivityKit. The framework implements these @objc methods on iOS 16.1+.
@protocol EmLiveActivityDisplay <NSObject>
@property(nonatomic,readonly) BOOL userDismissed;
- (void)prepareForForeground;
- (BOOL)renderStatus:(NSInteger)status memoryBytes:(uint64_t)bytes cpuPercent:(double)cpu tabCount:(NSInteger)count;
@end

@interface BackgroundStatusController () <UNUserNotificationCenterDelegate>
@property(nonatomic,strong) id<EmLiveActivityDisplay> live;
@property(nonatomic,strong) NSBundle *liveBundle;
@property(nonatomic,strong) UNUserNotificationCenter *center;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic) EmBackgroundStatus status;
@property(nonatomic) NSUInteger gameCount;
@property(nonatomic) BOOL hidden;
@property(nonatomic) BOOL legacy;
@property(nonatomic) BOOL submitting;
@property(nonatomic) BOOL askingPermission;
@property(nonatomic) NSUInteger revision;
@property(nonatomic,copy) NSString *lastRequestedKey;
- (void)refresh;
- (void)removeNotification;
- (void)postNotification;
@end

@implementation BackgroundStatusController
- (instancetype)init {
    if((self=[super init])){
        _center=UNUserNotificationCenter.currentNotificationCenter;_center.delegate=self;
        _hidden=UIApplication.sharedApplication.applicationState==UIApplicationStateBackground;
        // Clear this app's old media metadata. No new Now Playing metadata or
        // transport commands are registered by this version.
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=nil;
        [self removeNotification];
        if(@available(iOS 16.1,*)){
            NSString *path=[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"GaEmulatorLiveBridge.framework"];
            _liveBundle=[NSBundle bundleWithPath:path];NSError *error=nil;
            if([_liveBundle loadAndReturnError:&error]){
                Class bridge=NSClassFromString(@"EmLiveActivityBridge");
                if([bridge instancesRespondToSelector:@selector(renderStatus:memoryBytes:cpuPercent:tabCount:)])_live=[bridge new];
            }
            if(!_live)fprintf(stderr,"[LIVE_ACTIVITY] bridge unavailable: %s\n",(error.localizedDescription?:@"missing framework/class").UTF8String);
        }
        NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(enteredBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(enteringForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        [nc addObserver:self selector:@selector(becameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    }return self;
}
- (void)updateEnabled:(BOOL)enabled audioActive:(BOOL)active gameCount:(NSUInteger)count {
    EmBackgroundStatus next=em_background_status(enabled,count,active,0);
    if(self.status==next && self.gameCount==count)return;
    self.status=next;self.gameCount=count;self.revision++;[self refresh];
}
- (void)refresh {
    uint64_t bytes=self.status?EmAppMemoryBytes():0;
    double cpu=self.status?EmAppCpuUsage():-1;
    BOOL hasLive=[self.live renderStatus:self.status memoryBytes:bytes cpuPercent:cpu tabCount:self.gameCount];
    BOOL legacy=self.status!=EM_BACKGROUND_OFF && !hasLive && !self.live.userDismissed;
    if(self.legacy!=legacy){self.legacy=legacy;self.revision++;}
    if(hasLive && self.status==EM_BACKGROUND_RUNNING){
        if(!self.timer){
            __weak BackgroundStatusController *weakSelf=self;
            self.timer=[NSTimer timerWithTimeInterval:15 repeats:YES block:^(NSTimer *timer){[weakSelf refresh];}];
            self.timer.tolerance=3;[NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
        }
    }else {[self.timer invalidate];self.timer=nil;}
    if(legacy)[self requestPermission];
    [self postNotification];
}
- (void)enteredBackground:(NSNotification *)notification {self.hidden=YES;self.revision++;[self refresh];}
- (void)enteringForeground:(NSNotification *)notification {self.hidden=NO;self.revision++;[self removeNotification];}
- (void)becameActive:(NSNotification *)notification {
    self.hidden=NO;self.revision++;[self.live prepareForForeground];[self refresh];
}
- (NSString *)metricsText {
    char text[128];em_background_metrics(text,sizeof(text),EmAppMemoryBytes(),EmAppCpuUsage(),self.gameCount);
    return [NSString stringWithUTF8String:text];
}
- (void)removeNotification {
    [self.center removePendingNotificationRequestsWithIdentifiers:@[notificationID]];
    [self.center removeDeliveredNotificationsWithIdentifiers:@[notificationID]];
    self.lastRequestedKey=nil;
}
- (void)requestPermission {
    if(self.askingPermission || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    self.askingPermission=YES;
    [self.center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings){
        dispatch_async(dispatch_get_main_queue(),^{
            if(settings.authorizationStatus!=UNAuthorizationStatusNotDetermined || !self.legacy || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){
                self.askingPermission=NO;return;
            }
            [self.center requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(BOOL granted,NSError *error){
                dispatch_async(dispatch_get_main_queue(),^{
                    self.askingPermission=NO;self.revision++;
                    if(error)fprintf(stderr,"[BACKGROUND_NOTIFICATION] permission failed: %s\n",error.localizedDescription.UTF8String);
                    [self postNotification];
                });
            }];
        });
    }];
}
- (void)postNotification {
    if(!self.legacy || !self.hidden || self.status==EM_BACKGROUND_OFF){[self removeNotification];return;}
    NSString *key=[NSString stringWithFormat:@"%d:%lu",self.status,(unsigned long)self.gameCount];
    if(self.submitting || [self.lastRequestedKey isEqualToString:key])return;
    self.submitting=YES;NSUInteger revision=self.revision;
    [self.center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings){
        dispatch_async(dispatch_get_main_queue(),^{
            if(revision!=self.revision){self.submitting=NO;[self postNotification];return;}
            if(settings.authorizationStatus!=UNAuthorizationStatusAuthorized && settings.authorizationStatus!=UNAuthorizationStatusProvisional){
                self.submitting=NO;return;
            }
            UNMutableNotificationContent *content=[UNMutableNotificationContent new];
            content.title=self.status==EM_BACKGROUND_RUNNING?@"GaEmulator đang chạy nền":@"GaEmulator bị gián đoạn nền";
            content.body=[self metricsText];content.threadIdentifier=notificationID;
            content.subtitle=[NSString stringWithFormat:@"Cập nhật %@",[NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle]];
            [self.center removeDeliveredNotificationsWithIdentifiers:@[notificationID]];self.lastRequestedKey=key;
            [self.center addNotificationRequest:[UNNotificationRequest requestWithIdentifier:notificationID content:content trigger:nil] withCompletionHandler:^(NSError *error){
                dispatch_async(dispatch_get_main_queue(),^{
                    self.submitting=NO;
                    if(error){self.lastRequestedKey=nil;fprintf(stderr,"[BACKGROUND_NOTIFICATION] delivery failed: %s\n",error.localizedDescription.UTF8String);}
                    if(revision!=self.revision){[self removeNotification];[self postNotification];}
                });
            }];
        });
    }];
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {completionHandler(0);}
- (void)dealloc {[[NSNotificationCenter defaultCenter] removeObserver:self];[self.timer invalidate];}
@end
