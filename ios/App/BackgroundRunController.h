#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const EmBackgroundRunChangedNotification;
@interface BackgroundRunController : NSObject
+ (instancetype)shared;
@property(nonatomic,readonly) BOOL enabled;
@property(nonatomic,readonly) BOOL keepingAlive;
@property(nonatomic,readonly,copy) NSString *statusText;
- (BOOL)setEnabled:(BOOL)enabled error:(NSError **)error;
- (void)setRunningGameCount:(NSUInteger)count;
@end
