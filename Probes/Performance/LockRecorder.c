#include <stdint.h>
#include <time.h>
#include <pthread.h>
#include <stdlib.h>
#define LIMIT 1048576
static uint64_t values[4][LIMIT];
static uint64_t counts[4];
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
uint64_t performance_clock(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
// Called only after the shipping lock body returns. No allocation, callbacks or payload inspection.
void performance_lock_record(uint32_t kind,uint64_t start,uint64_t end) {
 pthread_mutex_lock(&mutex);
 uint64_t index=counts[kind]++;
 if(index<LIMIT) values[kind][index]=end-start;
 pthread_mutex_unlock(&mutex);
}
uint64_t performance_lock_count(uint32_t kind) { if(kind>=4) abort(); pthread_mutex_lock(&mutex); uint64_t result=counts[kind]; pthread_mutex_unlock(&mutex); return result; }
uint64_t performance_lock_sample(uint32_t kind,uint64_t index) {
 if(kind>=4) abort();
 pthread_mutex_lock(&mutex);
 if(index>=counts[kind] || index>=LIMIT) abort();
 uint64_t result=values[kind][index];
 pthread_mutex_unlock(&mutex);
 return result;
}
void performance_lock_reset(void) {
 pthread_mutex_lock(&mutex);
 for(unsigned i=0;i<4;i++) counts[i]=0;
 pthread_mutex_unlock(&mutex);
}
