#include <stdint.h>
typedef struct {
 uint64_t events, requested_bytes, live_blocks, live_requested_bytes;
 uint64_t peak_live_blocks, peak_live_requested_bytes, dropped_records;
} probe_stats;
void probe_begin(void);
void probe_snapshot(probe_stats *out);
void probe_end(void);
typedef struct {
 uint64_t blocks_in_use, size_in_use, size_allocated, max_size_in_use;
 uint64_t physical_footprint;
 int32_t task_info_result;
} probe_heap_stats;
void probe_heap_snapshot(probe_heap_stats *out);
// Scalar ABI for benchmark-only Swift declarations without a bridging header.
uint64_t probe_metric(uint32_t index);
void probe_heap_capture(void);
uint64_t probe_heap_metric(uint32_t index);
