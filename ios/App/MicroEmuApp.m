#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach/mach.h>
#import "AppPlatform.h"
#include "emulator.h"
#include <math.h>
#include <stdio.h>

static BOOL runtimeActive;
static void EmComputeVirtualSize(CGSize size, int *outWidth, int *outHeight) {
    if (size.width <= 0 || size.height <= 0) {
        *outWidth = 480;
        *outHeight = 320;
        return;
    }
    double width = size.width, height = size.height;
    double scale = 1.0;
    if (MAX(width, height) > 1920.0) scale = 1920.0 / MAX(width, height);
    if (MIN(width, height) * scale < 128.0) scale = 128.0 / MIN(width, height);
    int virtualWidth = (int)llround(width * scale);
    int virtualHeight = (int)llround(height * scale);
    if (virtualWidth < 128) virtualWidth = 128;
    if (virtualWidth > 1920) virtualWidth = 1920;
    if (virtualHeight < 128) virtualHeight = 128;
    if (virtualHeight > 1920) virtualHeight = 1920;
    *outWidth = virtualWidth;
    *outHeight = virtualHeight;
}
static NSURL *gamesDirectory(void) {
    NSURL *documents=[[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *games=[documents URLByAppendingPathComponent:@"Games" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:games withIntermediateDirectories:YES attributes:nil error:nil];return games;
}
static NSArray<NSURL*> *listGameJars(void) {
    NSArray<NSURL*> *items=[[[NSFileManager defaultManager] contentsOfDirectoryAtURL:gamesDirectory() includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL*url,NSDictionary*bindings){return [url.pathExtension.lowercaseString isEqualToString:@"jar"];}]];
    return [items sortedArrayUsingComparator:^NSComparisonResult(NSURL*a,NSURL*b){return [a.lastPathComponent localizedCaseInsensitiveCompare:b.lastPathComponent];}]?:@[];
}
static NSString *rmsPathForSlot(int slot) {
    NSURL *documents=[gamesDirectory() URLByDeletingLastPathComponent];
    NSURL *dir=slot<=1?[documents URLByAppendingPathComponent:@"RMS" isDirectory:YES]:[[documents URLByAppendingPathComponent:@"RMS-Tabs" isDirectory:YES] URLByAppendingPathComponent:[NSString stringWithFormat:@"tab-%d",slot] isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir.path;
}
static uint64_t emAppResidentMemory(void) {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    kern_return_t kr=task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&vmInfo,&count);
    if(kr==KERN_SUCCESS && vmInfo.phys_footprint>0)return (uint64_t)vmInfo.phys_footprint;
    struct task_basic_info basic;
    count=TASK_BASIC_INFO_COUNT;
    kr=task_info(mach_task_self(),TASK_BASIC_INFO,(task_info_t)&basic,&count);
    if(kr==KERN_SUCCESS)return (uint64_t)basic.resident_size;
    return 0;
}
static float emCurrentCpuUsage(void) {
    thread_array_t thread_list;
    mach_msg_type_number_t thread_count=0;
    if(task_threads(mach_task_self(),&thread_list,&thread_count)!=KERN_SUCCESS)return -1.0f;
    float tot_cpu=0.0f;
    for(mach_msg_type_number_t i=0;i<thread_count;i++){
        thread_basic_info_data_t thinfo;
        mach_msg_type_number_t thread_info_count=THREAD_BASIC_INFO_COUNT;
        if(thread_info(thread_list[i],THREAD_BASIC_INFO,(thread_info_t)&thinfo,&thread_info_count)==KERN_SUCCESS){
            if(!(thinfo.flags & TH_FLAGS_IDLE)){
                tot_cpu+=thinfo.cpu_usage/(float)TH_USAGE_SCALE*100.0f;
            }
        }
    }
    vm_deallocate(mach_task_self(),(vm_offset_t)thread_list,thread_count*sizeof(thread_t));
    return tot_cpu;
}
static UIColor *emSecondaryLabelColor(void) {
    if(@available(iOS 13.0,*))return UIColor.secondaryLabelColor;
    return [UIColor colorWithWhite:0.65 alpha:1];
}
static UIColor *emGroupedBgColor(void) {
    if(@available(iOS 13.0,*))return UIColor.systemGroupedBackgroundColor;
    return [UIColor colorWithWhite:0.08 alpha:1];
}
static UITableViewStyle emTableStyle(void) {
    if(@available(iOS 13.0,*))return UITableViewStyleInsetGrouped;
    return UITableViewStyleGrouped;
}
static NSData *emReadJarEntry(NSURL *jarURL, NSString *entryName) {
    if(!jarURL.path.length || !entryName.length)return nil;
    void *bytes=NULL;size_t size=0;
    if(!em_jar_read_entry(jarURL.path.fileSystemRepresentation,entryName.UTF8String,&bytes,&size))return nil;
    NSData *data=[NSData dataWithBytes:bytes length:size];
    em_jar_free(bytes);
    return data;
}
static NSDictionary<NSString*,NSString*> *emParseManifest(NSURL *jarURL) {
    NSData *raw=emReadJarEntry(jarURL,@"META-INF/MANIFEST.MF");
    if(!raw)return @{};
    NSString *text=[[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding]?:[[NSString alloc] initWithData:raw encoding:NSISOLatin1StringEncoding];
    if(!text)return @{};
    NSMutableDictionary<NSString*,NSString*> *headers=[NSMutableDictionary new];
    NSString *currentKey=nil;NSMutableString *currentVal=nil;
    for(NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]){
        if(!line.length)continue;
        if([line hasPrefix:@" "] && currentKey){[currentVal appendString:[line substringFromIndex:1]];continue;}
        if(currentKey)headers[currentKey]=[currentVal copy];
        NSRange colon=[line rangeOfString:@":"];
        if(colon.location!=NSNotFound && colon.location>0){
            currentKey=[line substringToIndex:colon.location];
            currentVal=[[[line substringFromIndex:colon.location+1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] mutableCopy];
        } else {currentKey=nil;currentVal=nil;}
    }
    if(currentKey)headers[currentKey]=[currentVal copy];
    return headers;
}
static UIImage *emRenderSquareIcon(UIImage *source) {
    if(!source)return nil;
    CGSize target=CGSizeMake(40,40);
    UIGraphicsBeginImageContextWithOptions(target,NO,0);
    CGContextRef ctx=UIGraphicsGetCurrentContext();
    UIBezierPath *clip=[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0,0,40,40) cornerRadius:8];
    [clip addClip];
    [[UIColor colorWithWhite:0.16 alpha:1] setFill];
    UIRectFill(CGRectMake(0,0,40,40));
    CGContextSetInterpolationQuality(ctx,source.size.width<=40?kCGInterpolationNone:kCGInterpolationHigh);
    CGFloat scale=MIN(36.0/MAX(1.0,source.size.width),36.0/MAX(1.0,source.size.height));
    CGFloat w=source.size.width*scale,h=source.size.height*scale;
    [source drawInRect:CGRectMake((40.0-w)/2.0,(40.0-h)/2.0,w,h)];
    UIImage *result=UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}
static UIImage *emFallbackJarIcon(void) {
    if(@available(iOS 13.0,*))return [UIImage systemImageNamed:@"gamecontroller.fill"];
    CGSize target=CGSizeMake(40,40);
    UIGraphicsBeginImageContextWithOptions(target,NO,0);
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0,0,40,40) cornerRadius:8] addClip];
    [[UIColor colorWithWhite:0.2 alpha:1] setFill];
    UIRectFill(CGRectMake(0,0,40,40));
    NSDictionary *attrs=@{NSFontAttributeName:[UIFont boldSystemFontOfSize:13],NSForegroundColorAttributeName:[UIColor colorWithWhite:0.85 alpha:1]};
    CGSize textSize=[@"JAR" sizeWithAttributes:attrs];
    [@"JAR" drawAtPoint:CGPointMake((40.0-textSize.width)/2.0,(40.0-textSize.height)/2.0) withAttributes:attrs];
    UIImage *result=UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}
