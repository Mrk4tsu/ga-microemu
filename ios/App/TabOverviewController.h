#import <UIKit/UIKit.h>

/** UI snapshots share the existing immutable frame; they never copy framebuffer pixels. */
@interface EmTabPreview : NSObject
@property(nonatomic) int tabId;
@property(nonatomic,copy) NSString *title;
@property(nonatomic,copy) NSString *status;
@property(nonatomic,strong) UIImage *image;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL sleeping;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL stopping;
@end

@interface TabOverviewController : UICollectionViewController <UICollectionViewDelegateFlowLayout>
@property(nonatomic,copy) void (^onSelectTab)(int tabId);
@property(nonatomic,copy) void (^onCloseTab)(int tabId);
- (void)displayTabs:(NSArray<EmTabPreview *> *)tabs;
- (void)updateImage:(UIImage *)image forTab:(int)tabId;
@end
