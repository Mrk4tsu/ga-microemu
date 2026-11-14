#import <UIKit/UIKit.h>

/** Collects a validated launch size; never starts a game itself. */
@interface ScreenSizePicker : UITableViewController <UITextFieldDelegate>
@property(nonatomic,copy) void (^onFinish)(BOOL accepted, int width, int height, BOOL fullScreen);
- (instancetype)initWithJar:(NSURL *)jar fullWidth:(int)width fullHeight:(int)height;
@end
