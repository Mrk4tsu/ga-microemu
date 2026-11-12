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
@end
@implementation GamePadButton
@end

@interface GameController : UIViewController <UITextFieldDelegate>
@property(nonatomic,strong) NSURL *jar;
@property(nonatomic,strong) GameScreen *screen;
@property(nonatomic,strong) UIView *statusRow;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UIButton *padToggle;
@property(nonatomic,strong) UIStackView *numpadGrid;
@property(nonatomic,strong) UIStackView *dpadGrid;
@property(nonatomic,strong) NSMutableArray<GamePadButton*> *padButtons;
@property(nonatomic,strong) UIView *inputBar;
@property(nonatomic,strong) GameKeyTextField *keyboardField;
@property(nonatomic,copy) NSString *lastSentText;
@property(nonatomic,strong) NSArray<NSLayoutConstraint*> *portraitPadConstraints;
@property(nonatomic,strong) NSArray<NSLayoutConstraint*> *landscapePadConstraints;
@property(nonatomic,strong) NSArray<NSLayoutConstraint*> *padHiddenConstraints;
@property(nonatomic) BOOL padHidden;
@property(nonatomic,strong) CADisplayLink *displayLink;
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
    self.padButtons=[NSMutableArray new];self.lastSentText=@"";
    self.screen=[GameScreen new];self.screen.virtualWidth=480;self.screen.virtualHeight=320;
    self.screen.contentMode=UIViewContentModeScaleAspectFit;self.screen.userInteractionEnabled=YES;self.screen.multipleTouchEnabled=YES;self.screen.layer.magnificationFilter=kCAFilterNearest;
    self.statusRow=[UIView new];
    self.status=[UILabel new];self.status.text=@"Opening game…";self.status.textColor=UIColor.secondaryLabelColor;self.status.font=[UIFont systemFontOfSize:12];self.status.numberOfLines=1;
    self.padToggle=[UIButton buttonWithType:UIButtonTypeSystem];[self.padToggle setTitle:@"Hide Pad" forState:UIControlStateNormal];
    self.padToggle.titleLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightMedium];[self.padToggle addTarget:self action:@selector(togglePad) forControlEvents:UIControlEventTouchUpInside];
    for(UIView*v in @[self.status,self.padToggle]){v.translatesAutoresizingMaskIntoConstraints=NO;[self.statusRow addSubview:v];}
    [NSLayoutConstraint activateConstraints:@[
        [self.status.leadingAnchor constraintEqualToAnchor:self.statusRow.leadingAnchor constant:12],
        [self.status.centerYAnchor constraintEqualToAnchor:self.statusRow.centerYAnchor],
        [self.status.trailingAnchor constraintLessThanOrEqualToAnchor:self.padToggle.leadingAnchor constant:-8],
        [self.padToggle.trailingAnchor constraintEqualToAnchor:self.statusRow.trailingAnchor constant:-12],
        [self.padToggle.centerYAnchor constraintEqualToAnchor:self.statusRow.centerYAnchor],
        [self.statusRow.heightAnchor constraintEqualToConstant:26]]];
    [self.padToggle setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
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
    NSLayoutConstraint *aspect=[self.screen.heightAnchor constraintEqualToAnchor:self.screen.widthAnchor multiplier:2.0/3.0];
    aspect.priority=999;
    self.portraitPadConstraints=@[
        [self.screen.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],
        [self.screen.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.screen.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        aspect,
        [self.screen.bottomAnchor constraintLessThanOrEqualToAnchor:self.statusRow.topAnchor constant:-4],
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
    [NSLayoutConstraint activateConstraints:@[
        [self.inputBar.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [self.inputBar.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.inputBar.heightAnchor constraintEqualToConstant:48],
        [self.inputBar.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor]]];
    [self updatePadLayout];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(statusChanged:) name:EmStatusNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(modalChanged:) name:EmModalNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    self.displayLink=[CADisplayLink displayLinkWithTarget:self selector:@selector(frame)];self.displayLink.preferredFramesPerSecond=30;[self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.navigationController.interactivePopGestureRecognizer.enabled=NO;[UIApplication sharedApplication].idleTimerDisabled=YES;
    EmClearFrame();em_reset_events();runtimeActive=YES;
    NSString *bootstrap=[[NSBundle mainBundle] pathForResource:@"minijvm_rt" ofType:@"jar" inDirectory:@"Runtime"],*emulator=[[NSBundle mainBundle] pathForResource:@"microemu-ios" ofType:@"jar" inDirectory:@"Runtime"];
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
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self updatePadLayout];
}
- (void)updatePadLayout {
    BOOL landscape=self.view.bounds.size.width>self.view.bounds.size.height;
    [NSLayoutConstraint deactivateConstraints:self.portraitPadConstraints];
    [NSLayoutConstraint deactivateConstraints:self.landscapePadConstraints];
    [NSLayoutConstraint deactivateConstraints:self.padHiddenConstraints];
    self.numpadGrid.hidden=self.padHidden;self.dpadGrid.hidden=self.padHidden;
    if(self.padHidden)[NSLayoutConstraint activateConstraints:self.padHiddenConstraints];
    else [NSLayoutConstraint activateConstraints:landscape?self.landscapePadConstraints:self.portraitPadConstraints];
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
    if(self.finished || self.stopping)return;
    button.backgroundColor=[UIColor colorWithWhite:0.35 alpha:1];
    [button.repeatTimer invalidate];
    for(NSNumber *code in button.keyCodes)em_event(1,code.intValue,0,0,NULL);
    __block int ticks=0;__weak GamePadButton *weakButton=button;
    button.repeatTimer=[NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES block:^(NSTimer*t){
        GamePadButton *b=weakButton;if(!b)return;
        if(++ticks>=4)for(NSNumber *code in b.keyCodes)em_event(3,code.intValue,0,0,NULL);
    }];
}
- (void)keyUp:(GamePadButton*)button {
    button.backgroundColor=button.idleColor;
    [button.repeatTimer invalidate];button.repeatTimer=nil;
    if(!self.finished)for(NSNumber *code in button.keyCodes)em_event(2,code.intValue,0,0,NULL);
}
- (void)setupKeyboardBar {
    self.inputBar=[UIView new];self.inputBar.backgroundColor=[UIColor colorWithWhite:0.1 alpha:0.98];self.inputBar.hidden=YES;
    UIView *line=[UIView new];line.backgroundColor=[UIColor colorWithWhite:0.25 alpha:1];line.translatesAutoresizingMaskIntoConstraints=NO;
    self.keyboardField=[GameKeyTextField new];self.keyboardField.delegate=self;
    self.keyboardField.backgroundColor=[UIColor colorWithWhite:0.18 alpha:1];self.keyboardField.textColor=UIColor.whiteColor;
    self.keyboardField.font=[UIFont systemFontOfSize:15];self.keyboardField.layer.cornerRadius=8;
    self.keyboardField.leftView=[[UIView alloc] initWithFrame:CGRectMake(0,0,10,1)];self.keyboardField.leftViewMode=UITextFieldViewModeAlways;
    self.keyboardField.attributedPlaceholder=[[NSAttributedString alloc] initWithString:@"Nhập văn bản gửi vào game…" attributes:@{NSForegroundColorAttributeName:UIColor.secondaryLabelColor}];
    self.keyboardField.autocorrectionType=UITextAutocorrectionTypeNo;self.keyboardField.autocapitalizationType=UITextAutocapitalizationTypeNone;
    self.keyboardField.spellCheckingType=UITextSpellCheckingTypeNo;self.keyboardField.returnKeyType=UIReturnKeySend;
    [self.keyboardField addTarget:self action:@selector(keyboardTextChanged) forControlEvents:UIControlEventEditingChanged];
    __weak GameController *weakSelf=self;
    self.keyboardField.onEmptyBackspace=^{GameController *s=weakSelf;if(!s || s.finished || s.stopping)return;em_event(13,-8,0,0,NULL);};
    UIButton *leftKey=[UIButton buttonWithType:UIButtonTypeSystem];[leftKey setTitle:@"L" forState:UIControlStateNormal];
    leftKey.titleLabel.font=[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];leftKey.backgroundColor=[UIColor colorWithWhite:0.24 alpha:1];leftKey.tintColor=UIColor.whiteColor;leftKey.layer.cornerRadius=8;
    [leftKey addTarget:self action:@selector(keyboardSendLeft) forControlEvents:UIControlEventTouchUpInside];
    UIButton *send=[UIButton buttonWithType:UIButtonTypeSystem];[send setTitle:@"↵" forState:UIControlStateNormal];
    send.titleLabel.font=[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];send.backgroundColor=UIColor.systemBlueColor;send.tintColor=UIColor.whiteColor;send.layer.cornerRadius=8;
    [send addTarget:self action:@selector(keyboardSendReturn) forControlEvents:UIControlEventTouchUpInside];
    UIButton *done=[UIButton buttonWithType:UIButtonTypeSystem];[done setTitle:@"Xong" forState:UIControlStateNormal];
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
    if(self.finished || self.stopping)return;
    NSString *current=self.keyboardField.text?:@"";
    NSString *previous=self.lastSentText?:@"";
    if([current isEqualToString:previous])return;
    NSUInteger common=0,limit=MIN(previous.length,current.length);
    while(common<limit && [previous characterAtIndex:common]==[current characterAtIndex:common])common++;
    NSUInteger deletes=previous.length-common;
    for(NSUInteger i=0;i<deletes;i++)em_event(13,-8,0,0,NULL);
    NSString *added=[current substringFromIndex:common];
    if(added.length>0)em_event(12,0,0,0,added.UTF8String);
    self.lastSentText=[current copy];
}
- (void)keyboardSendLeft {
    if(self.finished || self.stopping)return;
    [self.keyboardField unmarkText];
    [self keyboardTextChanged];
    em_event(13,-6,0,0,NULL);
    self.keyboardField.text=@"";self.lastSentText=@"";
}
- (void)keyboardSendReturn {
    if(self.finished || self.stopping)return;
    [self.keyboardField unmarkText];
    [self keyboardTextChanged];
    em_event(13,-5,0,0,NULL);
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
- (void)keyboardWillHide:(NSNotification*)notification {
    self.keyboardField.text=@"";self.lastSentText=@"";self.inputBar.hidden=YES;
}
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
            em_event(7,(int)i,0,0,value.UTF8String);
            if(weakSelf)weakSelf.textModal=nil;
        }]];
    }
    UIViewController *previous=self.textModal?:self.presentedViewController;
    self.textModal=alert;
    void (^presentAlert)(void)=^{if(!weakSelf.finished && !weakSelf.stopping && weakSelf.textModal==alert)[weakSelf presentViewController:alert animated:YES completion:nil];};
    if(previous)[previous dismissViewControllerAnimated:NO completion:presentAlert];
    else presentAlert();
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
    if(self.finished || self.stopping || self.presentedViewController)return;
    if(self.keyboardField.isFirstResponder){[self hideKeyboard];return;}
    self.keyboardField.text=@"";self.lastSentText=@"";
    self.inputBar.hidden=NO;[self.view bringSubviewToFront:self.inputBar];
    [self.keyboardField becomeFirstResponder];
}
- (void)stop {
    if(self.finished){[self close];return;}if(self.stopping)return;self.stopping=YES;self.status.text=@"Stopping game…";
    [self hideKeyboard];
    for(GamePadButton *button in self.padButtons){[button.repeatTimer invalidate];button.repeatTimer=nil;}
    [self.textModal dismissViewControllerAnimated:NO completion:nil];self.textModal=nil;em_event(10,0,0,0,NULL);
}
- (void)close {[self.displayLink invalidate];self.displayLink=nil;self.navigationController.interactivePopGestureRecognizer.enabled=YES;[self.navigationController popViewControllerAnimated:YES];}
- (void)dealloc {[[NSNotificationCenter defaultCenter] removeObserver:self];[self.displayLink invalidate];for(GamePadButton *button in self.padButtons)[button.repeatTimer invalidate];}
@end

@interface LibraryController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic,strong) NSArray<NSURL*> *games;
@end
@implementation LibraryController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"GaEmulator";self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeAlways;
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
