#import <Foundation/Foundation.h>
#include <stdint.h>

FOUNDATION_EXPORT NSString *const EmMemoryWillCleanNotification;
uint64_t EmAppMemoryBytes(void);
float EmAppCpuUsage(void);

@interface MemoryManager : NSObject
+ (instancetype)shared;
@property(nonatomic,readonly) BOOL enabled;
@property(nonatomic,readonly) uint32_t thresholdMB;
@property(nonatomic,readonly) uint32_t intervalSeconds;
@property(nonatomic,readonly) BOOL cleaning;
@property(nonatomic,readonly) BOOL canClean;
@property(nonatomic,readonly,copy) NSString *resultText;
- (void)applyEnabled:(BOOL)enabled thresholdMB:(uint32_t)mb intervalSeconds:(uint32_t)seconds;
- (void)cleanNow;
@end
