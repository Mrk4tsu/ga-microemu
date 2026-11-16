#import "BackgroundNowPlayingController.h"
#import "MemoryManager.h"
#import <UIKit/UIKit.h>
#import <MediaPlayer/MediaPlayer.h>
#import <UserNotifications/UserNotifications.h>
#include "background_policy.h"
#include <stdio.h>

@interface BackgroundNowPlayingController ()
@property(nonatomic) EmBackgroundStatus status;
@property(nonatomic) NSUInteger gameCount;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) MPMediaItemArtwork *artwork;
@property(nonatomic) BOOL commandsInstalled;
- (void)publish;
- (void)installCommands;
- (void)clear;
@end

@implementation BackgroundNowPlayingController
- (instancetype)init {
    if((self=[super init])){
        // Remove the previous version's ordinary notification without asking
        // for notification permission. Now Playing does not use this permission.
        UNUserNotificationCenter *notifications=UNUserNotificationCenter.currentNotificationCenter;
        [notifications removePendingNotificationRequestsWithIdentifiers:@[@"GaEmulator.BackgroundStatus"]];
        [notifications removeDeliveredNotificationsWithIdentifiers:@[@"GaEmulator.BackgroundStatus"]];
        MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=nil;
    }return self;
}
- (MPMediaItemArtwork *)makeArtwork {
    NSDictionary *icons=NSBundle.mainBundle.infoDictionary[@"CFBundleIcons"];
    NSString *name=[icons[@"CFBundlePrimaryIcon"][@"CFBundleIconFiles"] lastObject];
    UIImage *image=name?[UIImage imageNamed:name]:nil;
    if(!image){
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(128,128),YES,1);
        [[UIColor colorWithRed:0.06 green:0.12 blue:0.18 alpha:1] setFill];UIRectFill(CGRectMake(0,0,128,128));
        [@"G" drawInRect:CGRectMake(32,20,80,90) withAttributes:@{NSFontAttributeName:[UIFont boldSystemFontOfSize:76],NSForegroundColorAttributeName:UIColor.whiteColor}];
        image=UIGraphicsGetImageFromCurrentImageContext();UIGraphicsEndImageContext();
    }
    return [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size requestHandler:^UIImage *(CGSize size){return image;}];
}
- (void)updateEnabled:(BOOL)enabled audioActive:(BOOL)active userPaused:(BOOL)paused gameCount:(NSUInteger)count {
    EmBackgroundStatus next=em_background_status(enabled,count,active,paused);
    BOOL changed=self.status!=next || self.gameCount!=count;
    self.status=next;self.gameCount=count;
    if(next==EM_BACKGROUND_OFF){[self clear];return;}
    if(!self.commandsInstalled)[self installCommands];
    if(!self.artwork)self.artwork=[self makeArtwork];
    // Sample every five seconds while audio actually runs. An interrupted or
    // paused session publishes once and stops sampling until it resumes.
    if(next==EM_BACKGROUND_RUNNING && !self.timer){
        __weak BackgroundNowPlayingController *weakSelf=self;
        self.timer=[NSTimer timerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer){[weakSelf publish];}];
        self.timer.tolerance=1;
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }else if(next!=EM_BACKGROUND_RUNNING){[self.timer invalidate];self.timer=nil;}
    if(changed)[self publish];
}
- (void)publish {
    if(self.status==EM_BACKGROUND_OFF)return;
    char metrics[128];
    em_background_metrics(metrics,sizeof(metrics),EmAppMemoryBytes(),EmAppCpuUsage(),self.gameCount);
    NSString *title=self.status==EM_BACKGROUND_RUNNING?@"GaEmulator đang chạy nền":
        self.status==EM_BACKGROUND_PAUSED?@"GaEmulator đã tạm dừng nền":@"GaEmulator bị gián đoạn nền";
    NSMutableDictionary *info=[@{MPMediaItemPropertyTitle:title,
        MPMediaItemPropertyArtist:[NSString stringWithUTF8String:metrics],
        MPNowPlayingInfoPropertyMediaType:@(MPNowPlayingInfoMediaTypeAudio),
        MPNowPlayingInfoPropertyIsLiveStream:@YES,
        MPNowPlayingInfoPropertyPlaybackRate:@(self.status==EM_BACKGROUND_RUNNING?1.0:0.0)} mutableCopy];
    if(self.artwork)info[MPMediaItemPropertyArtwork]=self.artwork;
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=info;
    fprintf(stdout,"[NOW_PLAYING] state=%d %s\n",self.status,metrics);fflush(stdout);
}
- (void)installCommands {
    MPRemoteCommandCenter *commands=MPRemoteCommandCenter.sharedCommandCenter;
    [commands.playCommand addTarget:self action:@selector(play:)];commands.playCommand.enabled=YES;
    [commands.pauseCommand addTarget:self action:@selector(pause:)];commands.pauseCommand.enabled=YES;
    [commands.togglePlayPauseCommand addTarget:self action:@selector(toggle:)];commands.togglePlayPauseCommand.enabled=YES;
    [commands.stopCommand addTarget:self action:@selector(stop:)];commands.stopCommand.enabled=YES;
    commands.nextTrackCommand.enabled=NO;commands.previousTrackCommand.enabled=NO;
    commands.seekForwardCommand.enabled=NO;commands.seekBackwardCommand.enabled=NO;
    commands.skipForwardCommand.enabled=NO;commands.skipBackwardCommand.enabled=NO;
    commands.changePlaybackPositionCommand.enabled=NO;
    self.commandsInstalled=YES;
}
- (MPRemoteCommandHandlerStatus)play:(MPRemoteCommandEvent *)event {
    dispatch_async(dispatch_get_main_queue(),^{if(self.status!=EM_BACKGROUND_OFF && self.onPlay)self.onPlay();});return MPRemoteCommandHandlerStatusSuccess;
}
- (MPRemoteCommandHandlerStatus)pause:(MPRemoteCommandEvent *)event {
    dispatch_async(dispatch_get_main_queue(),^{if(self.status!=EM_BACKGROUND_OFF && self.onPause)self.onPause();});return MPRemoteCommandHandlerStatusSuccess;
}
- (MPRemoteCommandHandlerStatus)toggle:(MPRemoteCommandEvent *)event {
    dispatch_async(dispatch_get_main_queue(),^{
        if(self.status==EM_BACKGROUND_OFF)return;
        if(self.status==EM_BACKGROUND_RUNNING){if(self.onPause)self.onPause();}
        else if(self.onPlay)self.onPlay();
    });return MPRemoteCommandHandlerStatusSuccess;
}
- (MPRemoteCommandHandlerStatus)stop:(MPRemoteCommandEvent *)event {
    dispatch_async(dispatch_get_main_queue(),^{if(self.status!=EM_BACKGROUND_OFF && self.onStop)self.onStop();});return MPRemoteCommandHandlerStatusSuccess;
}
- (void)clear {
    [self.timer invalidate];self.timer=nil;self.artwork=nil;
    if(!self.commandsInstalled)return;
    MPRemoteCommandCenter *commands=MPRemoteCommandCenter.sharedCommandCenter;
    for(MPRemoteCommand *command in @[commands.playCommand,commands.pauseCommand,commands.togglePlayPauseCommand,commands.stopCommand]){
        [command removeTarget:self];command.enabled=NO;
    }
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo=nil;
    self.commandsInstalled=NO;
    fprintf(stdout,"[NOW_PLAYING] cleared\n");fflush(stdout);
}
- (void)dealloc {[self clear];}
@end
