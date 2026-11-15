#import "MemorySettingsController.h"
#import "MemoryManager.h"
#include "memory_policy.h"
static __weak MemorySettingsController *openSettings;

@interface MemorySettingsController ()
@property(nonatomic,strong) UISwitch *automatic;
@property(nonatomic,strong) UITextField *threshold;
@property(nonatomic,strong) UITextField *interval;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) UILabel *footprint;
@property(nonatomic,strong) UILabel *result;
@property(nonatomic,strong) UITableViewCell *cleanCell;
@end
@implementation MemorySettingsController
+ (BOOL)hasOpenSettings {return openSettings!=nil;}
- (instancetype)init {return [super initWithStyle:UITableViewStyleGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"Quản lý bộ nhớ";openSettings=self;
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Hủy" style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Lưu" style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    self.automatic=[UISwitch new];self.automatic.on=MemoryManager.shared.enabled;
    self.automatic.accessibilityLabel=@"Tự động dọn";
    [self.automatic addTarget:self action:@selector(updateFields) forControlEvents:UIControlEventValueChanged];
    self.threshold=[self numberField:@"Ngưỡng RAM (MB)" value:MemoryManager.shared.thresholdMB];
    self.interval=[self numberField:@"Dọn mỗi (giây)" value:MemoryManager.shared.intervalSeconds];
    self.tableView.keyboardDismissMode=UIScrollViewKeyboardDismissModeOnDrag;
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=56;
    [self updateFields];
}
- (UITextField *)numberField:(NSString *)label value:(uint32_t)value {
    UITextField *field=[[UITextField alloc] initWithFrame:CGRectMake(0,0,90,44)];
    field.keyboardType=UIKeyboardTypeNumberPad;field.textAlignment=NSTextAlignmentRight;
    field.text=[NSString stringWithFormat:@"%u",value];field.accessibilityLabel=label;return field;
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];__weak MemorySettingsController *weakSelf=self;
    self.timer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){[weakSelf refresh];}];[self refresh];
}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];[self.timer invalidate];self.timer=nil;}
- (void)updateFields {self.threshold.enabled=self.automatic.on;self.interval.enabled=self.automatic.on;}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)view {return 3;}
- (NSInteger)tableView:(UITableView *)view numberOfRowsInSection:(NSInteger)section {return section==0?2:section==1?3:1;}
- (NSString *)tableView:(UITableView *)view titleForHeaderInSection:(NSInteger)section {
    return section==0?@"Bộ nhớ đang dùng":section==1?@"Cài đặt":nil;
}
- (NSString *)tableView:(UITableView *)view titleForFooterInSection:(NSInteger)section {
    if(section==0)return nil;
    if(section==1)return @"Tự dọn khi thiếu bộ nhớ, RAM vượt ngưỡng hoặc đến lịch. Nhập 0 để tắt ngưỡng hoặc lịch dọn.";
    return @"Chỉ dọn bộ nhớ không còn dùng. Game và dữ liệu được giữ nguyên.";
}
- (UITableViewCell *)tableView:(UITableView *)view cellForRowAtIndexPath:(NSIndexPath *)index {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.selectionStyle=UITableViewCellSelectionStyleNone;
    if(index.section==0){
        if(index.row==0){cell.textLabel.text=@"RAM của ứng dụng";self.footprint=cell.detailTextLabel;}
        else {cell.textLabel.numberOfLines=0;self.result=cell.textLabel;}
    }else if(index.section==1){
        cell.textLabel.text=index.row==0?@"Tự động dọn":index.row==1?@"Ngưỡng RAM (MB)":@"Dọn mỗi (giây)";
        cell.accessoryView=index.row==0?self.automatic:index.row==1?self.threshold:self.interval;
    }else {
        cell.textLabel.text=@"Dọn ngay";cell.textLabel.textAlignment=NSTextAlignmentCenter;
        cell.selectionStyle=UITableViewCellSelectionStyleDefault;self.cleanCell=cell;
        cell.accessibilityIdentifier=@"memory-clean-now";
    }
    [self refreshMeasurements];return cell;
}
- (void)refresh {
    BOOL resize=self.result && ![self.result.text isEqualToString:MemoryManager.shared.resultText];
    [self refreshMeasurements];
    if(resize && self.view.window){[self.tableView beginUpdates];[self.tableView endUpdates];}
}
- (void)refreshMeasurements {
    uint64_t bytes=EmAppMemoryBytes();self.footprint.text=bytes?[NSString stringWithFormat:@"%.1f MB",bytes/1048576.0]:@"Không rõ";
    self.result.text=MemoryManager.shared.resultText;
    self.cleanCell.textLabel.enabled=MemoryManager.shared.canClean;
    self.cleanCell.textLabel.textColor=MemoryManager.shared.canClean?UIColor.systemBlueColor:UIColor.grayColor;
}
- (void)tableView:(UITableView *)view didSelectRowAtIndexPath:(NSIndexPath *)index {
    [view deselectRowAtIndexPath:index animated:YES];
    if(index.section==2){[self.view endEditing:YES];[MemoryManager.shared cleanNow];[self refresh];}
}
- (BOOL)readNumber:(UITextField *)field value:(uint32_t *)value {
    NSString *text=[field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(text.length>5 || [text rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location!=NSNotFound)return NO;
    *value=(uint32_t)text.integerValue;return YES;
}
- (void)save {
    uint32_t mb,seconds;
    if(![self readNumber:self.threshold value:&mb] || ![self readNumber:self.interval value:&seconds] || !em_memory_settings_valid(mb,seconds)){
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Kiểm tra lại số đã nhập" message:@"RAM: 64–32768 MB. Thời gian: 30–86400 giây. Nhập 0 để tắt." preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];return;
    }
    [MemoryManager.shared applyEnabled:self.automatic.on thresholdMB:mb intervalSeconds:seconds];[self close];
}
- (void)close {
    [self.view endEditing:YES];void (^completion)(void)=self.onClose;
    __weak MemorySettingsController *weakSelf=self;
    [self dismissViewControllerAnimated:YES completion:^{
        if(openSettings==weakSelf)openSettings=nil;
        if(completion)completion();
    }];
}
@end
