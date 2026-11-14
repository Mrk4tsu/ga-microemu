#import "ScreenSizePicker.h"
#include "emulator.h"

@interface ScreenSizePicker ()
@property(nonatomic,strong) NSURL *jar;
@property(nonatomic,strong) UITextField *widthField;
@property(nonatomic,strong) UITextField *heightField;
@property(nonatomic,strong) NSArray<NSArray<NSNumber *> *> *presets;
@property(nonatomic) BOOL finished;
@property(nonatomic) BOOL fullScreen;
@property(nonatomic) int fullWidth;
@property(nonatomic) int fullHeight;
@end

@implementation ScreenSizePicker
+ (NSString *)settingsKeyForJar:(NSURL *)jar { return [@"GaEmulator.ScreenSize." stringByAppendingString:jar.lastPathComponent]; }
+ (NSDictionary<NSString *, NSNumber *> *)savedSizeForJar:(NSURL *)jar {
    NSDictionary *saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:[self settingsKeyForJar:jar]];
    if(![saved[@"width"] isKindOfClass:NSNumber.class] || ![saved[@"height"] isKindOfClass:NSNumber.class])return nil;
    NSInteger width=[saved[@"width"] integerValue], height=[saved[@"height"] integerValue];
    if(width<EM_VIEWPORT_MIN || width>EM_VIEWPORT_MAX || height<EM_VIEWPORT_MIN || height>EM_VIEWPORT_MAX)return nil;
    id full=saved[@"fullScreen"];
    if(full && ![full isKindOfClass:NSNumber.class])return nil;
    return @{@"width":@(width),@"height":@(height),@"fullScreen":@([full boolValue])};
}
+ (void)removeSavedSizeForJar:(NSURL *)jar {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:[self settingsKeyForJar:jar]];
}
- (instancetype)initWithJar:(NSURL *)jar fullWidth:(int)width fullHeight:(int)height {
    if ((self=[super initWithStyle:UITableViewStyleGrouped])) {
        self.jar=jar;self.fullWidth=width;self.fullHeight=height;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"Screen size";
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Cancel" style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:self.editingSettings?@"Save":@"Start" style:UIBarButtonItemStyleDone target:self action:@selector(start)];
    self.presets=@[@[@240,@320],@[@320,@240],@[@320,@480],@[@480,@320],@[@480,@800],@[@800,@480]];
    self.widthField=[self dimensionField]; self.heightField=[self dimensionField];
    NSDictionary *saved=[ScreenSizePicker savedSizeForJar:self.jar];
    NSInteger width=[saved[@"width"] integerValue], height=[saved[@"height"] integerValue];
    if(width<EM_VIEWPORT_MIN || width>EM_VIEWPORT_MAX || height<EM_VIEWPORT_MIN || height>EM_VIEWPORT_MAX) {width=240;height=320;}
    self.fullScreen=[saved[@"fullScreen"] boolValue];
    if(self.fullScreen && em_viewport_valid(self.fullWidth,self.fullHeight)){width=self.fullWidth;height=self.fullHeight;}
    self.widthField.text=[NSString stringWithFormat:@"%ld",(long)width];
    self.heightField.text=[NSString stringWithFormat:@"%ld",(long)height];
    self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    [self updateStart];
}
- (UITextField *)dimensionField {
    UITextField *field=[[UITextField alloc] initWithFrame:CGRectMake(0,0,110,36)];
    field.keyboardType=UIKeyboardTypeNumberPad; field.textAlignment=NSTextAlignmentRight;
    field.accessibilityLabel=@"Screen dimension in pixels";
    [field addTarget:self action:@selector(dimensionChanged:) forControlEvents:UIControlEventEditingChanged];
    return field;
}
- (BOOL)parseField:(UITextField *)field value:(int *)value {
    NSString *text=[field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!text.length || text.length>4 || [text rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound) return NO;
    NSInteger number=text.integerValue;
    if(number<EM_VIEWPORT_MIN || number>EM_VIEWPORT_MAX) return NO;
    *value=(int)number;return YES;
}
- (BOOL)sizeWidth:(int *)width height:(int *)height {
    return [self parseField:self.widthField value:width] && [self parseField:self.heightField value:height] && em_viewport_valid(*width,*height);
}
- (void)updateStart {
    int width=0,height=0;self.navigationItem.rightBarButtonItem.enabled=[self sizeWidth:&width height:&height];
}
- (void)dimensionChanged:(UITextField *)field {
    if(field)self.fullScreen=NO;
    [self updateStart];
    for(NSInteger row=0;row<=(NSInteger)self.presets.count;row++) {
        NSIndexPath *path=[NSIndexPath indexPathForRow:row inSection:0];
        UITableViewCell *cell=[self.tableView cellForRowAtIndexPath:path];
        int width=0,height=0;BOOL valid=[self sizeWidth:&width height:&height];
        BOOL selected=row==0?self.fullScreen:(!self.fullScreen && valid && width==[self.presets[row-1][0] intValue] && height==[self.presets[row-1][1] intValue]);
        cell.accessoryType=selected?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
    }
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return section==0?self.presets.count+1:2; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { return section==0?self.jar.lastPathComponent:@"Custom size (pixels)"; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if(section==0) return @"Full screen stretches the picture to fill the game area. If full-size images cannot load, the game restarts with a smaller screen and enlarges it. For older games, you can also choose 240 × 320.";
    return [NSString stringWithFormat:@"Each dimension: %d–%d px. Maximum: %d × %d. Fixed sizes are used exactly. %@ Details and loading errors appear in Log.",EM_VIEWPORT_MIN,EM_VIEWPORT_MAX,EM_VIEWPORT_MAX,EM_VIEWPORT_MAX,self.editingSettings?@"Changes apply the next time you open this JAR. Full screen adapts to the game area at launch.":@"Your choice is saved. Next time this JAR opens directly; use its info button in the library to change the screen size."];
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if(path.section==0) {
        if(path.row==0){
            cell.textLabel.text=em_viewport_valid(self.fullWidth,self.fullHeight)?[NSString stringWithFormat:@"Full screen · %d × %d",self.fullWidth,self.fullHeight]:@"Full screen · Auto";
            if(self.fullScreen)cell.accessoryType=UITableViewCellAccessoryCheckmark;
            return cell;
        }
        NSArray<NSNumber *> *size=self.presets[path.row-1];
        cell.textLabel.text=[NSString stringWithFormat:@"%@ × %@",size[0],size[1]];
        int width=0,height=0;
        if(!self.fullScreen && [self sizeWidth:&width height:&height] && width==size[0].intValue && height==size[1].intValue) cell.accessoryType=UITableViewCellAccessoryCheckmark;
    } else {
        UITextField *field=path.row==0?self.widthField:self.heightField;
        cell.textLabel.text=path.row==0?@"Width":@"Height";
        field.accessibilityLabel=cell.textLabel.text;
        cell.accessoryView=field;cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)path {
    [tableView deselectRowAtIndexPath:path animated:YES];
    if(path.section!=0) return;
    [self.view endEditing:YES];
    self.fullScreen=path.row==0;
    if(!self.fullScreen){
        NSArray<NSNumber *> *size=self.presets[path.row-1];
        self.widthField.text=[size[0] stringValue];self.heightField.text=[size[1] stringValue];
    } else {
        int width=0,height=0;
        if(em_viewport_valid(self.fullWidth,self.fullHeight)){width=self.fullWidth;height=self.fullHeight;}
        else if(![self sizeWidth:&width height:&height]){width=240;height=320;}
        self.widthField.text=[NSString stringWithFormat:@"%d",width];self.heightField.text=[NSString stringWithFormat:@"%d",height];
    }
    [self dimensionChanged:nil];
}
- (void)start {
    if(self.finished) return;
    int width=0,height=0;if(![self sizeWidth:&width height:&height]) return;
    self.finished=YES;
    [NSUserDefaults.standardUserDefaults setObject:@{@"width":@(width),@"height":@(height),@"fullScreen":@(self.fullScreen)} forKey:[ScreenSizePicker settingsKeyForJar:self.jar]];
    if(self.onFinish) self.onFinish(YES,width,height,self.fullScreen);
}
- (void)cancel {
    if(self.finished) return;self.finished=YES;
    if(self.onFinish) self.onFinish(NO,0,0,NO);
}
@end
