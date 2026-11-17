#import <Foundation/Foundation.h>

@interface BackgroundStatusController : NSObject
// Main-thread status rendering. Live Activity when supported, one ordinary
// notification per background/state change otherwise; never media controls.
- (void)updateEnabled:(BOOL)enabled audioActive:(BOOL)active gameCount:(NSUInteger)count;
@end
