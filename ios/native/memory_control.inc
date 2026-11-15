/* Polled only by the host Runtime. UI threads exchange values under memory_lock,
 * never dereference a VM or run collection/finalizers themselves. */
static EmMemoryCleanup memory_cleanup;
static int memory_runtime_available;
static s64 memory_target_generation, memory_started_ms;

static void memory_runtime_state(int available) {
    mtx_lock(&memory_lock);
    memory_runtime_available=available;
    if(memory_cleanup.state==EM_CLEANUP_QUEUED || memory_cleanup.state==EM_CLEANUP_RUNNING)
        memory_cleanup.state=EM_CLEANUP_UNAVAILABLE;
    mtx_unlock(&memory_lock);
}
uint64_t em_memory_cleanup_request(void) {
    call_once(&initialized,initialize);
    mtx_lock(&memory_lock);
    uint64_t token=0;
    if(memory_runtime_available){
        if(memory_cleanup.state!=EM_CLEANUP_QUEUED && memory_cleanup.state!=EM_CLEANUP_RUNNING){
            memory_cleanup.token++;memory_cleanup.state=EM_CLEANUP_QUEUED;
            memory_cleanup.heap_before=memory_cleanup.heap_after=memory_cleanup.elapsed_ms=0;
        }
        token=memory_cleanup.token;
    }
    mtx_unlock(&memory_lock);return token;
}
void em_memory_cleanup_status(EmMemoryCleanup *status) {
    if(!status)return;
    call_once(&initialized,initialize);
    mtx_lock(&memory_lock);*status=memory_cleanup;mtx_unlock(&memory_lock);
}
static uint64_t memory_heap_bytes(GcCollector *collector) {
    if(collector->immix_heap){
        ImmixStats stats;immix_get_stats(collector->immix_heap,&stats);return stats.live_bytes;
    }
    spin_lock(&collector->lock);s64 bytes=collector->obj_heap_size;spin_unlock(&collector->lock);
    return bytes>0?(uint64_t)bytes:0;
}
static void memory_control_poll(Runtime *runtime) {
    if(runtime->thrd_info->microemu_session)return;
    EmMemoryCleanup snapshot;em_memory_cleanup_status(&snapshot);
    GcCollector *collector=runtime->jvm->collector;
    if(snapshot.state==EM_CLEANUP_QUEUED){
        uint64_t before=memory_heap_bytes(collector);
        memory_started_ms=nanoTime()/1000000;
        // Same asynchronous request protocol as this pinned runtime's allocator.
        // Preserve an existing heap-limit request and its requested-byte budget.
        spin_lock(&collector->lock);
        memory_target_generation=collector->gc_gen+1;
        if(!collector->gc_request){
            collector->gc_request=1;
            if(collector->gc_request_reason!=IMMIX_GC_HEAP_LIMIT)
                collector->gc_request_reason=IMMIX_GC_EXPLICIT;
        }
        spin_unlock(&collector->lock);
        mtx_lock(&memory_lock);
        memory_cleanup.heap_before=before;memory_cleanup.state=EM_CLEANUP_RUNNING;
        mtx_unlock(&memory_lock);
        gc_wakeup_notify(&collector->wakeup);
    }else if(snapshot.state==EM_CLEANUP_RUNNING){
        spin_lock(&collector->lock);s64 generation=collector->gc_gen;spin_unlock(&collector->lock);
        s64 elapsed=nanoTime()/1000000-memory_started_ms;
        if(generation>=memory_target_generation || elapsed>=5000){
            uint64_t after=memory_heap_bytes(collector);
            mtx_lock(&memory_lock);
            memory_cleanup.heap_after=after;memory_cleanup.elapsed_ms=elapsed>0?(uint64_t)elapsed:0;
            memory_cleanup.state=generation>=memory_target_generation?EM_CLEANUP_DONE:EM_CLEANUP_TIMEOUT;
            mtx_unlock(&memory_lock);
        }
    }
}
