#import <Foundation/Foundation.h>

@interface BackgroundNotificationController : NSObject
// Called on the main thread, like application/audio lifecycle notifications.
- (void)updateEnabled:(BOOL)enabled audioActive:(BOOL)audioActive gameCount:(NSUInteger)count;
- (void)requestPermissionIfNeeded;
@end
