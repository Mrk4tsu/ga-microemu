#ifndef EM_MEMORY_POLICY_H
#define EM_MEMORY_POLICY_H
#include <stdint.h>

enum { EM_MEMORY_NONE, EM_MEMORY_PRESSURE, EM_MEMORY_THRESHOLD, EM_MEMORY_INTERVAL };
typedef struct EmMemoryPolicy {
    int enabled, has_attempt;
    uint32_t threshold_mb, interval_seconds;
    uint64_t started_ms, last_attempt_ms;
} EmMemoryPolicy;
static inline int em_memory_settings_valid(uint32_t mb,uint32_t seconds) {
    return (mb==0 || (mb>=64 && mb<=32768)) && (seconds==0 || (seconds>=30 && seconds<=86400));
}
static inline int em_memory_policy_due(const EmMemoryPolicy *p,uint64_t now,uint64_t app_bytes,int pressure) {
    if(!p->enabled)return EM_MEMORY_NONE;
    if(p->has_attempt && (now<p->last_attempt_ms || now-p->last_attempt_ms<30000))return EM_MEMORY_NONE;
    if(pressure)return EM_MEMORY_PRESSURE;
    if(p->threshold_mb && app_bytes>=(uint64_t)p->threshold_mb*1024*1024)return EM_MEMORY_THRESHOLD;
    uint64_t origin=p->has_attempt?p->last_attempt_ms:p->started_ms;
    if(p->interval_seconds && now>=origin && now-origin>=(uint64_t)p->interval_seconds*1000)return EM_MEMORY_INTERVAL;
    return EM_MEMORY_NONE;
}
#endif
