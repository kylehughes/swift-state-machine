#include "probe.h"
#include <stdlib.h>
#include <stdio.h>
#include <malloc/malloc.h>
#include <pthread.h>
#include <stdint.h>
static void *items[40000];
static void *worker(void *arg) {
 size_t first=(uintptr_t)arg*10000;
 for(size_t i=first;i<first+10000;i++) {items[i]=malloc(64); ((volatile char*)items[i])[0]=1;}
 return NULL;
}
static void report(const char *phase,probe_stats s) {
 printf("%s events=%llu bytes=%llu live=%llu live_bytes=%llu peak=%llu dropped=%llu\n",phase,s.events,s.requested_bytes,s.live_blocks,s.live_requested_bytes,s.peak_live_blocks,s.dropped_records);
}
int main(void) {
 // Warm pthread creation outside measurement. Synchronization bookkeeping remains visible in the concurrent result.
 pthread_t threads[4];
 for(size_t i=0;i<4;i++) pthread_create(&threads[i],NULL,worker,(void*)i);
 for(size_t i=0;i<4;i++) pthread_join(threads[i],NULL);
 for(size_t i=0;i<40000;i++) free(items[i]);
 probe_stats held,done;
 probe_heap_stats baseline,heap_held,heap_done;
 probe_begin(); probe_end(); // Touch bookkeeping storage before physical-memory baseline.
 probe_heap_snapshot(&baseline);
 probe_begin(); worker(0); probe_snapshot(&held); probe_heap_snapshot(&heap_held);
 for(size_t i=0;i<10000;i++) free(items[i]);
 probe_snapshot(&done); probe_end(); probe_heap_snapshot(&heap_done); report("serial-held",held); report("serial-teardown",done);
 printf("heap baseline blocks=%llu bytes=%llu reserved=%llu footprint=%llu; held blocks=%llu bytes=%llu; teardown blocks=%llu bytes=%llu reserved=%llu footprint=%llu task_info=%d\n",baseline.blocks_in_use,baseline.size_in_use,baseline.size_allocated,baseline.physical_footprint,heap_held.blocks_in_use,heap_held.size_in_use,heap_done.blocks_in_use,heap_done.size_in_use,heap_done.size_allocated,heap_done.physical_footprint,heap_done.task_info_result);
 probe_begin();
 for(size_t i=0;i<4;i++) pthread_create(&threads[i],NULL,worker,(void*)i);
 for(size_t i=0;i<4;i++) pthread_join(threads[i],NULL);
 probe_snapshot(&held);
 for(size_t i=0;i<40000;i++) free(items[i]);
 probe_snapshot(&done); probe_end(); report("concurrent-held",held); report("concurrent-teardown",done);
 return 0;
}
