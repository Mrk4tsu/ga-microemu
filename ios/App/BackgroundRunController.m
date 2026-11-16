#import "BackgroundRunController.h"
#import "BackgroundNowPlayingController.h"
#import "AppPlatform.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#include "background_policy.h"
#include <stdio.h>

NSString *const EmBackgroundRunChangedNotification=@"GaEmulatorBackgroundRunChanged";
static NSString *const enabledKey=@"GaEmulator.BackgroundRun";

@interface BackgroundRunController () <AVAudioPlayerDelegate>
@property(nonatomic,readwrite) BOOL enabled;
@property(nonatomic,readwrite) BOOL keepingAlive;
@property(nonatomic,strong) AVAudioPlayer *player;
@property(nonatomic) NSUInteger runningGames;
@property(nonatomic) BOOL interrupted;
@property(nonatomic) BOOL sessionOwned;
@property(nonatomic) BOOL pausedByUser;
@property(nonatomic,strong) BackgroundNowPlayingController *nowPlaying;
- (BOOL)startAudio:(NSError **)error;
- (void)stopAudio;
- (void)pauseBackground;
- (void)resumeBackground;
@end
@implementation BackgroundRunController
+ (instancetype)shared {
    static BackgroundRunController *controller;static dispatch_once_t once;
    dispatch_once(&once,^{controller=[BackgroundRunController new];});return controller;
}
- (instancetype)init {
    if((self=[super init])){
        _enabled=[NSUserDefaults.standardUserDefaults boolForKey:enabledKey];
        _nowPlaying=[BackgroundNowPlayingController new];
        __weak BackgroundRunController *weakSelf=self;
        _nowPlaying.onPlay=^{[weakSelf resumeBackground];};
        _nowPlaying.onPause=^{[weakSelf pauseBackground];};
        _nowPlaying.onStop=^{[weakSelf setEnabled:NO error:nil];};
        NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(willResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(didBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(interruption:) name:AVAudioSessionInterruptionNotification object:nil];
        [nc addObserver:self selector:@selector(mediaReset:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
        [nc addObserver:self selector:@selector(mediaLost:) name:AVAudioSessionMediaServicesWereLostNotification object:nil];
        [nc addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
        [nc addObserver:self selector:@selector(terminating:) name:UIApplicationWillTerminateNotification object:nil];
    }return self;
}
- (NSString *)statusText {
    if(!self.enabled)return @"Chạy nền: Tắt";
    if(self.pausedByUser)return @"Chạy nền: Tạm dừng";
    return self.runningGames && !self.keepingAlive?@"Chạy nền: Gián đoạn":@"Chạy nền: Bật";
}
- (void)notifyChanged {
    [self.nowPlaying updateEnabled:self.enabled audioActive:self.keepingAlive userPaused:self.pausedByUser gameCount:self.runningGames];
    [[NSNotificationCenter defaultCenter] postNotificationName:EmBackgroundRunChangedNotification object:self];
}
- (void)setAlive:(BOOL)alive {
    if(self.keepingAlive==alive)return;
    self.keepingAlive=alive;
    fprintf(stdout,"[BACKGROUND] enabled=%d audio_active=%d games=%lu\n",self.enabled,alive,(unsigned long)self.runningGames);fflush(stdout);
    [self notifyChanged];
}
- (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error {
    BOOL previous=self.enabled,wasPaused=self.pausedByUser;self.enabled=enabled;self.pausedByUser=NO;
    if(enabled && self.runningGames && ![self startAudio:error]){
        self.enabled=previous;self.pausedByUser=wasPaused;[self notifyChanged];return NO;
    }
    if(!enabled)[self stopAudio];
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:enabledKey];
    [self notifyChanged];
    return YES;
}
- (void)setRunningGameCount:(NSUInteger)count {
    if(self.runningGames==count)return;
    self.runningGames=count;
    if(!count){self.pausedByUser=NO;[self stopAudio];}
    else if(self.enabled && !self.interrupted && !self.pausedByUser){
        NSError *error=nil;
        if(![self startAudio:&error]){fprintf(stderr,"[BACKGROUND] start failed: %s\n",error.localizedDescription.UTF8String);}
    }
    [self notifyChanged];
}
- (BOOL)startAudio:(NSError **)error {
    if(self.player.isPlaying){[self setAlive:YES];return YES;}
    // Register transport commands before activating playback; both are part
    // of eligibility for the system's Now Playing surface.
    [self.nowPlaying updateEnabled:self.enabled audioActive:NO userPaused:self.pausedByUser gameCount:self.runningGames];
    AVAudioSession *session=AVAudioSession.sharedInstance;
    // A mixable session is not eligible for the system's Now Playing controls.
    if(![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:error]
       || ![session setActive:YES error:error]){[self stopAudio];return NO;}
    self.sessionOwned=YES;
    if(!self.player){
        NSMutableData *wave=[NSMutableData dataWithLength:EM_BACKGROUND_WAVE_SIZE];
        em_background_wave(wave.mutableBytes,wave.length);
        self.player=[[AVAudioPlayer alloc] initWithData:wave error:error];self.player.delegate=self;
        self.player.numberOfLoops=-1;self.player.volume=1;
    }
    BOOL success=self.player && [self.player prepareToPlay] && [self.player play];
    if(!success){
        if(error && !*error)*error=[NSError errorWithDomain:@"GaEmulator.Background" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Không khởi động được âm thanh nền."}];
        [self stopAudio];return NO;
    }
    self.interrupted=NO;[self setAlive:YES];return YES;
}
- (void)stopAudio {
    [self.player stop];self.player=nil;
    if(self.sessionOwned){
        [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        self.sessionOwned=NO;
    }
    [self setAlive:NO];
}
- (void)willResignActive:(NSNotification *)notification {EmSetPresentationEnabled(NO);}
- (void)pauseBackground {
    if(!self.enabled || !self.runningGames)return;
    self.pausedByUser=YES;[self stopAudio];[self notifyChanged];
}
- (void)resumeBackground {
    if(!self.enabled || !self.runningGames)return;
    self.pausedByUser=NO;NSError *error=nil;
    if(![self startAudio:&error])fprintf(stderr,"[BACKGROUND] remote resume failed: %s\n",error.localizedDescription.UTF8String);
    [self notifyChanged];
}
- (void)terminating:(NSNotification *)notification {[self setRunningGameCount:0];}
- (void)didBecomeActive:(NSNotification *)notification {
    EmSetPresentationEnabled(YES);self.interrupted=NO;
    if(self.enabled && self.runningGames && !self.pausedByUser){
        NSError *error=nil;if(![self startAudio:&error])fprintf(stderr,"[BACKGROUND] foreground retry failed: %s\n",error.localizedDescription.UTF8String);
    }
}
- (void)interruption:(NSNotification *)notification {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self interruption:notification];});return;}
    NSUInteger type=[notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
    if(type==AVAudioSessionInterruptionTypeBegan){
        self.interrupted=YES;self.sessionOwned=NO;[self.player pause];[self setAlive:NO];
    }else {
        self.interrupted=NO;
        BOOL mayResume=([notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue]&AVAudioSessionInterruptionOptionShouldResume)!=0;
        if(self.enabled && self.runningGames && !self.pausedByUser && (mayResume || UIApplication.sharedApplication.applicationState==UIApplicationStateActive)){
            NSError *error=nil;if(![self startAudio:&error])fprintf(stderr,"[BACKGROUND] resume failed: %s\n",error.localizedDescription.UTF8String);
        }
    }
}
- (void)mediaLost:(NSNotification *)notification {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self mediaLost:notification];});return;}
    self.interrupted=YES;self.sessionOwned=NO;self.player=nil;[self setAlive:NO];
}
- (void)mediaReset:(NSNotification *)notification {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self mediaReset:notification];});return;}
    self.player=nil;self.sessionOwned=NO;self.interrupted=NO;[self setAlive:NO];
    if(self.enabled && self.runningGames && !self.pausedByUser){
        NSError *error=nil;if(![self startAudio:&error])fprintf(stderr,"[BACKGROUND] media reset retry failed: %s\n",error.localizedDescription.UTF8String);
    }
}
- (void)routeChanged:(NSNotification *)notification {
    // Route changes can stop playback without a matching interruption-ended event.
    dispatch_async(dispatch_get_main_queue(),^{[self setAlive:self.player.isPlaying];});
}
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    if(player!=self.player)return;
    fprintf(stderr,"[BACKGROUND] audio error: %s\n",error.localizedDescription.UTF8String);
    [self stopAudio];
}
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {if(player==self.player)[self stopAudio];}
@end
