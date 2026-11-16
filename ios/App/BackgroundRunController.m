#import "BackgroundRunController.h"
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
- (BOOL)startAudio:(NSError **)error;
- (void)stopAudio;
@end
@implementation BackgroundRunController
+ (instancetype)shared {
    static BackgroundRunController *controller;static dispatch_once_t once;
    dispatch_once(&once,^{controller=[BackgroundRunController new];});return controller;
}
- (instancetype)init {
    if((self=[super init])){
        _enabled=[NSUserDefaults.standardUserDefaults boolForKey:enabledKey];
        NSNotificationCenter *nc=NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(willResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(didBecomeActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(interruption:) name:AVAudioSessionInterruptionNotification object:nil];
        [nc addObserver:self selector:@selector(mediaReset:) name:AVAudioSessionMediaServicesWereResetNotification object:nil];
        [nc addObserver:self selector:@selector(mediaLost:) name:AVAudioSessionMediaServicesWereLostNotification object:nil];
        [nc addObserver:self selector:@selector(routeChanged:) name:AVAudioSessionRouteChangeNotification object:nil];
    }return self;
}
- (NSString *)statusText {
    if(!self.enabled)return @"Chạy nền: Tắt";
    return self.runningGames && !self.keepingAlive?@"Chạy nền: Gián đoạn":@"Chạy nền: Bật";
}
- (void)notifyChanged {
    [[NSNotificationCenter defaultCenter] postNotificationName:EmBackgroundRunChangedNotification object:self];
}
- (void)setAlive:(BOOL)alive {
    if(self.keepingAlive==alive)return;
    self.keepingAlive=alive;
    fprintf(stdout,"[BACKGROUND] enabled=%d audio_active=%d games=%lu\n",self.enabled,alive,(unsigned long)self.runningGames);fflush(stdout);
    [self notifyChanged];
}
- (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error {
    BOOL previous=self.enabled;self.enabled=enabled;
    if(enabled && self.runningGames && ![self startAudio:error]){
        self.enabled=previous;[self notifyChanged];return NO;
    }
    if(!enabled)[self stopAudio];
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:enabledKey];
    [self notifyChanged];return YES;
}
- (void)setRunningGameCount:(NSUInteger)count {
    if(self.runningGames==count)return;
    self.runningGames=count;
    if(!count)[self stopAudio];
    else if(self.enabled && !self.interrupted){
        NSError *error=nil;
        if(![self startAudio:&error]){fprintf(stderr,"[BACKGROUND] start failed: %s\n",error.localizedDescription.UTF8String);}
    }
    [self notifyChanged];
}
- (BOOL)startAudio:(NSError **)error {
    if(self.player.isPlaying){[self setAlive:YES];return YES;}
    AVAudioSession *session=AVAudioSession.sharedInstance;
    if(![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers error:error]
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
- (void)didBecomeActive:(NSNotification *)notification {
    EmSetPresentationEnabled(YES);self.interrupted=NO;
    if(self.enabled && self.runningGames){
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
        if(self.enabled && self.runningGames && (mayResume || UIApplication.sharedApplication.applicationState==UIApplicationStateActive)){
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
    if(self.enabled && self.runningGames){
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
