#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>
#import "AppPlatform.h"
#include "emulator.h"
#include <stdio.h>

static BOOL runtimeActive;
static NSURL *gamesDirectory(void) {
    NSURL *documents=[[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *games=[documents URLByAppendingPathComponent:@"Games" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:games withIntermediateDirectories:YES attributes:nil error:nil];return games;
}

@interface GameScreen : UIImageView
@property(nonatomic) int virtualWidth;
@property(nonatomic) int virtualHeight;
@property(nonatomic,weak) UITouch *pointer;
@end
@implementation GameScreen
- (CGPoint)position:(UITouch*)touch {
    CGSize size=self.bounds.size;CGFloat scale=MIN(size.width/self.virtualWidth,size.height/self.virtualHeight);
    CGPoint p=[touch locationInView:self];return CGPointMake((p.x-(size.width-self.virtualWidth*scale)/2)/scale,(p.y-(size.height-self.virtualHeight*scale)/2)/scale);
}
- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if(self.pointer)return;UITouch*t=touches.anyObject;CGPoint p=[self position:t];
    if(p.x<0 || p.y<0 || p.x>=self.virtualWidth || p.y>=self.virtualHeight)return;
    self.pointer=t;em_event(4,(int)p.x,(int)p.y,0,NULL);
}
- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if(!self.pointer || ![touches containsObject:self.pointer])return;CGPoint p=[self position:self.pointer];em_event(5,(int)p.x,(int)p.y,0,NULL);
}
- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    if(!self.pointer || ![touches containsObject:self.pointer])return;CGPoint p=[self position:self.pointer];em_event(6,(int)p.x,(int)p.y,0,NULL);self.pointer=nil;
}
- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {[self touchesEnded:touches withEvent:event];}
@end

@interface GameController : UIViewController <UITextFieldDelegate>
@property(nonatomic,strong) NSURL *jar;
@property(nonatomic,strong) GameScreen *screen;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) CADisplayLink *displayLink;
@property(nonatomic,strong) NSMutableDictionary<NSNumber*,NSTimer*> *repeatTimers;
@property(nonatomic,strong) UIAlertController *textModal;
@property(nonatomic) NSInteger maxTextLength;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL stopping;
@end

