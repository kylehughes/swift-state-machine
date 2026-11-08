#include "probe.h"
#include <stdlib.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <string.h>
#include <stdint.h>
#include <stdatomic.h>
#define CAP (1u << 20)
typedef struct { void *ptr; size_t size; } entry;
static entry entries[CAP];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static probe_stats stats;
static int enabled;
static pthread_key_t nesting_key;
static _Atomic int ready;
static int is_nested(void) { return !atomic_load(&ready) || pthread_getspecific(nesting_key)!=NULL; }
static void set_nested(int n) { if(pthread_setspecific(nesting_key,n ? (void*)1 : NULL)) abort(); }
static size_t index_of(void *ptr) { return (((uintptr_t)ptr >> 4) * 11400714819323198485ull) & (CAP-1); }
static void remove_record(void *ptr) {
 if (!ptr) return;
 size_t i=index_of(ptr);
 for(size_t n=0;n<CAP;n++,i=(i+1)&(CAP-1)) {
  if (!entries[i].ptr) return;
  if(entries[i].ptr==ptr) {
   stats.live_blocks--; stats.live_requested_bytes-=entries[i].size;
   entries[i].ptr=(void*)1; return;
  }
 }
}
static void add_record(void *ptr,size_t size) {
 if(!ptr) return;
 stats.events++; stats.requested_bytes+=size;
 size_t i=index_of(ptr);
 for(size_t n=0;n<CAP;n++,i=(i+1)&(CAP-1)) {
  if(entries[i].ptr==NULL || entries[i].ptr==(void*)1) {
   entries[i]=(entry){ptr,size}; stats.live_blocks++; stats.live_requested_bytes+=size;
   if(stats.live_blocks>stats.peak_live_blocks) stats.peak_live_blocks=stats.live_blocks;
   if(stats.live_requested_bytes>stats.peak_live_requested_bytes) stats.peak_live_requested_bytes=stats.live_requested_bytes;
   return;
  }
 }
 stats.dropped_records++;
}
static void note(void *old,void *ptr,size_t size,int is_realloc) {
 pthread_mutex_lock(&lock);
 if(enabled) {
  if(old && (!is_realloc || ptr)) remove_record(old);
  if(ptr) add_record(ptr,size);
 }
 pthread_mutex_unlock(&lock);
}
void probe_begin(void) {
 if(!atomic_load(&ready)) { if(pthread_key_create(&nesting_key,NULL)) abort(); atomic_store(&ready,1); }
 pthread_mutex_lock(&lock); enabled=0; memset(entries,0,sizeof entries); memset(&stats,0,sizeof stats); enabled=1; pthread_mutex_unlock(&lock);
}
void probe_snapshot(probe_stats *out) { pthread_mutex_lock(&lock); *out=stats; pthread_mutex_unlock(&lock); }
void probe_end(void) { pthread_mutex_lock(&lock); enabled=0; pthread_mutex_unlock(&lock); }
#define INTERPOSE(replacement,replacee) __attribute__((used)) static struct { const void *replacement; const void *replacee; } ip_##replacee __attribute__((section("__DATA,__interpose"))) = { (const void*)&replacement,(const void*)&replacee };
__attribute__((noinline)) static void *p_malloc(size_t n) { if(is_nested()) return malloc(n); set_nested(1); void *p=malloc(n); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_malloc,malloc)
__attribute__((noinline)) static void *p_malloc_type_malloc(size_t n,malloc_type_id_t t) { if(is_nested()) return malloc_type_malloc(n,t); set_nested(1); void *p=malloc_type_malloc(n,t); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_malloc_type_malloc,malloc_type_malloc)
__attribute__((noinline)) static void *p_calloc(size_t n,size_t s) { if(is_nested()) return calloc(n,s); set_nested(1); void *p=calloc(n,s); note(NULL,p,n*s,0); set_nested(0); return p; }
INTERPOSE(p_calloc,calloc)
__attribute__((noinline)) static void *p_malloc_type_calloc(size_t n,size_t s,malloc_type_id_t t) { if(is_nested()) return malloc_type_calloc(n,s,t); set_nested(1); void *p=malloc_type_calloc(n,s,t); note(NULL,p,n*s,0); set_nested(0); return p; }
INTERPOSE(p_malloc_type_calloc,malloc_type_calloc)
__attribute__((noinline)) static void *p_valloc(size_t n) { if(is_nested()) return valloc(n); set_nested(1); void *p=valloc(n); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_valloc,valloc)
__attribute__((noinline)) static void *p_malloc_type_valloc(size_t n,malloc_type_id_t t) { if(is_nested()) return malloc_type_valloc(n,t); set_nested(1); void *p=malloc_type_valloc(n,t); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_malloc_type_valloc,malloc_type_valloc)
__attribute__((noinline)) static void *p_aligned_alloc(size_t a,size_t n) { if(is_nested()) return aligned_alloc(a,n); set_nested(1); void *p=aligned_alloc(a,n); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_aligned_alloc,aligned_alloc)
__attribute__((noinline)) static void *p_malloc_type_aligned_alloc(size_t a,size_t n,malloc_type_id_t t) { if(is_nested()) return malloc_type_aligned_alloc(a,n,t); set_nested(1); void *p=malloc_type_aligned_alloc(a,n,t); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_malloc_type_aligned_alloc,malloc_type_aligned_alloc)
__attribute__((noinline)) static void *p_malloc_zone_malloc(malloc_zone_t *z,size_t n) { if(is_nested()) return malloc_zone_malloc(z,n); set_nested(1); void *p=malloc_zone_malloc(z,n); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_malloc_zone_malloc,malloc_zone_malloc)
__attribute__((noinline)) static void *p_malloc_type_zone_malloc(malloc_zone_t *z,size_t n,malloc_type_id_t t) { if(is_nested()) return malloc_type_zone_malloc(z,n,t); set_nested(1); void *p=malloc_type_zone_malloc(z,n,t); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_malloc_type_zone_malloc,malloc_type_zone_malloc)
__attribute__((noinline)) static void *p_malloc_zone_calloc(malloc_zone_t *z,size_t n,size_t s) { if(is_nested()) return malloc_zone_calloc(z,n,s); set_nested(1); void *p=malloc_zone_calloc(z,n,s); note(NULL,p,n*s,0); set_nested(0); return p; }
INTERPOSE(p_malloc_zone_calloc,malloc_zone_calloc)
__attribute__((noinline)) static void *p_malloc_type_zone_calloc(malloc_zone_t *z,size_t n,size_t s,malloc_type_id_t t) { if(is_nested()) return malloc_type_zone_calloc(z,n,s,t); set_nested(1); void *p=malloc_type_zone_calloc(z,n,s,t); note(NULL,p,n*s,0); set_nested(0); return p; }
INTERPOSE(p_malloc_type_zone_calloc,malloc_type_zone_calloc)
__attribute__((noinline)) static void *p_malloc_zone_valloc(malloc_zone_t *z,size_t n) { if(is_nested()) return malloc_zone_valloc(z,n); set_nested(1); void *p=malloc_zone_valloc(z,n); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_malloc_zone_valloc,malloc_zone_valloc)
__attribute__((noinline)) static void *p_malloc_type_zone_valloc(malloc_zone_t *z,size_t n,malloc_type_id_t t) { if(is_nested()) return malloc_type_zone_valloc(z,n,t); set_nested(1); void *p=malloc_type_zone_valloc(z,n,t); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_malloc_type_zone_valloc,malloc_type_zone_valloc)
__attribute__((noinline)) static void *p_malloc_zone_memalign(malloc_zone_t *z,size_t a,size_t n) { if(is_nested()) return malloc_zone_memalign(z,a,n); set_nested(1); void *p=malloc_zone_memalign(z,a,n); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_malloc_zone_memalign,malloc_zone_memalign)
__attribute__((noinline)) static void *p_malloc_type_zone_memalign(malloc_zone_t *z,size_t a,size_t n,malloc_type_id_t t) { if(is_nested()) return malloc_type_zone_memalign(z,a,n,t); set_nested(1); void *p=malloc_type_zone_memalign(z,a,n,t); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_malloc_type_zone_memalign,malloc_type_zone_memalign)
__attribute__((noinline)) static void *p_malloc_zone_malloc_with_options(malloc_zone_t *z,size_t a,size_t n,malloc_zone_malloc_options_t o) { if(is_nested()) return malloc_zone_malloc_with_options(z,a,n,o); set_nested(1); void *p=malloc_zone_malloc_with_options(z,a,n,o); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_malloc_zone_malloc_with_options,malloc_zone_malloc_with_options)
__attribute__((noinline)) static void *p_malloc_type_zone_malloc_with_options(malloc_zone_t *z,size_t a,size_t n,malloc_type_id_t t,malloc_zone_malloc_options_t o) { if(is_nested()) return malloc_type_zone_malloc_with_options(z,a,n,t,o); set_nested(1); void *p=malloc_type_zone_malloc_with_options(z,a,n,t,o); note(NULL,p,n,0); set_nested(0); return p; }
INTERPOSE(p_malloc_type_zone_malloc_with_options,malloc_type_zone_malloc_with_options)
static void p_free(void *p) { if(is_nested()) { free(p); return; } set_nested(1); note(p,NULL,0,0); free(p); set_nested(0); }
INTERPOSE(p_free,free)
static void p_malloc_zone_free(malloc_zone_t *z,void *p) { if(is_nested()) { malloc_zone_free(z,p); return; } set_nested(1); note(p,NULL,0,0); malloc_zone_free(z,p); set_nested(0); }
INTERPOSE(p_malloc_zone_free,malloc_zone_free)
static void p_malloc_type_free(void *p,malloc_type_id_t t) { if(is_nested()) { malloc_type_free(p,t); return; } set_nested(1); note(p,NULL,0,0); malloc_type_free(p,t); set_nested(0); }
INTERPOSE(p_malloc_type_free,malloc_type_free)
static void p_malloc_type_zone_free(malloc_zone_t *z,void *p,malloc_type_id_t t) { if(is_nested()) { malloc_type_zone_free(z,p,t); return; } set_nested(1); note(p,NULL,0,0); malloc_type_zone_free(z,p,t); set_nested(0); }
INTERPOSE(p_malloc_type_zone_free,malloc_type_zone_free)
static void *p_realloc(void *p,size_t n) { if(is_nested()) return realloc(p,n); set_nested(1); pthread_mutex_lock(&lock); void *q=realloc(p,n); if(enabled && q) { remove_record(p); add_record(q,n); } pthread_mutex_unlock(&lock); set_nested(0); return q; }
INTERPOSE(p_realloc,realloc)
static void *p_malloc_zone_realloc(malloc_zone_t *z,void *p,size_t n) { if(is_nested()) return malloc_zone_realloc(z,p,n); set_nested(1); pthread_mutex_lock(&lock); void *q=malloc_zone_realloc(z,p,n); if(enabled && q) { remove_record(p); add_record(q,n); } pthread_mutex_unlock(&lock); set_nested(0); return q; }
INTERPOSE(p_malloc_zone_realloc,malloc_zone_realloc)
static void *p_malloc_type_realloc(void *p,size_t n,malloc_type_id_t t) { if(is_nested()) return malloc_type_realloc(p,n,t); set_nested(1); pthread_mutex_lock(&lock); void *q=malloc_type_realloc(p,n,t); if(enabled && q) { remove_record(p); add_record(q,n); } pthread_mutex_unlock(&lock); set_nested(0); return q; }
INTERPOSE(p_malloc_type_realloc,malloc_type_realloc)
static void *p_malloc_type_zone_realloc(malloc_zone_t *z,void *p,size_t n,malloc_type_id_t t) { if(is_nested()) return malloc_type_zone_realloc(z,p,n,t); set_nested(1); pthread_mutex_lock(&lock); void *q=malloc_type_zone_realloc(z,p,n,t); if(enabled && q) { remove_record(p); add_record(q,n); } pthread_mutex_unlock(&lock); set_nested(0); return q; }
INTERPOSE(p_malloc_type_zone_realloc,malloc_type_zone_realloc)
static int p_posix_memalign(void **p,size_t a,size_t n) { if(is_nested()) return posix_memalign(p,a,n); set_nested(1); int r=posix_memalign(p,a,n); if(!r) note(NULL,*p,n,0); set_nested(0); return r; }
INTERPOSE(p_posix_memalign,posix_memalign)
static int p_malloc_type_posix_memalign(void **p,size_t a,size_t n,malloc_type_id_t t) { if(is_nested()) return malloc_type_posix_memalign(p,a,n,t); set_nested(1); int r=malloc_type_posix_memalign(p,a,n,t); if(!r) note(NULL,*p,n,0); set_nested(0); return r; }
INTERPOSE(p_malloc_type_posix_memalign,malloc_type_posix_memalign)

