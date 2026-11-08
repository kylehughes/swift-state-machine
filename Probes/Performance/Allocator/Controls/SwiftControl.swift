import Dispatch
import Foundation

final class Box: Sendable {
    let value: UInt64
    init(_ value: UInt64) { self.value = value }
}

// Fixed C-owned slots isolate the class allocations from collection growth.
@_silgen_name("control_store") func store(_ index: Int, _ value: UnsafeMutableRawPointer)
@_silgen_name("control_release") func releaseAll()

@inline(never) func allocate(_ start: Int, _ end: Int) {
    for i in start ..< end {
        let value = Box(UInt64(i))
        store(i, Unmanaged.passRetained(value).toOpaque())
    }
}
func report(_ phase: String, _ value: probe_stats) {
    print(
        "\(phase) events=\(value.events) bytes=\(value.requested_bytes) live=\(value.live_blocks) live_bytes=\(value.live_requested_bytes) peak=\(value.peak_live_blocks) dropped=\(value.dropped_records)"
    )
}
allocate(0, 40000)
releaseAll()
DispatchQueue.concurrentPerform(iterations: 4) { i in allocate(i * 10000, (i + 1) * 10000) }
releaseAll()
var baselineHeap = probe_heap_stats()
var heldHeap = probe_heap_stats()
var doneHeap = probe_heap_stats()
probe_begin()
probe_end()
probe_heap_snapshot(&baselineHeap)
var held = probe_stats()
var done = probe_stats()
probe_begin()
allocate(0, 10000)
probe_heap_snapshot(&heldHeap)
probe_snapshot(&held)
releaseAll()
probe_snapshot(&done)
probe_end()
probe_heap_snapshot(&doneHeap)
report("swift-serial-held", held)
report("swift-serial-teardown", done)
print(
    "swift-heap baseline blocks=\(baselineHeap.blocks_in_use) bytes=\(baselineHeap.size_in_use) reserved=\(baselineHeap.size_allocated) footprint=\(baselineHeap.physical_footprint); held blocks=\(heldHeap.blocks_in_use) bytes=\(heldHeap.size_in_use); teardown blocks=\(doneHeap.blocks_in_use) bytes=\(doneHeap.size_in_use) reserved=\(doneHeap.size_allocated) footprint=\(doneHeap.physical_footprint) task_info=\(doneHeap.task_info_result)"
)
probe_begin()
DispatchQueue.concurrentPerform(iterations: 4) { i in allocate(i * 10000, (i + 1) * 10000) }
probe_snapshot(&held)
releaseAll()
probe_snapshot(&done)
probe_end()
report("swift-concurrent-held", held)
report("swift-concurrent-teardown", done)
