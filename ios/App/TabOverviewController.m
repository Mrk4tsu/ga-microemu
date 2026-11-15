#import "TabOverviewController.h"
#import "EmControls.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

@implementation EmTabPreview
@end

@interface EmTabCell : UICollectionViewCell
@property(nonatomic) int tabId;
@property(nonatomic,strong) UILabel *heading;
@property(nonatomic,strong) UILabel *state;
@property(nonatomic,strong) UILabel *placeholder;
@property(nonatomic,strong) UIImageView *preview;
@property(nonatomic,strong) UIView *previewArea;
@property(nonatomic,strong) UIButton *closeButton;
@property(nonatomic,strong) UIButton *stopButton;
@property(nonatomic,strong) UIButton *openButton;
@property(nonatomic,copy) void (^onOpen)(void);
@property(nonatomic,copy) void (^onStop)(void);
@property(nonatomic,copy) void (^onClose)(void);
- (void)configure:(EmTabPreview *)tab;
- (void)displayImage:(UIImage *)image;
@end

@implementation EmTabCell
- (instancetype)initWithFrame:(CGRect)frame {
    if((self=[super initWithFrame:frame])){
        self.contentView.backgroundColor=[UIColor colorWithWhite:0.13 alpha:1];
        self.contentView.layer.cornerRadius=12;self.contentView.clipsToBounds=YES;
        self.heading=[UILabel new];self.heading.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        self.heading.textColor=UIColor.whiteColor;self.heading.lineBreakMode=NSLineBreakByTruncatingTail;
        self.state=[UILabel new];self.state.font=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        self.state.adjustsFontSizeToFitWidth=YES;self.state.minimumScaleFactor=0.8;
        self.previewArea=[UIView new];self.previewArea.backgroundColor=UIColor.blackColor;
        self.preview=[UIImageView new];self.preview.contentMode=UIViewContentModeScaleAspectFit;
        self.preview.layer.magnificationFilter=kCAFilterNearest;
        self.placeholder=[UILabel new];self.placeholder.text=@"Waiting for game…";self.placeholder.numberOfLines=2;
        self.placeholder.textAlignment=NSTextAlignmentCenter;self.placeholder.font=[UIFont systemFontOfSize:12];
        self.placeholder.textColor=[UIColor colorWithWhite:0.55 alpha:1];
        self.closeButton=[self icon:EmControlClose action:@selector(closeTab)];
        self.stopButton=[self icon:EmControlStop action:@selector(stopTab)];
        self.stopButton.tintColor=[UIColor colorWithRed:1 green:0.3 blue:0.3 alpha:1];
        self.openButton=[self icon:EmControlExpand action:@selector(openTab)];
        self.openButton.tintColor=UIColor.systemBlueColor;
        for(UIView *view in @[self.heading,self.state,self.previewArea,self.closeButton,self.stopButton,self.openButton]){
            view.translatesAutoresizingMaskIntoConstraints=NO;[self.contentView addSubview:view];
        }
        for(UIView *view in @[self.preview,self.placeholder]){
            view.translatesAutoresizingMaskIntoConstraints=NO;[self.previewArea addSubview:view];
        }
        [NSLayoutConstraint activateConstraints:@[
            [self.closeButton.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [self.closeButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [self.closeButton.widthAnchor constraintEqualToConstant:44],[self.closeButton.heightAnchor constraintEqualToConstant:44],
            [self.heading.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
            [self.heading.trailingAnchor constraintEqualToAnchor:self.closeButton.leadingAnchor],
            [self.heading.centerYAnchor constraintEqualToAnchor:self.closeButton.centerYAnchor],
            [self.previewArea.topAnchor constraintEqualToAnchor:self.closeButton.bottomAnchor],
            [self.previewArea.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:1],
            [self.previewArea.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-1],
            [self.previewArea.bottomAnchor constraintEqualToAnchor:self.openButton.topAnchor],
            [self.preview.topAnchor constraintEqualToAnchor:self.previewArea.topAnchor],
            [self.preview.bottomAnchor constraintEqualToAnchor:self.previewArea.bottomAnchor],
            [self.preview.leadingAnchor constraintEqualToAnchor:self.previewArea.leadingAnchor],
            [self.preview.trailingAnchor constraintEqualToAnchor:self.previewArea.trailingAnchor],
            [self.placeholder.centerYAnchor constraintEqualToAnchor:self.previewArea.centerYAnchor],
            [self.placeholder.leadingAnchor constraintEqualToAnchor:self.previewArea.leadingAnchor constant:8],
            [self.placeholder.trailingAnchor constraintEqualToAnchor:self.previewArea.trailingAnchor constant:-8],
            [self.openButton.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
            [self.openButton.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            [self.openButton.widthAnchor constraintEqualToConstant:44],[self.openButton.heightAnchor constraintEqualToConstant:44],
            [self.stopButton.trailingAnchor constraintEqualToAnchor:self.openButton.leadingAnchor],
            [self.stopButton.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            [self.stopButton.widthAnchor constraintEqualToConstant:44],[self.stopButton.heightAnchor constraintEqualToConstant:44],
            [self.state.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
            [self.state.trailingAnchor constraintEqualToAnchor:self.stopButton.leadingAnchor constant:-2],
            [self.state.centerYAnchor constraintEqualToAnchor:self.openButton.centerYAnchor]]];
    }
    return self;
}
- (UIButton *)icon:(EmControlIcon)icon action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];button.tintColor=UIColor.lightGrayColor;
    EmSetButtonIcon(button,icon,@"");[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return button;
}
- (void)configure:(EmTabPreview *)tab {
    self.tabId=tab.tabId;
    self.heading.text=tab.title;
    self.state.text=tab.stopping?@"Stopping":tab.finished?@"Stopped":tab.sleeping?@"Sleep":@"Active";
    self.state.textColor=tab.stopping?[UIColor colorWithRed:1 green:0.75 blue:0.25 alpha:1]:
        tab.finished || tab.sleeping?UIColor.lightGrayColor:[UIColor colorWithRed:0.4 green:0.9 blue:0.65 alpha:1];
    self.state.accessibilityValue=tab.status;
    self.contentView.layer.borderWidth=tab.active?2:1;
    self.contentView.layer.borderColor=(tab.active?UIColor.systemBlueColor:[UIColor colorWithWhite:0.22 alpha:1]).CGColor;
    self.stopButton.enabled=!tab.finished && !tab.stopping;
    self.closeButton.accessibilityLabel=[@"Close tab: " stringByAppendingString:tab.title];
    self.closeButton.accessibilityHint=@"Stops the game and removes this tab.";
    self.stopButton.accessibilityLabel=[@"Stop game: " stringByAppendingString:tab.title];
    self.stopButton.accessibilityHint=@"Keeps the tab and its last image.";
    self.openButton.accessibilityLabel=[@"Open tab: " stringByAppendingString:tab.title];
    self.closeButton.accessibilityIdentifier=[NSString stringWithFormat:@"tab-%d-close",tab.tabId];
    self.stopButton.accessibilityIdentifier=[NSString stringWithFormat:@"tab-%d-stop",tab.tabId];
    self.openButton.accessibilityIdentifier=[NSString stringWithFormat:@"tab-%d-open",tab.tabId];
    self.placeholder.text=tab.finished?@"Game stopped":@"Waiting for game…";
    [self displayImage:tab.image];
}
- (void)displayImage:(UIImage *)image {self.preview.image=image;self.placeholder.hidden=image!=nil;}
- (void)openTab {if(self.onOpen)self.onOpen();}
- (void)stopTab {if(self.onStop)self.onStop();}
- (void)closeTab {if(self.onClose)self.onClose();}
- (void)prepareForReuse {
    [super prepareForReuse];self.preview.image=nil;self.onOpen=nil;self.onStop=nil;self.onClose=nil;
}
@end

@interface TabOverviewController ()
@property(nonatomic,copy) NSArray<EmTabPreview *> *tabs;
@end
@implementation TabOverviewController
- (instancetype)init {
    UICollectionViewFlowLayout *layout=[UICollectionViewFlowLayout new];
    layout.minimumInteritemSpacing=12;layout.minimumLineSpacing=12;layout.sectionInset=UIEdgeInsetsMake(12,12,24,12);
    return [super initWithCollectionViewLayout:layout];
}
- (void)viewDidLoad {
    [super viewDidLoad];self.collectionView.backgroundColor=[UIColor colorWithWhite:0.045 alpha:1];
    self.collectionView.alwaysBounceVertical=YES;
    self.collectionView.accessibilityIdentifier=@"tab-overview";
    [self.collectionView registerClass:EmTabCell.class forCellWithReuseIdentifier:@"tab"];
}
- (void)displayTabs:(NSArray<EmTabPreview *> *)tabs {
    BOOL sameOrder=self.tabs.count==tabs.count;
    if(sameOrder)for(NSUInteger i=0;i<tabs.count;i++)if(self.tabs[i].tabId!=tabs[i].tabId){sameOrder=NO;break;}
    self.tabs=tabs;
    if(!sameOrder){[self.collectionView reloadData];return;}
    // Status changes should not rebuild the grid, move its scroll position or
    // replace the focused button while the user is browsing their tabs.
    for(NSIndexPath *index in self.collectionView.indexPathsForVisibleItems){
        if(index.item>=tabs.count)continue; // A structural reload may still be pending.
        EmTabCell *cell=(EmTabCell *)[self.collectionView cellForItemAtIndexPath:index];
        if(cell.tabId==tabs[index.item].tabId)[cell configure:tabs[index.item]];
    }
}
- (NSInteger)collectionView:(UICollectionView *)view numberOfItemsInSection:(NSInteger)section {return self.tabs.count;}
- (UICollectionViewCell *)collectionView:(UICollectionView *)view cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    EmTabCell *cell=[view dequeueReusableCellWithReuseIdentifier:@"tab" forIndexPath:indexPath];
    EmTabPreview *tab=self.tabs[indexPath.item];[cell configure:tab];int tabId=tab.tabId;
    __weak TabOverviewController *weakSelf=self;
    cell.onOpen=^{if(weakSelf.onSelectTab)weakSelf.onSelectTab(tabId);};
    cell.onStop=^{if(weakSelf.onStopTab)weakSelf.onStopTab(tabId);};
    cell.onClose=^{if(weakSelf.onCloseTab)weakSelf.onCloseTab(tabId);};
    return cell;
}
- (void)collectionView:(UICollectionView *)view didSelectItemAtIndexPath:(NSIndexPath *)indexPath {
    if(indexPath.item<self.tabs.count && self.onSelectTab)self.onSelectTab(self.tabs[indexPath.item].tabId);
}
- (CGSize)collectionView:(UICollectionView *)view layout:(UICollectionViewLayout *)layout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {
    CGFloat available=CGRectGetWidth(view.bounds)-view.adjustedContentInset.left-view.adjustedContentInset.right-24;
    NSInteger columns=MAX(2,MIN(4,(NSInteger)floor((available+12)/240)));
    CGFloat width=MAX(1,floor((available-(columns-1)*12)/columns));
    return CGSizeMake(width,floor(width*1.25)+88);
}
- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator {
    [super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];
    [self.collectionView.collectionViewLayout invalidateLayout];
}
- (void)updateImage:(UIImage *)image forTab:(int)tabId {
    for(NSUInteger i=0;i<self.tabs.count;i++)if(self.tabs[i].tabId==tabId){
        self.tabs[i].image=image;
        EmTabCell *cell=(EmTabCell *)[self.collectionView cellForItemAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]];
        if(cell.tabId==tabId)[cell displayImage:image];return;
    }
}
@end
