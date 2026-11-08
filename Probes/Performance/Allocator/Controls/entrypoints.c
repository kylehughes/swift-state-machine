#include "probe.h"
#include <stdlib.h>
#include <stdio.h>
#include <malloc/malloc.h>
static void *p[10];
int main(void) {
 malloc_zone_t *z=malloc_default_zone();
 probe_stats empty,held,done;
 probe_begin(); probe_snapshot(&empty); probe_end();
 probe_begin();
 p[0]=malloc(64); p[1]=calloc(2,32); p[2]=valloc(64); p[3]=aligned_alloc(64,64);
 if(posix_memalign(&p[4],64,64)) abort();
 p[5]=malloc_zone_malloc(z,64); p[6]=malloc_zone_calloc(z,2,32); p[7]=malloc_zone_valloc(z,64);
 p[8]=malloc_zone_memalign(z,64,64);
 p[9]=malloc_zone_malloc_with_options(z,64,64,MALLOC_ZONE_MALLOC_OPTION_NONE);
 p[0]=realloc(p[0],128); p[5]=malloc_zone_realloc(z,p[5],128);
 for(int i=0;i<10;i++) ((volatile char*)p[i])[0]=42;
 probe_snapshot(&held);
 for(int i=0;i<5;i++) free(p[i]);
 for(int i=5;i<10;i++) malloc_zone_free(z,p[i]);
 probe_snapshot(&done); probe_end();
 printf("empty events=%llu bytes=%llu live=%llu\n",empty.events,empty.requested_bytes,empty.live_blocks);
 printf("entrypoints-held events=%llu bytes=%llu live=%llu live_bytes=%llu dropped=%llu\n",held.events,held.requested_bytes,held.live_blocks,held.live_requested_bytes,held.dropped_records);
 printf("entrypoints-teardown events=%llu bytes=%llu live=%llu live_bytes=%llu dropped=%llu\n",done.events,done.requested_bytes,done.live_blocks,done.live_requested_bytes,done.dropped_records);
 return !(empty.events==0 && held.events==12 && held.requested_bytes==896 && held.live_blocks==10 && held.live_requested_bytes==768 && done.live_blocks==0 && done.live_requested_bytes==0 && done.dropped_records==0);
}