@implementation GameController
- (void)viewDidLoad {
    [super viewDidLoad];self.view.backgroundColor=[UIColor colorWithWhite:0.045 alpha:1];self.title=self.jar.lastPathComponent;
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.hidesBackButton=YES;self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Stop" style:UIBarButtonItemStylePlain target:self action:@selector(stop)];
    self.navigationItem.rightBarButtonItems=@[
        [[UIBarButtonItem alloc] initWithTitle:@"Log" style:UIBarButtonItemStylePlain target:self action:@selector(shareLog)],
        [[UIBarButtonItem alloc] initWithTitle:@"Keyboard" style:UIBarButtonItemStylePlain target:self action:@selector(keyboard)]];
    self.repeatTimers=[NSMutableDictionary new];self.screen=[GameScreen new];self.screen.virtualWidth=480;self.screen.virtualHeight=320;
    self.screen.contentMode=UIViewContentModeScaleAspectFit;self.screen.userInteractionEnabled=YES;self.screen.multipleTouchEnabled=YES;self.screen.layer.magnificationFilter=kCAFilterNearest;
    self.status=[UILabel new];self.status.text=@"Opening game…";self.status.textColor=UIColor.secondaryLabelColor;self.status.font=[UIFont systemFontOfSize:12];self.status.numberOfLines=2;
    UIStackView *controls=[[UIStackView alloc] initWithArrangedSubviews:@[[self key:@"L" code:-6],[self key:@"◀" code:-3],[self key:@"▲" code:-1],[self key:@"●" code:-5],[self key:@"▼" code:-2],[self key:@"▶" code:-4],[self key:@"R" code:-7]]];
    controls.axis=UILayoutConstraintAxisHorizontal;controls.spacing=6;controls.distribution=UIStackViewDistributionFillEqually;
    UIStackView *numbers=[[UIStackView alloc] initWithArrangedSubviews:@[[self key:@"1" code:'1'],[self key:@"3" code:'3'],[self key:@"7" code:'7'],[self key:@"9" code:'9'],[self key:@"*" code:'*'],[self key:@"0" code:'0'],[self key:@"#" code:'#']]];
    numbers.spacing=6;numbers.distribution=UIStackViewDistributionFillEqually;
    for(UIView*v in @[self.screen,self.status,controls,numbers]){v.translatesAutoresizingMaskIntoConstraints=NO;[self.view addSubview:v];}
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.screen.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],[self.screen.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],[self.screen.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.screen.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-4],
        [self.status.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],[self.status.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],[self.status.heightAnchor constraintEqualToConstant:30],
        [self.status.bottomAnchor constraintEqualToAnchor:controls.topAnchor constant:-6],
        [controls.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],[controls.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],[controls.heightAnchor constraintEqualToConstant:44],
        [controls.bottomAnchor constraintEqualToAnchor:numbers.topAnchor constant:-6],
        [numbers.leadingAnchor constraintEqualToAnchor:controls.leadingAnchor],[numbers.trailingAnchor constraintEqualToAnchor:controls.trailingAnchor],[numbers.heightAnchor constraintEqualToConstant:36],
        [numbers.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-6]]];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(statusChanged:) name:EmStatusNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(modalChanged:) name:EmModalNotification object:nil];
    self.displayLink=[CADisplayLink displayLinkWithTarget:self selector:@selector(frame)];self.displayLink.preferredFramesPerSecond=30;[self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.navigationController.interactivePopGestureRecognizer.enabled=NO;[UIApplication sharedApplication].idleTimerDisabled=YES;
    EmClearFrame();em_reset_events();runtimeActive=YES;
    NSString *bootstrap=[[NSBundle mainBundle] pathForResource:@"minijvm_rt" ofType:@"jar" inDirectory:@"Resources"],*emulator=[[NSBundle mainBundle] pathForResource:@"microemu-ios" ofType:@"jar" inDirectory:@"Resources"];
    NSURL *documents=[gamesDirectory() URLByDeletingLastPathComponent];NSString *rms=[[documents URLByAppendingPathComponent:@"RMS" isDirectory:YES] path];
    NSString *log=[[documents URLByAppendingPathComponent:@"microemu.log"] path];NSString *jar=self.jar.path;
    __weak GameController *weakSelf=self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            freopen(log.fileSystemRepresentation,"w",stdout);freopen(log.fileSystemRepresentation,"a",stderr);setvbuf(stdout,NULL,_IOLBF,0);
            int result=bootstrap && emulator?em_run(bootstrap.fileSystemRepresentation,emulator.fileSystemRepresentation,jar.fileSystemRepresentation,rms.fileSystemRepresentation,480,320):-1;
            dispatch_async(dispatch_get_main_queue(), ^{GameController *owner=weakSelf;runtimeActive=NO;owner.finished=YES;
                owner.status.text=result==0?@"Game stopped":@"Game error — see Log";owner.navigationItem.leftBarButtonItem.title=@"Back";
                [UIApplication sharedApplication].idleTimerDisabled=NO;if(owner.stopping)[owner close];});
        }
    });
}
- (UIButton*)key:(NSString*)title code:(NSInteger)code {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];[button setTitle:title forState:UIControlStateNormal];button.tag=code;
    button.backgroundColor=[UIColor colorWithWhite:0.15 alpha:1];button.tintColor=UIColor.whiteColor;button.layer.cornerRadius=9;button.titleLabel.font=[UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [button addTarget:self action:@selector(keyDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(keyUp:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel|UIControlEventTouchDragExit];return button;
}
- (void)keyDown:(UIButton*)button {
    if(self.finished || self.stopping)return;NSNumber *key=@(button.tag);[self.repeatTimers[key] invalidate];em_event(1,(int)button.tag,0,0,NULL);
    __block int ticks=0;self.repeatTimers[key]=[NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES block:^(NSTimer*t){if(++ticks>=4)em_event(3,(int)button.tag,0,0,NULL);}];
}
- (void)keyUp:(UIButton*)button {NSNumber *key=@(button.tag);[self.repeatTimers[key] invalidate];[self.repeatTimers removeObjectForKey:key];if(!self.finished)em_event(2,(int)button.tag,0,0,NULL);}
- (void)frame {
    int width,height;NSData *data=EmConsumeFrame(&width,&height);if(!data)return;
    CGColorSpaceRef color=CGColorSpaceCreateDeviceRGB();CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGImageRef image=CGImageCreate(width,height,8,32,width*4,color,kCGBitmapByteOrder32Little|kCGImageAlphaFirst,provider,NULL,NO,kCGRenderingIntentDefault);
    if(image){self.screen.image=[UIImage imageWithCGImage:image];CGImageRelease(image);}CGDataProviderRelease(provider);CGColorSpaceRelease(color);
}
- (void)statusChanged:(NSNotification*)notification {self.status.text=notification.object;}
- (void)modalChanged:(NSNotification*)notification {
    NSDictionary *info=notification.object;
    if(info[@"title"]==NSNull.null){[self.textModal dismissViewControllerAnimated:NO completion:nil];self.textModal=nil;return;}
    if(self.finished || self.stopping)return;
    [self.textModal dismissViewControllerAnimated:NO completion:nil];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:info[@"title"] message:[info[@"max"] intValue]>0?nil:info[@"value"] preferredStyle:UIAlertControllerStyleAlert];
    self.textModal=alert;self.maxTextLength=[info[@"max"] integerValue];int constraints=[info[@"constraints"] intValue];
    if(self.maxTextLength>0)[alert addTextFieldWithConfigurationHandler:^(UITextField*field){field.text=info[@"value"];field.delegate=self;field.secureTextEntry=(constraints&0x10000)!=0;
        int type=constraints&0xffff;field.keyboardType=type==2?UIKeyboardTypeNumberPad:type==3?UIKeyboardTypePhonePad:type==5?UIKeyboardTypeDecimalPad:type==1?UIKeyboardTypeEmailAddress:UIKeyboardTypeDefault;
        field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;}];
    NSArray *commands=info[@"commands"];if(!commands.count)commands=@[@"Done"];
    for(NSUInteger i=0;i<commands.count;i++){
        [alert addAction:[UIAlertAction actionWithTitle:commands[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction*a){NSString *value=alert.textFields.firstObject.text?:@"";em_event(7,(int)i,0,0,value.UTF8String);self.textModal=nil;}]];
    }
    [self presentViewController:alert animated:YES completion:nil];
}
- (BOOL)textField:(UITextField*)field shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString*)replacement {
    return (NSInteger)field.text.length-(NSInteger)range.length+(NSInteger)replacement.length<=self.maxTextLength;
}
- (void)shareLog {
    NSURL *log=[[gamesDirectory() URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"microemu.log"];
    if(![[NSFileManager defaultManager] fileExistsAtPath:log.path])return;
    UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[log] applicationActivities:nil];share.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItems.firstObject;[self presentViewController:share animated:YES completion:nil];
}
- (void)keyboard {
    if(self.finished || self.stopping || self.presentedViewController)return;
    UIAlertController *editor=[UIAlertController alertControllerWithTitle:@"Type into game" message:@"Tap a text field in the game first. Text is hidden while you type." preferredStyle:UIAlertControllerStyleAlert];
    [editor addTextFieldWithConfigurationHandler:^(UITextField*field){field.secureTextEntry=YES;field.autocorrectionType=UITextAutocorrectionTypeNo;field.autocapitalizationType=UITextAutocapitalizationTypeNone;}];
    [editor addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [editor addAction:[UIAlertAction actionWithTitle:@"Type" style:UIAlertActionStyleDefault handler:^(UIAlertAction*a){NSString *text=editor.textFields.firstObject.text?:@"";em_event(12,0,0,0,text.UTF8String);}]];
    [self presentViewController:editor animated:YES completion:nil];
}
- (void)stop {
    if(self.finished){[self close];return;}if(self.stopping)return;self.stopping=YES;self.status.text=@"Stopping game…";
    for(NSNumber *key in self.repeatTimers){[self.repeatTimers[key] invalidate];em_event(2,key.intValue,0,0,NULL);}[self.repeatTimers removeAllObjects];
    [self.textModal dismissViewControllerAnimated:NO completion:nil];self.textModal=nil;em_event(10,0,0,0,NULL);
}
- (void)close {[self.displayLink invalidate];self.displayLink=nil;self.navigationController.interactivePopGestureRecognizer.enabled=YES;[self.navigationController popViewControllerAnimated:YES];}
- (void)dealloc {[[NSNotificationCenter defaultCenter] removeObserver:self];[self.displayLink invalidate];for(NSTimer*t in self.repeatTimers.allValues)[t invalidate];}
@end

@interface LibraryController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic,strong) NSArray<NSURL*> *games;
@end
@implementation LibraryController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"MicroEmu";self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Import JAR" style:UIBarButtonItemStylePlain target:self action:@selector(importJar)];
    self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;
}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];self.games=[[[NSFileManager defaultManager] contentsOfDirectoryAtURL:gamesDirectory() includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL*url,NSDictionary*bindings){return [url.pathExtension.lowercaseString isEqualToString:@"jar"];}]];self.games=[self.games sortedArrayUsingComparator:^NSComparisonResult(NSURL*a,NSURL*b){return [a.lastPathComponent localizedCaseInsensitiveCompare:b.lastPathComponent];}];[self.tableView reloadData];}
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {return self.games.count;}
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)index {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];cell.textLabel.text=self.games[index.row].lastPathComponent;cell.detailTextLabel.text=@"Java ME · 480 × 320";cell.imageView.image=[UIImage systemImageNamed:@"gamecontroller.fill"];cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;
}
- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {return self.games.count?@"Tap a game to run it. Touch the game screen or use the buttons below it.":@"Import a MIDP JAR from Files to get started. Games run locally on your iPhone.";}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)index {if(runtimeActive)return;GameController *game=[GameController new];game.jar=self.games[index.row];[self.navigationController pushViewController:game animated:YES];}
- (void)importJar {UTType *jar=[UTType typeWithFilenameExtension:@"jar"]?:UTTypeData;UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[jar,UTTypeData] asCopy:YES];picker.delegate=self;picker.allowsMultipleSelection=YES;[self presentViewController:picker animated:YES completion:nil];}
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
    for(NSURL *url in urls){if(![url.pathExtension.lowercaseString isEqualToString:@"jar"])continue;BOOL scoped=[url startAccessingSecurityScopedResource];
        NSURL *target=[gamesDirectory() URLByAppendingPathComponent:url.lastPathComponent];if([[NSFileManager defaultManager] fileExistsAtPath:target.path])target=[gamesDirectory() URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.jar",url.lastPathComponent.stringByDeletingPathExtension,NSUUID.UUID.UUIDString]];
        NSError *error=nil;[[NSFileManager defaultManager] copyItemAtURL:url toURL:target error:&error];if(scoped)[url stopAccessingSecurityScopedResource];
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
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:[[LibraryController alloc] initWithStyle:UITableViewStyleInsetGrouped]];navigation.navigationBar.prefersLargeTitles=YES;self.window.rootViewController=navigation;self.window.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;[self.window makeKeyAndVisible];return YES;
}
- (void)applicationDidEnterBackground:(UIApplication*)application {if(runtimeActive)em_event(8,0,0,0,NULL);}
- (void)applicationWillEnterForeground:(UIApplication*)application {if(runtimeActive)em_event(9,0,0,0,NULL);}
@end
int main(int argc,char**argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(AppDelegate.class));}}