static UIImage *emIconFromJar(NSURL *jarURL, NSString **outSuiteName) {
    NSDictionary<NSString*,NSString*> *manifest=emParseManifest(jarURL);
    if(outSuiteName)*outSuiteName=manifest[@"MIDlet-Name"]?:@"";
    NSMutableArray<NSString*> *candidates=[NSMutableArray new];
    NSString *m1=manifest[@"MIDlet-1"];
    if(m1.length){
        NSArray<NSString*> *parts=[m1 componentsSeparatedByString:@","];
        if(parts.count>=2){
            NSString *p=[parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if(p.length)[candidates addObject:p];
        }
    }
    NSString *mIcon=[manifest[@"MIDlet-Icon"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if(mIcon.length)[candidates addObject:mIcon];
    [candidates addObjectsFromArray:@[@"icon.png",@"res/icon.png",@"icons/icon.png"]];
    for(NSString *entry in candidates){
        NSData *data=emReadJarEntry(jarURL,entry);
        UIImage *decoded=data?[UIImage imageWithData:data]:nil;
        if(decoded)return emRenderSquareIcon(decoded);
    }
    return emFallbackJarIcon();
}
static NSString *emSuiteKeyForJar(NSURL *jarURL) {
    NSDictionary<NSString*,NSString*> *manifest=emParseManifest(jarURL);
    if(!manifest.count)return nil;
    NSString *vendor=manifest[@"MIDlet-Vendor"]?:@"null";
    NSString *name=manifest[@"MIDlet-Name"]?:@"MIDlet";
    NSString *input=[NSString stringWithFormat:@"%@\n%@",vendor,name];
    NSData *utf8=[input dataUsingEncoding:NSUTF8StringEncoding];
    if(!utf8)return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(utf8.bytes,(CC_LONG)utf8.length,digest);
#pragma clang diagnostic pop
    NSMutableString *hex=[NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH*2];
    for(int i=0;i<CC_SHA1_DIGEST_LENGTH;i++)[hex appendFormat:@"%02x",digest[i]];
    return hex;
}
static void emRemoveGameData(NSString *deletedSuiteKey, NSArray<NSURL*> *remainingJars) {
    NSFileManager *fm=[NSFileManager defaultManager];
    NSURL *documents=[gamesDirectory() URLByDeletingLastPathComponent];
    NSURL *rmsDir=[documents URLByAppendingPathComponent:@"RMS" isDirectory:YES];
    NSURL *rmsTabsDir=[documents URLByAppendingPathComponent:@"RMS-Tabs" isDirectory:YES];
    if(!remainingJars.count){
        [fm removeItemAtURL:rmsDir error:nil];
        [fm removeItemAtURL:rmsTabsDir error:nil];
        [fm removeItemAtURL:[documents URLByAppendingPathComponent:@"microemu.log"] error:nil];
        return;
    }
    [fm removeItemAtURL:[rmsDir URLByAppendingPathComponent:@"tmp" isDirectory:YES] error:nil];
    if(!deletedSuiteKey.length)return;
    NSMutableSet<NSString*> *activeKeys=[NSMutableSet new];
    for(NSURL *jar in remainingJars){
        NSString *key=emSuiteKeyForJar(jar);
        if(key.length)[activeKeys addObject:key];
    }
    if([activeKeys containsObject:deletedSuiteKey])return;
    [fm removeItemAtURL:[rmsDir URLByAppendingPathComponent:deletedSuiteKey isDirectory:YES] error:nil];
    NSArray<NSURL*> *tabDirs=[fm contentsOfDirectoryAtURL:rmsTabsDir includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    for(NSURL *tabDir in tabDirs){
        [fm removeItemAtURL:[tabDir URLByAppendingPathComponent:deletedSuiteKey isDirectory:YES] error:nil];
        NSArray<NSURL*> *rest=[fm contentsOfDirectoryAtURL:tabDir includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
        BOOL hasSuite=NO;
        for(NSURL *entry in rest){
            if(![entry.lastPathComponent isEqualToString:@"tmp"]){hasSuite=YES;break;}
        }
        if(!hasSuite)[fm removeItemAtURL:tabDir error:nil];
    }
    NSArray<NSURL*> *remainingTabs=[fm contentsOfDirectoryAtURL:rmsTabsDir includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    if(!remainingTabs.count)[fm removeItemAtURL:rmsTabsDir error:nil];
}

@interface GameScreen : UIImageView
@property(nonatomic) int tabId;
@property(nonatomic) int virtualWidth;
@property(nonatomic) int virtualHeight;
@property(nonatomic,weak) UITouch *pointer;
@end
@implementation GameScreen
- (CGPoint)position:(UITouch*)touch {
    CGSize size=self.bounds.size;CGFloat scale=MIN(size.width/self.virtualWidth,size.height/self.virtualHeight);
    CGPoint p=[touch locationInView:self];return CGPointMake((p.x-(size.width-self.virtualWidth*scale)/2)/scale,(p.y-(size.height-self.virtualHeight*scale)/2)/scale);
}
- (void)cancelPointer {
    if(!self.pointer)return;
    CGPoint p=[self position:self.pointer];
    em_tab_event(self.tabId,6,(int)p.x,(int)p.y,0,NULL);
    self.pointer=nil;
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if(self.pointer)return;UITouch*t=touches.anyObject;CGPoint p=[self position:t];
    if(p.x<0 || p.y<0 || p.x>=self.virtualWidth || p.y>=self.virtualHeight)return;
    self.pointer=t;em_tab_event(self.tabId,4,(int)p.x,(int)p.y,0,NULL);
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if(!self.pointer || ![touches containsObject:self.pointer])return;CGPoint p=[self position:self.pointer];em_tab_event(self.tabId,5,(int)p.x,(int)p.y,0,NULL);
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if(!self.pointer || ![touches containsObject:self.pointer])return;CGPoint p=[self position:self.pointer];em_tab_event(self.tabId,6,(int)p.x,(int)p.y,0,NULL);self.pointer=nil;
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {[self touchesEnded:touches withEvent:event];}
@end

@interface GameKeyTextField : UITextField
@property(nonatomic,copy) void (^onEmptyBackspace)(void);
@end
@implementation GameKeyTextField
- (void)deleteBackward {
    BOOL wasEmpty=(self.text.length==0);
    [super deleteBackward];
    if(wasEmpty && self.onEmptyBackspace)self.onEmptyBackspace();
}
@end

@interface GamePadButton : UIButton
@property(nonatomic,strong) NSArray<NSNumber*> *keyCodes;
@property(nonatomic,strong) NSTimer *repeatTimer;
@property(nonatomic,strong) UIColor *idleColor;
@property(nonatomic) BOOL active;
@property(nonatomic) int pressedTabId;
@end
@implementation GamePadButton
@end

@interface GameTab : NSObject
@property(nonatomic) int tabId;
@property(nonatomic) int rmsSlot;
@property(nonatomic,strong) NSURL *jar;
@property(nonatomic) int virtualWidth;
@property(nonatomic) int virtualHeight;
@property(nonatomic,strong) UIImage *lastImage;
@property(nonatomic,copy) NSString *statusText;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL sleeping;
@end
@implementation GameTab
@end

@interface LibraryController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic,strong) NSArray<NSURL*> *games;
@property(nonatomic,strong) NSMutableDictionary<NSString*,UIImage*> *icons;
@property(nonatomic,strong) NSMutableDictionary<NSString*,NSString*> *subtitles;
@property(nonatomic,copy) void (^onPickJar)(NSURL *jar);
@end

@interface GameController : UIViewController <UITextFieldDelegate>
@property(nonatomic,strong) NSURL *jar;
@property(nonatomic,strong) GameScreen *screen;
@property(nonatomic,strong) UIView *statusRow;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIButton *padToggle;
@property(nonatomic,strong) UIStackView *numpadGrid;
@property(nonatomic,strong) UIStackView *dpadGrid;
@property(nonatomic,strong) NSArray<NSLayoutConstraint*> *portraitPadConstraints;
@property(nonatomic,strong) NSArray<NSLayoutConstraint*> *landscapePadConstraints;
@property(nonatomic,strong) NSArray<NSLayoutConstraint*> *padHiddenConstraints;
@property(nonatomic) BOOL padHidden;
@property(nonatomic,strong) UIView *inputBar;
@property(nonatomic,strong) GameKeyTextField *keyboardField;
@property(nonatomic,copy) NSString *lastSentText;
@property(nonatomic,strong) NSMutableArray<GamePadButton*> *padButtons;
@property(nonatomic,strong) CADisplayLink *displayLink;
@property(nonatomic,strong) UIAlertController *textModal;
@property(nonatomic) NSInteger maxTextLength;
@property(nonatomic,strong) NSMutableArray<GameTab*> *tabs;
@property(nonatomic) int activeTabId;
@property(nonatomic) int nextTabId;
@property(nonatomic) BOOL hostStarted;
@property(nonatomic) BOOL hostFinished;
@property(nonatomic) BOOL closingHost;
@property(nonatomic,strong) UIBarButtonItem *stopItem;
@property(nonatomic,strong) UIBarButtonItem *addTabItem;
@property(nonatomic,strong) UIButton *tabSelector;
@property(nonatomic,strong) NSLayoutConstraint *inputBarBottomConstraint;
@property(nonatomic,strong) UILabel *metricsLabel;
@property(nonatomic,strong) NSTimer *metricsTimer;
@end

@implementation GameController
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=[UIColor colorWithWhite:0.045 alpha:1];
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.hidesBackButton=YES;
    self.tabs=[NSMutableArray new];self.padButtons=[NSMutableArray new];self.lastSentText=@"";
    self.stopItem=[[UIBarButtonItem alloc] initWithTitle:@"Stop" style:UIBarButtonItemStylePlain target:self action:@selector(stop)];
    self.addTabItem=[[UIBarButtonItem alloc] initWithTitle:@"New tab" style:UIBarButtonItemStylePlain target:self action:@selector(newTab)];
    self.navigationItem.leftBarButtonItems=@[self.stopItem,self.addTabItem];
    self.tabSelector=[UIButton buttonWithType:UIButtonTypeSystem];
    if(@available(iOS 14.0,*))self.tabSelector.showsMenuAsPrimaryAction=YES;
    else [self.tabSelector addTarget:self action:@selector(showTabSheet) forControlEvents:UIControlEventTouchUpInside];
    self.tabSelector.tintColor=UIColor.whiteColor;
    self.tabSelector.titleLabel.font=[UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.tabSelector.titleLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;
    [self.tabSelector setTitle:[self.jar.lastPathComponent stringByAppendingString:@" ▾"] forState:UIControlStateNormal];
    [self.tabSelector sizeToFit];
    self.navigationItem.titleView=self.tabSelector;
    self.navigationItem.rightBarButtonItems=@[
        [[UIBarButtonItem alloc] initWithTitle:@"Log" style:UIBarButtonItemStylePlain target:self action:@selector(shareLog)],
        [[UIBarButtonItem alloc] initWithTitle:@"Keyboard" style:UIBarButtonItemStylePlain target:self action:@selector(keyboard)]];
    self.screen=[GameScreen new];self.screen.virtualWidth=480;self.screen.virtualHeight=320;
    self.screen.contentMode=UIViewContentModeScaleAspectFit;self.screen.userInteractionEnabled=YES;self.screen.multipleTouchEnabled=YES;self.screen.layer.magnificationFilter=kCAFilterNearest;
    self.statusRow=[UIView new];
    self.status=[UILabel new];self.status.text=@"Opening game…";self.status.textColor=emSecondaryLabelColor();self.status.font=[UIFont systemFontOfSize:12];self.status.numberOfLines=1;
    self.status.lineBreakMode=NSLineBreakByTruncatingTail;
    [self.status setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    self.metricsLabel=[UILabel new];
    self.metricsLabel.font=[UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
    self.metricsLabel.textColor=emSecondaryLabelColor();
    self.metricsLabel.textAlignment=NSTextAlignmentCenter;
    self.metricsLabel.adjustsFontSizeToFitWidth=YES;
    self.metricsLabel.minimumScaleFactor=0.8;
    self.metricsLabel.numberOfLines=1;
    [self.metricsLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    self.padToggle=[UIButton buttonWithType:UIButtonTypeSystem];[self.padToggle setTitle:@"Hide Pad" forState:UIControlStateNormal];
    self.padToggle.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightMedium];[self.padToggle addTarget:self action:@selector(togglePad) forControlEvents:UIControlEventTouchUpInside];
    [self.padToggle setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    for(UIView*v in @[self.status,self.metricsLabel,self.padToggle]){v.translatesAutoresizingMaskIntoConstraints=NO;[self.statusRow addSubview:v];}
    NSLayoutConstraint *metricsCenterX=[self.metricsLabel.centerXAnchor constraintEqualToAnchor:self.statusRow.centerXAnchor];
    metricsCenterX.priority=UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [self.status.leadingAnchor constraintEqualToAnchor:self.statusRow.leadingAnchor constant:12],
        [self.status.centerYAnchor constraintEqualToAnchor:self.statusRow.centerYAnchor],
        [self.status.trailingAnchor constraintLessThanOrEqualToAnchor:self.metricsLabel.leadingAnchor constant:-6],
        metricsCenterX,
        [self.metricsLabel.centerYAnchor constraintEqualToAnchor:self.statusRow.centerYAnchor],
        [self.metricsLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.status.trailingAnchor constant:6],
        [self.metricsLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.padToggle.leadingAnchor constant:-6],
        [self.padToggle.trailingAnchor constraintEqualToAnchor:self.statusRow.trailingAnchor constant:-12],
        [self.padToggle.centerYAnchor constraintEqualToAnchor:self.statusRow.centerYAnchor],
        [self.padToggle.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.metricsLabel.trailingAnchor constant:6],
        [self.statusRow.heightAnchor constraintEqualToConstant:26]]];
    self.numpadGrid=[self gridWithRows:@[
        @[[self key:@"1" codes:@[@('1')] accent:NO],[self key:@"2" codes:@[@('2')] accent:NO],[self key:@"3" codes:@[@('3')] accent:NO]],
        @[[self key:@"4" codes:@[@('4')] accent:NO],[self key:@"5" codes:@[@('5')] accent:NO],[self key:@"6" codes:@[@('6')] accent:NO]],
        @[[self key:@"7" codes:@[@('7')] accent:NO],[self key:@"8" codes:@[@('8')] accent:NO],[self key:@"9" codes:@[@('9')] accent:NO]],
        @[[self key:@"*" codes:@[@('*')] accent:NO],[self key:@"0" codes:@[@('0')] accent:NO],[self key:@"#" codes:@[@('#')] accent:NO]]]];
    self.dpadGrid=[self gridWithRows:@[
        @[[self key:@"L" codes:@[@(-6)] accent:YES],[UIView new],[self key:@"R" codes:@[@(-7)] accent:YES]],
        @[[self key:@"↖" codes:@[@(-1),@(-3)] accent:NO],[self key:@"↑" codes:@[@(-1)] accent:NO],[self key:@"↗" codes:@[@(-1),@(-4)] accent:NO]],
        @[[self key:@"←" codes:@[@(-3)] accent:NO],[self key:@"F" codes:@[@(-5)] accent:YES],[self key:@"→" codes:@[@(-4)] accent:NO]],
        @[[self key:@"↙" codes:@[@(-2),@(-3)] accent:NO],[self key:@"↓" codes:@[@(-2)] accent:NO],[self key:@"↘" codes:@[@(-2),@(-4)] accent:NO]]]];
    [self setupKeyboardBar];
    for(UIView*v in @[self.screen,self.statusRow,self.numpadGrid,self.dpadGrid,self.inputBar]){v.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:v];}
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    self.portraitPadConstraints=@[
        [self.screen.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],
        [self.screen.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.screen.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.screen.bottomAnchor constraintEqualToAnchor:self.statusRow.topAnchor constant:-4],
        [self.statusRow.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.statusRow.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.statusRow.bottomAnchor constraintEqualToAnchor:self.numpadGrid.topAnchor constant:-6],
        [self.numpadGrid.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [self.numpadGrid.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [self.numpadGrid.heightAnchor constraintEqualToConstant:212],
        [self.dpadGrid.leadingAnchor constraintEqualToAnchor:self.numpadGrid.trailingAnchor constant:4],
        [self.dpadGrid.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [self.dpadGrid.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
        [self.dpadGrid.heightAnchor constraintEqualToConstant:212],
        [self.dpadGrid.widthAnchor constraintEqualToAnchor:self.numpadGrid.widthAnchor]];
    self.landscapePadConstraints=@[
        [self.numpadGrid.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [self.numpadGrid.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor constant:-10],
        [self.numpadGrid.widthAnchor constraintEqualToConstant:156],
        [self.numpadGrid.heightAnchor constraintEqualToConstant:196],
        [self.dpadGrid.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [self.dpadGrid.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor constant:-10],
        [self.dpadGrid.widthAnchor constraintEqualToConstant:156],
        [self.dpadGrid.heightAnchor constraintEqualToConstant:196],
        [self.screen.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],
        [self.screen.leadingAnchor constraintEqualToAnchor:self.numpadGrid.trailingAnchor constant:8],
        [self.screen.trailingAnchor constraintEqualToAnchor:self.dpadGrid.leadingAnchor constant:-8],
        [self.screen.bottomAnchor constraintEqualToAnchor:self.statusRow.topAnchor constant:-4],
        [self.statusRow.leadingAnchor constraintEqualToAnchor:self.numpadGrid.trailingAnchor constant:8],
        [self.statusRow.trailingAnchor constraintEqualToAnchor:self.dpadGrid.leadingAnchor constant:-8],
        [self.statusRow.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4]];
    self.padHiddenConstraints=@[
        [self.screen.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],
        [self.screen.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.screen.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.screen.bottomAnchor constraintEqualToAnchor:self.statusRow.topAnchor constant:-4],
        [self.statusRow.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.statusRow.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.statusRow.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4]];
    if(@available(iOS 15.0,*)){
        self.inputBarBottomConstraint=[self.inputBar.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor];
    } else {
        self.inputBarBottomConstraint=[self.inputBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
    }
    [NSLayoutConstraint activateConstraints:@[
        [self.inputBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.inputBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.inputBar.heightAnchor constraintEqualToConstant:48],
        self.inputBarBottomConstraint]];
    [self updatePadLayout];
    NSNotificationCenter *nc=[NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(statusChanged:) name:EmStatusNotification object:nil];
    [nc addObserver:self selector:@selector(modalChanged:) name:EmModalNotification object:nil];
    [nc addObserver:self selector:@selector(tabFinished:) name:EmTabFinishedNotification object:nil];
    if(@available(iOS 15.0,*)){}else [nc addObserver:self selector:@selector(keyboardWillChangeFrame:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [nc addObserver:self selector:@selector(appDidEnterBackground) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [nc addObserver:self selector:@selector(appWillEnterForeground) name:UIApplicationWillEnterForegroundNotification object:nil];
    self.displayLink=[CADisplayLink displayLinkWithTarget:self selector:@selector(frame)];self.displayLink.preferredFramesPerSecond=30;[self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.navigationController.interactivePopGestureRecognizer.enabled=NO;[UIApplication sharedApplication].idleTimerDisabled=YES;
    __weak GameController *weakSelf=self;
    self.metricsTimer=[NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer*t){
        [weakSelf updateMetrics];
    }];
    [self updateMetrics];
    EmClearAllFrames();em_reset_events();runtimeActive=YES;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self startRuntimeIfReady];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updatePadLayout];
    [self startRuntimeIfReady];
}
- (GameTab*)tabWithId:(int)tabId {
    for(GameTab *tab in self.tabs)if(tab.tabId==tabId)return tab;
    return nil;
}
- (GameTab*)activeTab {
    return [self tabWithId:self.activeTabId];
}
- (int)nextFreeRmsSlot {
    for(int slot=1;;slot++){
        BOOL used=NO;
        for(GameTab *tab in self.tabs)if(tab.rmsSlot==slot){used=YES;break;}
        if(!used)return slot;
    }
}
- (void)updateMetrics {
    uint64_t appMem=emAppResidentMemory();
    uint64_t totalMem=[NSProcessInfo processInfo].physicalMemory;
    float cpu=emCurrentCpuUsage();
    double appMB=(double)appMem/(1024.0*1024.0);
    double totalGB=(double)totalMem/(1024.0*1024.0*1024.0);
    double ratio=totalMem>0?((double)appMem/(double)totalMem):0.0;
    if(totalGB>0){
        if(cpu>=0){
            self.metricsLabel.text=[NSString stringWithFormat:@"RAM: %.0fMB/%.1fGB · CPU: %.0f%%",appMB,totalGB,cpu];
        }else{
            self.metricsLabel.text=[NSString stringWithFormat:@"RAM: %.0fMB/%.1fGB",appMB,totalGB];
        }
    }else{
        self.metricsLabel.text=[NSString stringWithFormat:@"RAM: %.0fMB",appMB];
    }
    BOOL isLowRam=(totalMem>0 && totalMem<=1536ULL*1024ULL*1024ULL);
    if((isLowRam && appMB>=320.0) || ratio>=0.40){
        self.metricsLabel.textColor=[UIColor colorWithRed:1.0 green:0.35 blue:0.35 alpha:1];
    }else if((isLowRam && appMB>=200.0) || ratio>=0.25){
        self.metricsLabel.textColor=[UIColor colorWithRed:1.0 green:0.80 blue:0.0 alpha:1];
    }else{
        self.metricsLabel.textColor=emSecondaryLabelColor();
    }
}
- (void)updateTabSelector {
    GameTab *active=[self activeTab];
    NSString *title=active?[NSString stringWithFormat:@"%d · %@ ▾",active.tabId,active.jar.lastPathComponent]:[self.jar.lastPathComponent stringByAppendingString:@" ▾"];
    [self.tabSelector setTitle:title forState:UIControlStateNormal];
    [self.tabSelector sizeToFit];
    if(@available(iOS 14.0,*)){
        NSMutableArray<UIAction*> *actions=[NSMutableArray new];
        __weak GameController *weakSelf=self;
        for(GameTab *tab in self.tabs){
            NSString *suffix=tab.finished?@" · Stopped":@"";
            NSString *label=[NSString stringWithFormat:@"Tab %d · %@%@",tab.tabId,tab.jar.lastPathComponent,suffix];
            int targetId=tab.tabId;
            UIAction *action=[UIAction actionWithTitle:label image:nil identifier:nil handler:^(UIAction*a){
                [weakSelf switchToTab:targetId];
            }];
            action.state=tab.tabId==self.activeTabId?UIMenuElementStateOn:UIMenuElementStateOff;
            [actions addObject:action];
        }
        if(@available(iOS 15.0,*)){
            self.tabSelector.menu=[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsSingleSelection children:actions];
        }else{
            self.tabSelector.menu=[UIMenu menuWithTitle:@"" children:actions];
        }
    }
}
- (void)showTabSheet {
    if(self.closingHost || self.presentedViewController || !self.tabs.count)return;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak GameController *weakSelf=self;
    for(GameTab *tab in self.tabs){
        NSString *prefix=tab.tabId==self.activeTabId?@"✓ ":@"";
        NSString *suffix=tab.finished?@" · Stopped":@"";
        NSString *label=[NSString stringWithFormat:@"%@Tab %d · %@%@",prefix,tab.tabId,tab.jar.lastPathComponent,suffix];
        int targetId=tab.tabId;
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction*a){
            [weakSelf switchToTab:targetId];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=self.tabSelector;
    sheet.popoverPresentationController.sourceRect=self.tabSelector.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)startRuntimeIfReady {
    if(self.hostStarted || self.closingHost || !self.view.window)return;
    [self.view layoutIfNeeded];
    CGSize bounds=self.screen.bounds.size;
    if(bounds.width<=0 || bounds.height<=0)return;
    self.hostStarted=YES;
    NSString *bootstrap=[[NSBundle mainBundle] pathForResource:@"minijvm_rt" ofType:@"jar" inDirectory:@"Runtime"];
    NSString *emulator=[[NSBundle mainBundle] pathForResource:@"microemu-ios" ofType:@"jar" inDirectory:@"Runtime"];
    NSURL *documents=[gamesDirectory() URLByDeletingLastPathComponent];
    NSString *log=[[documents URLByAppendingPathComponent:@"microemu.log"] path];
    __weak GameController *weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            freopen(log.fileSystemRepresentation,"w",stdout);freopen(log.fileSystemRepresentation,"a",stderr);setvbuf(stdout,NULL,_IOLBF,0);
            int result=bootstrap && emulator?em_host_run(bootstrap.fileSystemRepresentation,emulator.fileSystemRepresentation):-1;
            dispatch_async(dispatch_get_main_queue(), ^{
                GameController *owner=weakSelf;
                runtimeActive=NO;
                if(!owner)return;
                owner.hostFinished=YES;
                [UIApplication sharedApplication].idleTimerDisabled=NO;
                if(owner.closingHost){[owner close];return;}
                for(GameTab *tab in owner.tabs){
                    tab.finished=YES;
                    tab.statusText=result==0?@"Game stopped":@"Game error — see Log";
                }
                GameTab *active=[owner activeTab];
                if(active){
                    owner.status.text=active.statusText;
                    owner.stopItem.title=owner.tabs.count>1?@"Close":@"Back";
                }
                [owner updateTabSelector];
            });
        }
    });
    [self openNewTabWithJar:self.jar];
}
- (void)cancelActiveInputs {
    [self hideKeyboard];
    [self.screen cancelPointer];
    for(GamePadButton *button in self.padButtons){
        [button.repeatTimer invalidate];button.repeatTimer=nil;
        button.backgroundColor=button.idleColor;
        if(button.active){
            button.active=NO;
            for(NSNumber *code in button.keyCodes)em_tab_event(button.pressedTabId,2,code.intValue,0,0,NULL);
        }
    }
    if(self.textModal){[self.textModal dismissViewControllerAnimated:NO completion:nil];self.textModal=nil;}
}
- (void)openNewTabWithJar:(NSURL*)jarURL {
    if(!jarURL || self.closingHost || self.hostFinished)return;
    [self cancelActiveInputs];
    GameTab *previous=[self activeTab];
    if(previous){
        previous.lastImage=self.screen.image;
        previous.sleeping=YES;
        if(!previous.finished)em_host_sleep_tab(previous.tabId,1);
    }
    [self.view layoutIfNeeded];
    int width=480,height=320;
    EmComputeVirtualSize(self.screen.bounds.size,&width,&height);
    GameTab *tab=[GameTab new];
    tab.tabId=++self.nextTabId;
    tab.rmsSlot=[self nextFreeRmsSlot];
    tab.jar=jarURL;
    tab.virtualWidth=width;
    tab.virtualHeight=height;
    tab.statusText=@"Opening game…";
    tab.started=YES;
    [self.tabs addObject:tab];
    self.activeTabId=tab.tabId;
    self.screen.tabId=tab.tabId;
    self.screen.virtualWidth=width;
    self.screen.virtualHeight=height;
    self.screen.image=nil;
    self.status.text=tab.statusText;
    self.stopItem.title=@"Stop";
    EmClearFrame(tab.tabId);
    NSString *rms=rmsPathForSlot(tab.rmsSlot);
    em_host_open_tab(tab.tabId,jarURL.path.fileSystemRepresentation,rms.fileSystemRepresentation,width,height);
    [self updateTabSelector];
}
- (void)switchToTab:(int)targetTabId {
    if(targetTabId==self.activeTabId)return;
    GameTab *next=[self tabWithId:targetTabId];
    if(!next)return;
    [self cancelActiveInputs];
    GameTab *previous=[self activeTab];
    if(previous){
        previous.lastImage=self.screen.image;
        previous.sleeping=YES;
        if(!previous.finished)em_host_sleep_tab(previous.tabId,1);
    }
    self.activeTabId=next.tabId;
    self.screen.tabId=next.tabId;
    self.screen.virtualWidth=next.virtualWidth;
    self.screen.virtualHeight=next.virtualHeight;
    self.screen.image=next.lastImage;
    self.status.text=next.statusText?:@"";
    self.stopItem.title=next.finished?(self.tabs.count>1?@"Close":@"Back"):@"Stop";
    next.sleeping=NO;
    if(!next.finished)em_host_sleep_tab(next.tabId,0);
    [self updateTabSelector];
}
- (void)presentJarListPicker {
    if(self.closingHost || self.hostFinished || self.presentedViewController)return;
    LibraryController *picker=[[LibraryController alloc] initWithStyle:emTableStyle()];
    __weak GameController *weakSelf=self;
    picker.onPickJar=^(NSURL *jar){
        [weakSelf openNewTabWithJar:jar];
    };
    UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:picker];
    if(@available(iOS 13.0,*)){}else{nav.navigationBar.barStyle=UIBarStyleBlack;nav.navigationBar.tintColor=UIColor.systemBlueColor;}
    [self presentViewController:nav animated:YES completion:nil];
}
- (void)newTab {
    if(self.closingHost || self.hostFinished || self.presentedViewController)return;
    NSURL *currentJar=[self activeTab].jar?:self.jar;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"New tab" message:@"Choose a game to open in a new tab" preferredStyle:UIAlertControllerStyleActionSheet];
    __weak GameController *weakSelf=self;
    if(currentJar){
        [sheet addAction:[UIAlertAction actionWithTitle:currentJar.lastPathComponent style:UIAlertActionStyleDefault handler:^(UIAlertAction*a){
            [weakSelf openNewTabWithJar:currentJar];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Choose from list" style:UIAlertActionStyleDefault handler:^(UIAlertAction*a){
        [weakSelf presentJarListPicker];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.barButtonItem=self.addTabItem;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)updatePadLayout {
    BOOL landscape=self.view.bounds.size.width>self.view.bounds.size.height;
    self.numpadGrid.hidden=self.padHidden;self.dpadGrid.hidden=self.padHidden;
    NSArray<NSLayoutConstraint*> *target=self.padHidden?self.padHiddenConstraints:(landscape?self.landscapePadConstraints:self.portraitPadConstraints);
    if(target.firstObject.active)return;
    [NSLayoutConstraint deactivateConstraints:self.portraitPadConstraints];
    [NSLayoutConstraint deactivateConstraints:self.landscapePadConstraints];
    [NSLayoutConstraint deactivateConstraints:self.padHiddenConstraints];
    [NSLayoutConstraint activateConstraints:target];
}
- (void)togglePad {
    self.padHidden=!self.padHidden;
    [self.padToggle setTitle:self.padHidden?@"Show Pad":@"Hide Pad" forState:UIControlStateNormal];
    [self updatePadLayout];
}
- (UIStackView*)gridWithRows:(NSArray<NSArray<UIView*>*>*)rows {
    NSMutableArray *rowViews=[NSMutableArray new];
    for(NSArray<UIView*> *cols in rows){
        UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:cols];
        row.axis=UILayoutConstraintAxisHorizontal;row.spacing=4;row.distribution=UIStackViewDistributionFillEqually;
        [rowViews addObject:row];
    }
    UIStackView *grid=[[UIStackView alloc] initWithArrangedSubviews:rowViews];
    grid.axis=UILayoutConstraintAxisVertical;grid.spacing=4;grid.distribution=UIStackViewDistributionFillEqually;
    return grid;
}
- (GamePadButton*)key:(NSString*)title codes:(NSArray<NSNumber*>*)codes accent:(BOOL)accent {
    GamePadButton *button=[GamePadButton buttonWithType:UIButtonTypeSystem];[button setTitle:title forState:UIControlStateNormal];
    button.keyCodes=codes;button.idleColor=[UIColor colorWithWhite:accent?0.23:0.15 alpha:0.95];
    button.backgroundColor=button.idleColor;button.tintColor=UIColor.whiteColor;button.layer.cornerRadius=10;
    button.titleLabel.font=[UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [button addTarget:self action:@selector(keyDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(keyUp:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel|UIControlEventTouchDragExit];
    [self.padButtons addObject:button];
    return button;
}
- (void)keyDown:(GamePadButton*)button {
    GameTab *tab=[self activeTab];
    if(!tab || tab.finished || tab.stopping)return;
    button.active=YES;button.pressedTabId=tab.tabId;
    button.backgroundColor=[UIColor colorWithWhite:0.35 alpha:1];
    [button.repeatTimer invalidate];
    for(NSNumber *code in button.keyCodes)em_tab_event(tab.tabId,1,code.intValue,0,0,NULL);
    __block int ticks=0;__weak GamePadButton *weakButton=button;__weak GameController *weakSelf=self;
    button.repeatTimer=[NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES block:^(NSTimer*t){
        GamePadButton *b=weakButton;GameController *s=weakSelf;
        if(!b || !s || !b.active || s.activeTabId!=b.pressedTabId)return;
        if(++ticks>=4)for(NSNumber *code in b.keyCodes)em_tab_event(b.pressedTabId,3,code.intValue,0,0,NULL);
    }];
}
- (void)keyUp:(GamePadButton*)button {
    button.backgroundColor=button.idleColor;
    [button.repeatTimer invalidate];button.repeatTimer=nil;
    if(!button.active)return;
    button.active=NO;
    GameTab *tab=[self tabWithId:button.pressedTabId];
    if(tab && !tab.finished)for(NSNumber *code in button.keyCodes)em_tab_event(button.pressedTabId,2,code.intValue,0,0,NULL);
}
- (void)setupKeyboardBar {
    self.inputBar=[UIView new];self.inputBar.backgroundColor=[UIColor colorWithWhite:0.1 alpha:0.98];self.inputBar.hidden=YES;
    UIView *line=[UIView new];line.backgroundColor=[UIColor colorWithWhite:0.25 alpha:1];line.translatesAutoresizingMaskIntoConstraints=NO;
    self.keyboardField=[GameKeyTextField new];self.keyboardField.delegate=self;
    self.keyboardField.backgroundColor=[UIColor colorWithWhite:0.18 alpha:1];self.keyboardField.textColor=UIColor.whiteColor;
    self.keyboardField.font=[UIFont systemFontOfSize:15];self.keyboardField.layer.cornerRadius=8;
    self.keyboardField.leftView=[[UIView alloc] initWithFrame:CGRectMake(0,0,10,1)];self.keyboardField.leftViewMode=UITextFieldViewModeAlways;
    self.keyboardField.attributedPlaceholder=[[NSAttributedString alloc] initWithString:@"Type text for game…" attributes:@{NSForegroundColorAttributeName:emSecondaryLabelColor()}];
    self.keyboardField.autocorrectionType=UITextAutocorrectionTypeNo;self.keyboardField.autocapitalizationType=UITextAutocapitalizationTypeNone;
    self.keyboardField.spellCheckingType=UITextSpellCheckingTypeNo;self.keyboardField.returnKeyType=UIReturnKeySend;
    [self.keyboardField addTarget:self action:@selector(keyboardTextChanged) forControlEvents:UIControlEventEditingChanged];
    __weak GameController *weakSelf=self;
    self.keyboardField.onEmptyBackspace=^{
        GameController *s=weakSelf;GameTab *t=[s activeTab];
        if(!t || t.finished || t.stopping)return;
        em_tab_event(t.tabId,13,-8,0,0,NULL);
    };
    UIButton *leftKey=[UIButton buttonWithType:UIButtonTypeSystem];[leftKey setTitle:@"L" forState:UIControlStateNormal];
    leftKey.titleLabel.font=[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];leftKey.backgroundColor=[UIColor colorWithWhite:0.24 alpha:1];leftKey.tintColor=UIColor.whiteColor;leftKey.layer.cornerRadius=8;
    [leftKey addTarget:self action:@selector(keyboardSendLeft) forControlEvents:UIControlEventTouchUpInside];
    UIButton *send=[UIButton buttonWithType:UIButtonTypeSystem];[send setTitle:@"↵" forState:UIControlStateNormal];
    send.titleLabel.font=[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];send.backgroundColor=UIColor.systemBlueColor;send.tintColor=UIColor.whiteColor;send.layer.cornerRadius=8;
    [send addTarget:self action:@selector(keyboardSendReturn) forControlEvents:UIControlEventTouchUpInside];
    UIButton *done=[UIButton buttonWithType:UIButtonTypeSystem];[done setTitle:@"Done" forState:UIControlStateNormal];
    done.titleLabel.font=[UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];done.backgroundColor=[UIColor colorWithWhite:0.24 alpha:1];done.tintColor=UIColor.whiteColor;done.layer.cornerRadius=8;
    [done addTarget:self action:@selector(hideKeyboard) forControlEvents:UIControlEventTouchUpInside];
    [self.inputBar addSubview:line];
    for(UIView *v in @[self.keyboardField,leftKey,send,done]){v.translatesAutoresizingMaskIntoConstraints=NO;[self.inputBar addSubview:v];}
    [NSLayoutConstraint activateConstraints:@[
        [line.topAnchor constraintEqualToAnchor:self.inputBar.topAnchor],[line.leadingAnchor constraintEqualToAnchor:self.inputBar.leadingAnchor],[line.trailingAnchor constraintEqualToAnchor:self.inputBar.trailingAnchor],[line.heightAnchor constraintEqualToConstant:0.5],
        [self.keyboardField.leadingAnchor constraintEqualToAnchor:self.inputBar.leadingAnchor constant:8],[self.keyboardField.centerYAnchor constraintEqualToAnchor:self.inputBar.centerYAnchor],[self.keyboardField.heightAnchor constraintEqualToConstant:34],
        [leftKey.leadingAnchor constraintEqualToAnchor:self.keyboardField.trailingAnchor constant:6],[leftKey.centerYAnchor constraintEqualToAnchor:self.inputBar.centerYAnchor],[leftKey.widthAnchor constraintEqualToConstant:36],[leftKey.heightAnchor constraintEqualToConstant:34],
        [send.leadingAnchor constraintEqualToAnchor:leftKey.trailingAnchor constant:6],[send.centerYAnchor constraintEqualToAnchor:self.inputBar.centerYAnchor],[send.widthAnchor constraintEqualToConstant:40],[send.heightAnchor constraintEqualToConstant:34],
        [done.leadingAnchor constraintEqualToAnchor:send.trailingAnchor constant:6],[done.trailingAnchor constraintEqualToAnchor:self.inputBar.trailingAnchor constant:-8],[done.centerYAnchor constraintEqualToAnchor:self.inputBar.centerYAnchor],[done.widthAnchor constraintEqualToConstant:52],[done.heightAnchor constraintEqualToConstant:34]]];
}
- (void)keyboardTextChanged {
    GameTab *tab=[self activeTab];
    if(!tab || tab.finished || tab.stopping)return;
    NSString *current=self.keyboardField.text?:@"";
    NSString *previous=self.lastSentText?:@"";
    if([current isEqualToString:previous])return;
    NSUInteger common=0,limit=MIN(previous.length,current.length);
    while(common<limit && [previous characterAtIndex:common]==[current characterAtIndex:common])common++;
    NSUInteger deletes=previous.length-common;
    for(NSUInteger i=0;i<deletes;i++)em_tab_event(tab.tabId,13,-8,0,0,NULL);
    NSString *added=[current substringFromIndex:common];
    if(added.length>0)em_tab_event(tab.tabId,12,0,0,0,added.UTF8String);
    self.lastSentText=[current copy];
}
- (void)keyboardSendLeft {
    GameTab *tab=[self activeTab];
    if(!tab || tab.finished || tab.stopping)return;
    [self.keyboardField unmarkText];
    [self keyboardTextChanged];
    em_tab_event(tab.tabId,13,-6,0,0,NULL);
    self.keyboardField.text=@"";self.lastSentText=@"";
}
- (void)keyboardSendReturn {
    GameTab *tab=[self activeTab];
    if(!tab || tab.finished || tab.stopping)return;
    [self.keyboardField unmarkText];
    [self keyboardTextChanged];
    em_tab_event(tab.tabId,13,-5,0,0,NULL);
    self.keyboardField.text=@"";self.lastSentText=@"";
}
- (void)hideKeyboard {
    if(self.keyboardField.isFirstResponder){
        [self.keyboardField unmarkText];
        [self keyboardTextChanged];
        [self.keyboardField resignFirstResponder];
    }
    self.keyboardField.text=@"";self.lastSentText=@"";self.inputBar.hidden=YES;
}
- (void)keyboardWillChangeFrame:(NSNotification*)notification {
    CGRect endFrame=[notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local=[self.view convertRect:endFrame fromView:nil];
    CGFloat overlap=MAX(0,CGRectGetMaxY(self.view.bounds)-local.origin.y);
    self.inputBarBottomConstraint.constant=-overlap;
    NSTimeInterval duration=[notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{ [self.view layoutIfNeeded]; }];
}
- (void)keyboardWillHide:(NSNotification*)notification {
    self.keyboardField.text=@"";self.lastSentText=@"";self.inputBar.hidden=YES;
    if(@available(iOS 15.0,*)){}else{self.inputBarBottomConstraint.constant=0;[self.view layoutIfNeeded];}
}
- (void)frame {
    if(!self.activeTabId)return;
    int width,height;NSData *data=EmConsumeFrame(self.activeTabId,&width,&height);if(!data)return;
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef image=CGImageCreate(width,height,8,32,width*4,color,kCGBitmapByteOrder32Little|kCGImageAlphaFirst,provider,NULL,NO,kCGRenderingIntentDefault);
    if(image){
        UIImage *uiImage=[UIImage imageWithCGImage:image];
        self.screen.image=uiImage;
        GameTab *active=[self activeTab];
        if(active)active.lastImage=uiImage;
        CGImageRelease(image);
    }
    CGDataProviderRelease(provider);CGColorSpaceRelease(color);
}
- (void)statusChanged:(NSNotification*)notification {
    NSDictionary *info=notification.object;
    int tabId=[info[@"tabId"] intValue];
    NSString *text=info[@"text"]?:@"";
    GameTab *tab=[self tabWithId:tabId];
    if(tab)tab.statusText=text;
    if(tabId==self.activeTabId)self.status.text=text;
}
- (void)modalChanged:(NSNotification*)notification {
    NSDictionary *info=notification.object;
    int tabId=[info[@"tabId"] intValue];
    if(tabId!=self.activeTabId)return;
    GameTab *tab=[self tabWithId:tabId];
    if(info[@"title"]==NSNull.null){[self.textModal dismissViewControllerAnimated:NO completion:nil];self.textModal=nil;return;}
    if(!tab || tab.finished || tab.stopping)return;
    [self hideKeyboard];
    NSString *title=[info[@"title"] length]?info[@"title"]:nil;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:[info[@"max"] intValue]>0?nil:info[@"value"] preferredStyle:UIAlertControllerStyleAlert];
    self.maxTextLength=[info[@"max"] integerValue];int constraints=[info[@"constraints"] intValue];
    if(self.maxTextLength>0)[alert addTextFieldWithConfigurationHandler:^(UITextField*field){field.text=info[@"value"];field.delegate=self;field.secureTextEntry=(constraints&0x10000)!=0;
        int type=constraints&0xffff;field.keyboardType=type==2?UIKeyboardTypeNumberPad:type==3?UIKeyboardTypePhonePad:type==5?UIKeyboardTypeDecimalPad:type==1?UIKeyboardTypeEmailAddress:UIKeyboardTypeDefault;
        field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;}];
    NSArray *commands=info[@"commands"];if(!commands.count)commands=@[@"Done"];
    __weak UIAlertController *weakAlert=alert;__weak GameController *weakSelf=self;
    for(NSUInteger i=0;i<commands.count;i++){
        [alert addAction:[UIAlertAction actionWithTitle:commands[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction*a){
            NSString *value=weakAlert.textFields.firstObject.text?:@"";
            em_tab_event(tabId,7,(int)i,0,0,value.UTF8String);
            if(weakSelf)weakSelf.textModal=nil;
        }]];
    }
    UIViewController *previous=self.textModal?:self.presentedViewController;
    self.textModal=alert;
    void (^presentAlert)(void)=^{
        GameTab *current=[weakSelf activeTab];
        if(current && current.tabId==tabId && !current.finished && !current.stopping && weakSelf.textModal==alert)
            [weakSelf presentViewController:alert animated:YES completion:nil];
    };
    if(previous)[previous dismissViewControllerAnimated:NO completion:presentAlert];
    else presentAlert();
}
- (void)tabFinished:(NSNotification*)notification {
    NSDictionary *info=notification.object;
    int tabId=[info[@"tabId"] intValue];
    int result=[info[@"result"] intValue];
    GameTab *tab=[self tabWithId:tabId];
    if(!tab)return;
    tab.finished=YES;
    EmClearFrame(tabId);
    if(tab.stopping){[self removeTab:tab];return;}
    tab.statusText=result==0?@"Game stopped":@"Game error — see Log";
    if(tabId==self.activeTabId){
        self.status.text=tab.statusText;
        self.stopItem.title=self.tabs.count>1?@"Close":@"Back";
    }
    [self updateTabSelector];
}
- (void)removeTab:(GameTab*)tab {
    BOOL wasActive=(tab.tabId==self.activeTabId);
    [self.tabs removeObject:tab];
    EmClearFrame(tab.tabId);
    em_tab_reset_events(tab.tabId);
    if(!self.tabs.count){
        if(!self.hostStarted || self.hostFinished){runtimeActive=NO;[self close];return;}
        self.closingHost=YES;
        self.activeTabId=0;self.screen.tabId=0;
        em_host_shutdown();
        return;
    }
    if(wasActive){
        self.activeTabId=0;
        [self switchToTab:self.tabs.firstObject.tabId];
    } else {
        [self updateTabSelector];
    }
}
- (BOOL)textField:(UITextField*)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString*)replacement {
    if(field==self.keyboardField)return YES;
    return (NSInteger)field.text.length-(NSInteger)range.length+(NSInteger)replacement.length<=self.maxTextLength;
}
- (BOOL)textFieldShouldReturn:(UITextField*)field {
    if(field==self.keyboardField){[self keyboardSendReturn];return NO;}
    return YES;
}
- (void)shareLog {
    NSURL *log=[[gamesDirectory() URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"microemu.log"];
    if(![[NSFileManager defaultManager] fileExistsAtPath:log.path])return;
    UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[log] applicationActivities:nil];share.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItems.firstObject;[self presentViewController:share animated:YES completion:nil];
}
- (void)keyboard {
    GameTab *tab=[self activeTab];
    if(!tab || tab.finished || tab.stopping || self.presentedViewController)return;
    if(self.keyboardField.isFirstResponder){[self hideKeyboard];return;}
    self.keyboardField.text=@"";self.lastSentText=@"";
    self.inputBar.hidden=NO;[self.view bringSubviewToFront:self.inputBar];
    [self.keyboardField becomeFirstResponder];
}
- (void)appDidEnterBackground {
    for(GameTab *tab in self.tabs)if(!tab.finished)em_tab_event(tab.tabId,8,0,0,0,NULL);
}
- (void)appWillEnterForeground {
    for(GameTab *tab in self.tabs)if(!tab.finished)em_tab_event(tab.tabId,9,0,0,0,NULL);
    [self updateMetrics];
}
- (void)stop {
    GameTab *tab=[self activeTab];
    if(!tab){
        if(!self.hostStarted || self.hostFinished){runtimeActive=NO;[self close];}
        return;
    }
    if(tab.finished || self.hostFinished){[self removeTab:tab];return;}
    if(tab.stopping)return;
    tab.stopping=YES;tab.statusText=@"Stopping game…";self.status.text=tab.statusText;
    [self cancelActiveInputs];
    em_host_close_tab(tab.tabId);
}
- (void)close {
    [self.metricsTimer invalidate];self.metricsTimer=nil;
    [self.displayLink invalidate];self.displayLink=nil;
    [UIApplication sharedApplication].idleTimerDisabled=NO;
    self.navigationController.interactivePopGestureRecognizer.enabled=YES;
    [self.navigationController popViewControllerAnimated:YES];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.metricsTimer invalidate];
    [self.displayLink invalidate];
    for(GamePadButton *button in self.padButtons)[button.repeatTimer invalidate];
}
@end

@implementation LibraryController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.icons=[NSMutableDictionary new];self.subtitles=[NSMutableDictionary new];
    self.title=self.onPickJar?@"Choose JAR":@"GaEmulator";
    self.navigationItem.largeTitleDisplayMode=self.onPickJar?UINavigationItemLargeTitleDisplayModeNever:UINavigationItemLargeTitleDisplayModeAlways;
    if(self.onPickJar){
        self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Cancel" style:UIBarButtonItemStylePlain target:self action:@selector(cancelPicker)];
    }else{
        self.navigationItem.leftBarButtonItem=self.editButtonItem;
    }
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Import JAR" style:UIBarButtonItemStylePlain target:self action:@selector(importJar)];
    self.tableView.backgroundColor=emGroupedBgColor();
    self.tableView.rowHeight=58;
    if(@available(iOS 13.0,*)){}else{self.tableView.separatorColor=[UIColor colorWithWhite:0.22 alpha:1];}
}
- (void)cancelPicker {[self dismissViewControllerAnimated:YES completion:nil];}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];self.games=listGameJars();[self.tableView reloadData];}
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {return self.games.count;}
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)index {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSURL *jar=self.games[index.row];
    NSString *key=jar.path?:jar.lastPathComponent;
    UIImage *icon=self.icons[key];
    NSString *suite=self.subtitles[key];
    if(!icon){
        icon=emIconFromJar(jar,&suite);
        if(icon)self.icons[key]=icon;
        if(suite)self.subtitles[key]=suite;
    }
    cell.textLabel.text=jar.lastPathComponent;
    cell.detailTextLabel.text=self.onPickJar?@"Open in new tab":(suite.length?[NSString stringWithFormat:@"%@ · Java ME",suite]:@"Java ME · Full Screen");
    cell.imageView.image=icon;
    cell.imageView.contentMode=UIViewContentModeScaleAspectFit;
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    if(@available(iOS 13.0,*)){}else{
        cell.backgroundColor=[UIColor colorWithWhite:0.13 alpha:1];
        cell.textLabel.textColor=UIColor.whiteColor;
        cell.detailTextLabel.textColor=emSecondaryLabelColor();
    }
    return cell;
}
- (BOOL)tableView:(UITableView*)tableView canEditRowAtIndexPath:(NSIndexPath*)indexPath {return !self.onPickJar;}
- (void)tableView:(UITableView*)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath*)indexPath {
    if(editingStyle!=UITableViewCellEditingStyleDelete || self.onPickJar || indexPath.row>=(NSInteger)self.games.count)return;
    NSURL *target=self.games[indexPath.row];
    NSString *deletedSuiteKey=emSuiteKeyForJar(target);
    NSError *error=nil;
    if(![[NSFileManager defaultManager] removeItemAtURL:target error:&error]){
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Delete failed" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSString *key=target.path?:target.lastPathComponent;
    [self.icons removeObjectForKey:key];
    [self.subtitles removeObjectForKey:key];
    self.games=listGameJars();
    emRemoveGameData(deletedSuiteKey,self.games);
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:0] withRowAnimation:UITableViewRowAnimationNone];
}
- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
    if(self.onPickJar)return self.games.count?@"Tap a game to open it in a new tab.":@"No JAR files yet. Tap Import JAR to add one.";
    return self.games.count?@"Tap a game to run it. Swipe left or tap Edit to remove a JAR.":@"Import a MIDP JAR from Files to get started. Games run locally on your iPhone.";
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)index {
    if(self.onPickJar){
        NSURL *selected=self.games[index.row];
        void (^handler)(NSURL*)=self.onPickJar;
        [self dismissViewControllerAnimated:YES completion:^{if(handler)handler(selected);}];
        return;
    }
    if(runtimeActive)return;GameController *game=[GameController new];game.jar=self.games[index.row];[self.navigationController pushViewController:game animated:YES];
}
- (void)importJar {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[@"com.gamod.microemu.jar",@"public.archive",@"public.data"] inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.delegate=self;
    if(@available(iOS 11.0,*))picker.allowsMultipleSelection=YES;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    for(NSURL *url in urls){if(![url.pathExtension.lowercaseString isEqualToString:@"jar"])continue;BOOL scoped=[url startAccessingSecurityScopedResource];
        NSURL *target=[gamesDirectory() URLByAppendingPathComponent:url.lastPathComponent];if([[NSFileManager defaultManager] fileExistsAtPath:target.path])target=[gamesDirectory() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.jar",url.lastPathComponent.stringByDeletingPathExtension,NSUUID.UUID.UUIDString]];
        NSError *error=nil;[[NSFileManager defaultManager] copyItemAtURL:url toURL:target error:&error];if(scoped)[url stopAccessingSecurityScopedResource];
        NSString *key=target.path?:target.lastPathComponent;[self.icons removeObjectForKey:key];[self.subtitles removeObjectForKey:key];
        if(error){UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Import failed" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:alert animated:YES completion:nil];}
    }
    [self viewWillAppear:NO];
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
    em_configure_memory_bytes([NSProcessInfo processInfo].physicalMemory);
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:[[LibraryController alloc] initWithStyle:emTableStyle()]];
    navigation.navigationBar.prefersLargeTitles=YES;
    if(@available(iOS 13.0,*)){self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;}
    else{navigation.navigationBar.barStyle=UIBarStyleBlack;navigation.navigationBar.tintColor=UIColor.systemBlueColor;}
    self.window.rootViewController=navigation;[self.window makeKeyAndVisible];return YES;
}
@end
#if !defined(DEBUG) && defined(__APPLE__)
#import <dlfcn.h>
#include <sys/types.h>
static void emDenyDebugger(void) {
    char sym[]={'p','t','r','a','c','e',0};
    int (*fn)(int,pid_t,char*,int)=(int(*)(int,pid_t,char*,int))dlsym(RTLD_DEFAULT,sym);
    if(fn)fn(31,0,0,0);
}
#endif
int main(int argc,char**argv){
#if !defined(DEBUG) && defined(__APPLE__)
    emDenyDebugger();
#endif
    @autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(AppDelegate.class));}
}
