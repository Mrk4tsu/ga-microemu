/* Bounded ZIP readers. Each handle belongs to its immutable game generation;
 * Stop releases abandoned readers only after that generation has quiesced. */
extern mz_bool gemu_zip_reader_open(mz_zip_archive *, const char *);
typedef struct EmArchiveReader {
    uint64_t id, owner, length, position;
    mz_zip_archive zip;
    mz_zip_reader_extract_iter_state *iterator;
    mz_uint index;
    int failed;
    struct EmArchiveReader *next;
} EmArchiveReader;
static EmArchiveReader *archive_readers;
static uint64_t next_archive_reader = 1;

static void archive_free(EmArchiveReader *reader) {
    if (reader->iterator) mz_zip_reader_extract_iter_free(reader->iterator);
    mz_zip_reader_end(&reader->zip);
    free(reader);
}
static EmArchiveReader *archive_find(uint64_t id) {
    for (EmArchiveReader *s=archive_readers;s;s=s->next) if(s->id==id)return s;
    return NULL;
}
static int archive_count(uint64_t owner) {
    int count=0;
    mtx_lock(&archive_lock);
    for(EmArchiveReader *s=archive_readers;s;s=s->next)if(s->owner==owner)count++;
    mtx_unlock(&archive_lock);
    return count;
}
static void archive_release(uint64_t owner, int all) {
    mtx_lock(&archive_lock);
    EmArchiveReader **link=&archive_readers;
    while(*link) {
        EmArchiveReader *s=*link;
        if(!all && s->owner!=owner) {link=&s->next;continue;}
        *link=s->next;archive_free(s);
    }
    mtx_unlock(&archive_lock);
}
static int archive_finish(EmArchiveReader *s) {
    if(!s->iterator)return !s->failed;
    unsigned char extra;
    size_t excess=mz_zip_reader_extract_iter_read(s->iterator,&extra,1);
    mz_bool valid=mz_zip_reader_extract_iter_free(s->iterator);s->iterator=NULL;
    if(excess || !valid)s->failed=1;
    return !s->failed;
}
static s32 archive_open_native(Runtime *r,JClass *c) {
    char *path=string_copy(r,localvar_getRefer(r->localvar,0));
    char *entry=string_copy(r,localvar_getRefer(r->localvar,1));
    EmArchiveReader *s=calloc(1,sizeof(*s));
    uint64_t id=0;
    jthread_block_enter(r);
    if(s && path && entry && gemu_zip_reader_open(&s->zip,path)) {
        int index=mz_zip_reader_locate_file(&s->zip,entry,NULL,MZ_ZIP_FLAG_CASE_SENSITIVE);
        if(index<0)index=mz_zip_reader_locate_file(&s->zip,entry,NULL,0);
        mz_zip_archive_file_stat stat;
        if(index>=0 && mz_zip_reader_file_stat(&s->zip,(mz_uint)index,&stat) && stat.m_uncomp_size<=INT64_MAX) {
            s->index=(mz_uint)index;s->length=stat.m_uncomp_size;
            s->iterator=mz_zip_reader_extract_iter_new(&s->zip,s->index,0);
            if(s->iterator) {
                mz_zip_clear_last_error(&s->zip);
                s->owner=r->thrd_info->microemu_session;
                mtx_lock(&archive_lock);
                id=s->id=next_archive_reader++;s->next=archive_readers;archive_readers=s;
                mtx_unlock(&archive_lock);
            }
        }
    }
    if(!id && s)archive_free(s);
    free(path);free(entry);
    jthread_block_exit(r);
    push_long(r->stack,(s64)id);
    return 0;
}
static s32 archive_read_native(Runtime *r,JClass *c) {
    uint64_t id=localvar_getLong(r->localvar,0);
    Instance *array=localvar_getRefer(r->localvar,2);
    int offset=localvar_getInt(r->localvar,3),length=localvar_getInt(r->localvar,4),result=-2;
    if(!array || offset<0 || length<0 || (int64_t)offset+length>jarray_length(array)) {push_int(r->stack,-2);return 0;}
    /* Never retain a movable Java array across a GC-blocking native region. */
    unsigned char buffer[16384];
    jthread_block_enter(r);
    mtx_lock(&archive_lock);
    EmArchiveReader *s=archive_find(id);
    if(s && !s->failed) {
        if(!length)result=0;
        else if(s->position==s->length)result=archive_finish(s)?-1:-2;
        else {
            size_t requested=(size_t)length;
            if(requested>sizeof(buffer))requested=sizeof(buffer);
            if(requested>s->length-s->position)requested=(size_t)(s->length-s->position);
            size_t count=mz_zip_reader_extract_iter_read(s->iterator,buffer,requested);
            s->position+=count;
            if(count && count<=requested && mz_zip_get_last_error(&s->zip)==MZ_ZIP_NO_ERROR) {
                result=(int)count;
                if(s->position==s->length && !archive_finish(s))result=-2;
            }
            if(result==-2)s->failed=1;
        }
    }
    mtx_unlock(&archive_lock);
    jthread_block_exit(r);
    if(result>0)memcpy((unsigned char *)jarray_body(localvar_getRefer(r->localvar,2))+offset,buffer,(size_t)result);
    push_int(r->stack,result);
    return 0;
}
static s32 archive_remaining_native(Runtime *r,JClass *c) {
    mtx_lock(&archive_lock);
    EmArchiveReader *s=archive_find(localvar_getLong(r->localvar,0));
    s64 value=s && !s->failed?(s64)(s->length-s->position):-1;
    mtx_unlock(&archive_lock);
    push_long(r->stack,value);return 0;
}
static s32 archive_rewind_native(Runtime *r,JClass *c) {
    jthread_block_enter(r);
    mtx_lock(&archive_lock);
    EmArchiveReader *s=archive_find(localvar_getLong(r->localvar,0));
    int ok=0;
    if(s) {
        if(s->iterator)mz_zip_reader_extract_iter_free(s->iterator);
        mz_zip_clear_last_error(&s->zip);
        s->iterator=mz_zip_reader_extract_iter_new(&s->zip,s->index,0);
        s->position=0;s->failed=!s->iterator;ok=!s->failed;
    }
    mtx_unlock(&archive_lock);
    jthread_block_exit(r);
    push_int(r->stack,ok);return 0;
}
static s32 archive_close_native(Runtime *r,JClass *c) {
    uint64_t id=localvar_getLong(r->localvar,0);
    jthread_block_enter(r);
    mtx_lock(&archive_lock);
    EmArchiveReader **link=&archive_readers;
    while(*link) {
        EmArchiveReader *s=*link;
        if(s->id==id) {*link=s->next;archive_free(s);break;}
        link=&s->next;
    }
    mtx_unlock(&archive_lock);
    jthread_block_exit(r);return 0;
}
static s32 archive_count_native(Runtime *r,JClass *c) {push_int(r->stack,archive_count(r->thrd_info->microemu_session));return 0;}
