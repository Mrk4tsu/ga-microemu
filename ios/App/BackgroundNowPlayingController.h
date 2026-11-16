#import <Foundation/Foundation.h>

@interface BackgroundNowPlayingController : NSObject
@property(nonatomic,copy) void (^onPlay)(void);
@property(nonatomic,copy) void (^onPause)(void);
@property(nonatomic,copy) void (^onStop)(void);
// Main thread. Keep metadata available while foreground/inactive too, so the
// user can pull down the system's media controls without first pressing Home.
- (void)updateEnabled:(BOOL)enabled audioActive:(BOOL)active userPaused:(BOOL)paused gameCount:(NSUInteger)count;
@end
