#import "BackgroundNotificationController.h"
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#include <stdio.h>

static NSString *const statusIdentifier=@"GaEmulator.BackgroundStatus";

@interface BackgroundNotificationController () <UNUserNotificationCenterDelegate>
@property(nonatomic,strong) UNUserNotificationCenter *center;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL audioActive;
@property(nonatomic) BOOL hidden;
@property(nonatomic) BOOL submitting;
@property(nonatomic) BOOL requestingPermission;
@property(nonatomic) NSUInteger gameCount;
@property(nonatomic) NSUInteger revision;
@property(nonatomic,copy) NSString *lastRequestedKey;
- (void)refresh;
- (void)removeStatus;
@end

@implementation BackgroundNotificationController
- (instancetype)init {
    if((self=[super init])){
        _center=UNUserNotificationCenter.currentNotificationCenter;_center.delegate=self;
        _hidden=UIApplication.sharedApplication.applicationState==UIApplicationStateBackground;
        NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(enteredBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [nc addObserver:self selector:@selector(enteringForeground:) name:UIApplicationWillEnterForegroundNotification object:nil];
        // A previous process may have been killed before it could remove its status.
        [self removeStatus];
    }return self;
}
- (void)dealloc {[[NSNotificationCenter defaultCenter] removeObserver:self];}
- (void)updateEnabled:(BOOL)enabled audioActive:(BOOL)audioActive gameCount:(NSUInteger)count {
    if(self.enabled==enabled && self.audioActive==audioActive && self.gameCount==count)return;
    self.enabled=enabled;self.audioActive=audioActive;self.gameCount=count;self.revision++;
    [self refresh];
}
- (void)requestPermissionIfNeeded {
    if(self.requestingPermission || !self.enabled || !self.gameCount || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    self.requestingPermission=YES;
    [self.center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings){
        dispatch_async(dispatch_get_main_queue(),^{
            if(settings.authorizationStatus!=UNAuthorizationStatusNotDetermined || !self.enabled || !self.gameCount || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive){
                self.requestingPermission=NO;[self refresh];return;
            }
            // Ask in context, after background mode is enabled for a running game.
            [self.center requestAuthorizationWithOptions:UNAuthorizationOptionAlert completionHandler:^(BOOL granted,NSError *error){
                dispatch_async(dispatch_get_main_queue(),^{
                    self.requestingPermission=NO;
                    self.revision++; // Invalidate any settings read made before the answer.
                    if(error)fprintf(stderr,"[BACKGROUND_NOTIFICATION] permission failed: %s\n",error.localizedDescription.UTF8String);
                    fprintf(stdout,"[BACKGROUND_NOTIFICATION] permission=%d\n",granted);fflush(stdout);
                    [self refresh];
                });
            }];
        });
    }];
}
- (void)removeStatus {
    [self.center removePendingNotificationRequestsWithIdentifiers:@[statusIdentifier]];
    [self.center removeDeliveredNotificationsWithIdentifiers:@[statusIdentifier]];
    self.lastRequestedKey=nil;
}
- (void)enteredBackground:(NSNotification *)notification {
    self.hidden=YES;self.revision++;[self refresh];
}
- (void)enteringForeground:(NSNotification *)notification {
    self.hidden=NO;self.revision++;[self removeStatus];
}
- (void)refresh {
    if(!self.hidden || !self.enabled || !self.gameCount){[self removeStatus];return;}
    NSString *key=[NSString stringWithFormat:@"%lu:%d",(unsigned long)self.gameCount,self.audioActive];
    if(self.submitting || [self.lastRequestedKey isEqualToString:key])return;
    self.submitting=YES;NSUInteger revision=self.revision;
    [self.center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings){
        dispatch_async(dispatch_get_main_queue(),^{
            if(revision!=self.revision){self.submitting=NO;[self refresh];return;}
            if(settings.authorizationStatus!=UNAuthorizationStatusAuthorized && settings.authorizationStatus!=UNAuthorizationStatusProvisional){
                self.submitting=NO;
                fprintf(stdout,"[BACKGROUND_NOTIFICATION] skipped: permission=%ld\n",(long)settings.authorizationStatus);fflush(stdout);return;
            }
            UNMutableNotificationContent *content=[UNMutableNotificationContent new];
            content.title=self.audioActive?@"Chạy nền đã bật":@"Chạy nền bị gián đoạn";
            content.body=[NSString stringWithFormat:@"%lu game. Chạm để mở ứng dụng.",(unsigned long)self.gameCount];
            content.threadIdentifier=statusIdentifier;
            // One quiet status, updated only when count or audio state changes.
            [self.center removeDeliveredNotificationsWithIdentifiers:@[statusIdentifier]];
            self.lastRequestedKey=key;
            UNNotificationRequest *request=[UNNotificationRequest requestWithIdentifier:statusIdentifier content:content trigger:nil];
            [self.center addNotificationRequest:request withCompletionHandler:^(NSError *error){
                dispatch_async(dispatch_get_main_queue(),^{
                    self.submitting=NO;
                    if(error){self.lastRequestedKey=nil;fprintf(stderr,"[BACKGROUND_NOTIFICATION] delivery failed: %s\n",error.localizedDescription.UTF8String);}
                    // Serialize adds. A stale completion must not restore a status
                    // after foreground/Stop, or erase a newer notification.
                    if(revision!=self.revision){[self removeStatus];[self refresh];}
                });
            }];
        });
    }];
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler {
    // A notification submitted just before foregrounding should stay hidden.
    completionHandler(0);
}
@end
