#import <UIKit/UIKit.h>
@interface MemorySettingsController : UITableViewController
+ (BOOL)hasOpenSettings;
@property(nonatomic,copy) void (^onClose)(void);
@end