#include <mach/mach.h>
void probe_heap_snapshot(probe_heap_stats *out) {
 malloc_statistics_t heap;
 malloc_zone_statistics(NULL,&heap);
 task_vm_info_data_t vm={0};
 mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
 kern_return_t result=task_info(mach_task_self(),TASK_VM_INFO,(task_info_t)&vm,&count);
 *out=(probe_heap_stats){heap.blocks_in_use,heap.size_in_use,heap.size_allocated,heap.max_size_in_use,result==KERN_SUCCESS ? vm.phys_footprint : 0,result};
}

uint64_t probe_metric(uint32_t index) {
 probe_stats s; probe_snapshot(&s);
 switch(index) {
  case 0:return s.events; case 1:return s.requested_bytes;
  case 2:return s.live_blocks; case 3:return s.live_requested_bytes;
  case 4:return s.peak_live_blocks; case 5:return s.peak_live_requested_bytes;
  case 6:return s.dropped_records; default:abort();
 }
}
static probe_heap_stats captured_heap;
void probe_heap_capture(void) { probe_heap_snapshot(&captured_heap); }
uint64_t probe_heap_metric(uint32_t index) {
 switch(index) {
  case 0:return captured_heap.blocks_in_use; case 1:return captured_heap.size_in_use;
  case 2:return captured_heap.size_allocated; case 3:return captured_heap.max_size_in_use;
  case 4:return captured_heap.physical_footprint; case 5:return captured_heap.task_info_result;
  default:abort();
 }
}
