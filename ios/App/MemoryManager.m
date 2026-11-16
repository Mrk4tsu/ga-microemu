#import "MemoryManager.h"
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#include "emulator.h"
#include "memory_policy.h"
#include <stdio.h>

NSString *const EmMemoryWillCleanNotification=@"GaEmulatorMemoryWillClean";
static NSString *const settingsKey=@"GaEmulator.MemorySettings";
static uint64_t uptimeMS(void) {return (uint64_t)(NSProcessInfo.processInfo.systemUptime*1000);}
float EmAppCpuUsage(void) {
    thread_array_t threads;mach_msg_type_number_t count=0;
    if(task_threads(mach_task_self(),&threads,&count)!=KERN_SUCCESS)return -1;
    float usage=0;BOOL measured=NO;
    for(mach_msg_type_number_t i=0;i<count;i++){
        thread_basic_info_data_t info;mach_msg_type_number_t length=THREAD_BASIC_INFO_COUNT;
        if(thread_info(threads[i],THREAD_BASIC_INFO,(thread_info_t)&info,&length)==KERN_SUCCESS){
            measured=YES;
            if(!(info.flags&TH_FLAGS_IDLE))usage+=info.cpu_usage/(float)TH_USAGE_SCALE*100;
        }
        mach_port_deallocate(mach_task_self(),threads[i]);
    }
    vm_deallocate(mach_task_self(),(vm_address_t)threads,count*sizeof(thread_t));
    return measured?usage:-1;
}
uint64_t EmAppMemoryBytes(void) {
    task_vm_info_data_t info;mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    if(task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&info,&count)==KERN_SUCCESS && info.phys_footprint>0)return info.phys_footprint;
    struct task_basic_info basic;count=TASK_BASIC_INFO_COUNT;
    if(task_info(mach_task_self(),TASK_BASIC_INFO,(task_info_t)&basic,&count)==KERN_SUCCESS)return basic.resident_size;
    return 0;
}
@interface MemoryManager () {
    EmMemoryPolicy _policy;
}
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,readwrite) BOOL cleaning;
@property(nonatomic,readwrite,copy) NSString *resultText;
@property(nonatomic) uint64_t token;
@property(nonatomic) uint64_t beforeBytes;
@property(nonatomic) uint64_t requestedAt;
- (void)startCleanup:(NSString *)reason;
- (void)finishCleanup:(EmMemoryCleanup)state;
@end
@implementation MemoryManager
+ (instancetype)shared {
    static MemoryManager *manager;static dispatch_once_t once;
    dispatch_once(&once,^{manager=[MemoryManager new];});return manager;
}
- (instancetype)init {
    if((self=[super init])){
        NSDictionary *saved=[NSUserDefaults.standardUserDefaults dictionaryForKey:settingsKey];
        _policy.enabled=saved?saved[@"enabled"]!=nil && [saved[@"enabled"] boolValue]:YES;
        NSInteger mb=[saved[@"thresholdMB"] integerValue],seconds=[saved[@"intervalSeconds"] integerValue];
        if(mb>=0 && mb<=32768 && seconds>=0 && seconds<=86400 && em_memory_settings_valid((uint32_t)mb,(uint32_t)seconds)){
            _policy.threshold_mb=(uint32_t)mb;_policy.interval_seconds=(uint32_t)seconds;
        }
        _policy.started_ms=uptimeMS();self.resultText=@"Chưa dọn lần nào.";
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(memoryWarning:) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
        __weak MemoryManager *weakSelf=self;
        self.timer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){[weakSelf tick];}];
    }return self;
}
- (BOOL)enabled {return _policy.enabled;}
- (uint32_t)thresholdMB {return _policy.threshold_mb;}
- (uint32_t)intervalSeconds {return _policy.interval_seconds;}
- (BOOL)canClean {return !self.cleaning && (!_policy.has_attempt || uptimeMS()-_policy.last_attempt_ms>=5000);}
- (void)applyEnabled:(BOOL)enabled thresholdMB:(uint32_t)mb intervalSeconds:(uint32_t)seconds {
    if(!em_memory_settings_valid(mb,seconds))return;
    _policy.enabled=enabled;_policy.threshold_mb=mb;_policy.interval_seconds=seconds;
    _policy.started_ms=uptimeMS();
    [NSUserDefaults.standardUserDefaults setObject:@{@"enabled":@(enabled),@"thresholdMB":@(mb),@"intervalSeconds":@(seconds)} forKey:settingsKey];
}
- (void)memoryWarning:(NSNotification *)notification {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{[self memoryWarning:notification];});return;}
    if(em_memory_policy_due(&_policy,uptimeMS(),0,1))[self startCleanup:@"iOS báo thiếu bộ nhớ"];
}
- (void)tick {
    if(self.cleaning){
        EmMemoryCleanup state;em_memory_cleanup_status(&state);
        if(self.token && state.token==self.token && state.state>=EM_CLEANUP_DONE){[self finishCleanup:state];return;}
        if(uptimeMS()-self.requestedAt>=6000){
            state=(EmMemoryCleanup){0};state.state=EM_CLEANUP_TIMEOUT;[self finishCleanup:state];
        }
        return;
    }
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    if(!_policy.enabled || (!_policy.threshold_mb && !_policy.interval_seconds))return;
    int reason=em_memory_policy_due(&_policy,uptimeMS(),_policy.threshold_mb?EmAppMemoryBytes():0,0);
    if(reason)[self startCleanup:reason==EM_MEMORY_THRESHOLD?@"Vượt ngưỡng RAM app":@"Theo lịch"];
}
- (void)cleanNow {if(self.canClean)[self startCleanup:@"Dọn thủ công"];}
- (void)startCleanup:(NSString *)reason {
    if(self.cleaning)return;
    self.cleaning=YES;self.beforeBytes=EmAppMemoryBytes();self.requestedAt=uptimeMS();
    _policy.has_attempt=1;_policy.last_attempt_ms=self.requestedAt;
    self.resultText=@"Đang dọn bộ nhớ…";
    [[NSNotificationCenter defaultCenter] postNotificationName:EmMemoryWillCleanNotification object:self];
    self.token=em_memory_cleanup_request();
    fprintf(stdout,"[MEMORY] request reason=%s token=%llu app_before=%llu\n",reason.UTF8String,(unsigned long long)self.token,(unsigned long long)self.beforeBytes);fflush(stdout);
    if(!self.token){
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.25*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            EmMemoryCleanup state={0};state.state=EM_CLEANUP_UNAVAILABLE;[self finishCleanup:state];
        });
    }
}
- (void)finishCleanup:(EmMemoryCleanup)state {
    uint64_t after=EmAppMemoryBytes();
    NSString *result=state.state==EM_CLEANUP_DONE?@"Đã dọn xong.":
        state.state==EM_CLEANUP_UNAVAILABLE?@"Đã dọn bộ nhớ tạm.":@"Chưa nhận được kết quả. Hãy thử lại sau.";
    NSString *measurement=self.beforeBytes && after?[NSString stringWithFormat:@"RAM: %.1f → %.1f MB",self.beforeBytes/1048576.0,after/1048576.0]:@"Chưa đo được RAM.";
    self.resultText=[NSString stringWithFormat:@"%@\n%@",result,measurement];
    self.cleaning=NO;self.token=0;
    fprintf(stdout,"[MEMORY] result state=%d app_before=%llu app_after=%llu heap_before=%llu heap_after=%llu elapsed_ms=%llu\n",state.state,
        (unsigned long long)self.beforeBytes,(unsigned long long)after,(unsigned long long)state.heap_before,(unsigned long long)state.heap_after,(unsigned long long)state.elapsed_ms);fflush(stdout);
}
@end
