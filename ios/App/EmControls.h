#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, EmControlIcon) {
    EmControlStop, EmControlAdd, EmControlTabs, EmControlKeyboard, EmControlLog,
    EmControlClose, EmControlExpand, EmControlPad, EmControlPadHidden, EmControlCollapse, EmControlImport
};

UIImage *EmControlImage(EmControlIcon icon);
UIBarButtonItem *EmIconItem(EmControlIcon icon, NSString *label, id target, SEL action);
void EmSetButtonIcon(UIButton *button, EmControlIcon icon, NSString *label);
