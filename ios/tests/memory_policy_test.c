#include "memory_policy.h"
#include <stdio.h>
#include <stdlib.h>
#define CHECK(test) do { if(!(test)){fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#test);exit(1);} } while(0)
int main(void) {
    CHECK(em_memory_settings_valid(0,0));CHECK(em_memory_settings_valid(64,30));CHECK(em_memory_settings_valid(32768,86400));
    CHECK(!em_memory_settings_valid(63,60));CHECK(!em_memory_settings_valid(32769,0));
    CHECK(!em_memory_settings_valid(0,29));CHECK(!em_memory_settings_valid(0,86401));
    EmMemoryPolicy p={0};p.started_ms=1000;
    CHECK(!em_memory_policy_due(&p,999999,UINT64_MAX,1));
    p.enabled=1;CHECK(!em_memory_policy_due(&p,999999,UINT64_MAX,0)); // default: warnings only
    CHECK(em_memory_policy_due(&p,1000,0,1)==EM_MEMORY_PRESSURE);
    p.threshold_mb=128;CHECK(!em_memory_policy_due(&p,1000,128ULL*1024*1024-1,0));
    CHECK(em_memory_policy_due(&p,1000,128ULL*1024*1024,0)==EM_MEMORY_THRESHOLD);
    p.has_attempt=1;p.last_attempt_ms=1000;
    CHECK(!em_memory_policy_due(&p,30999,UINT64_MAX,1)); // even warning floods are throttled
    CHECK(em_memory_policy_due(&p,31000,UINT64_MAX,1)==EM_MEMORY_PRESSURE);
    CHECK(!em_memory_policy_due(&p,500,UINT64_MAX,1)); // clock moves backwards
    p.threshold_mb=0;p.interval_seconds=60;
    CHECK(!em_memory_policy_due(&p,60999,0,0));CHECK(em_memory_policy_due(&p,61000,0,0)==EM_MEMORY_INTERVAL);
    p.has_attempt=0;CHECK(em_memory_policy_due(&p,61000,0,0)==EM_MEMORY_INTERVAL);
    p.threshold_mb=32768;CHECK(em_memory_policy_due(&p,61000,32768ULL*1024*1024,0)==EM_MEMORY_THRESHOLD);
    puts("PASS: memory settings, opt-in triggers, threshold boundaries and 30-second cooldown");return 0;
}
