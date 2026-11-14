/* Included after VmSock by the guarded miniJVM patch. Arrays stay rooted until
 * normal close or quiescent session cleanup. Never free an in-flight buffer. */
typedef struct EmSessionSocket {
    u64 owner;
    Instance *array;
    int ready, cancelled;
    struct EmSessionSocket *next;
} EmSessionSocket;
static once_flag em_io_once = ONCE_FLAG_INIT;
static mtx_t em_io_lock;
static EmSessionSocket *em_io_sockets;
static void em_io_init(void) { mtx_init(&em_io_lock, mtx_plain); }
static int microemu_io_track(Runtime *r, Instance *array) {
    if (!r->thrd_info->microemu_session) return 0;
    EmSessionSocket *node = calloc(1, sizeof(*node));
    if (!node) return -1;
    node->owner = r->thrd_info->microemu_session; node->array = array;
    gc_obj_hold(r->jvm->collector, array);
    call_once(&em_io_once, em_io_init);
    mtx_lock(&em_io_lock);
    node->next = em_io_sockets; em_io_sockets = node;
    mtx_unlock(&em_io_lock);
    return 0;
}
static void microemu_io_ready(Instance *array) {
    call_once(&em_io_once, em_io_init);
    mtx_lock(&em_io_lock);
    for (EmSessionSocket *n = em_io_sockets; n; n = n->next)
        if (n->array == array) { n->ready = 1; break; }
    mtx_unlock(&em_io_lock);
}
void microemu_io_cancel(u64 owner) {
    call_once(&em_io_once, em_io_init);
    mtx_lock(&em_io_lock);
    for (EmSessionSocket *n = em_io_sockets; n; n = n->next) {
        if (n->owner != owner || !n->ready || n->cancelled) continue;
        n->cancelled = 1;
        int fd = ((VmSock *)jarray_body(n->array))->contex.fd;
        /* shutdown wakes send/receive without freeing the context. connect/DNS
         * publishes ready only after returning, so no descriptor-reuse race. */
        if (fd >= 0) shutdown(fd, 2);
    }
    mtx_unlock(&em_io_lock);
}
static void microemu_io_close(MiniJVM *jvm, Instance *array) {
    call_once(&em_io_once, em_io_init);
    mtx_lock(&em_io_lock);
    EmSessionSocket **p = &em_io_sockets;
    while (*p && (*p)->array != array) p = &(*p)->next;
    EmSessionSocket *node = *p;
    if (node) *p = node->next;
    /* net_free sets fd=-1, including for a late Java finalizer. */
    mbedtls_net_free(&((VmSock *)jarray_body(array))->contex);
    mtx_unlock(&em_io_lock);
    if (node) { gc_obj_release(jvm->collector, array); free(node); }
}
int microemu_io_count(u64 owner) {
    call_once(&em_io_once, em_io_init);
    mtx_lock(&em_io_lock);
    int count = 0;
    for (EmSessionSocket *n = em_io_sockets; n; n = n->next) if (n->owner == owner) count++;
    mtx_unlock(&em_io_lock);
    return count;
}
void microemu_io_release(MiniJVM *jvm, u64 owner) {
    call_once(&em_io_once, em_io_init);
    for (;;) {
        mtx_lock(&em_io_lock);
        Instance *array = NULL;
        for (EmSessionSocket *n = em_io_sockets; n; n = n->next)
            if (!owner || n->owner == owner) { array = n->array; break; }
        mtx_unlock(&em_io_lock);
        if (!array) break;
        microemu_io_close(jvm, array);
    }
}
