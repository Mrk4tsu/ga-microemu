#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSString * const EmStatusNotification;
FOUNDATION_EXPORT NSString * const EmModalNotification;
FOUNDATION_EXPORT NSString * const EmTabFinishedNotification;
NSData *EmConsumeFrame(int tabId, int *width, int *height);
void EmClearFrame(int tabId);
void EmClearAllFrames(void);
