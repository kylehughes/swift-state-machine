import StateMachine
import Darwin
import Foundation

@main
nonisolated enum PerformanceMain {
    static func main() async throws {
        #if PERFORMANCE_LOCK_INSTRUMENTED
        // Verify all three real copied primitive paths before resetting their measured samples.
        do {
            let primitive = AtomicRecordStorage(0)
            let initial = primitive.load()
            try require(primitive.isCurrent(initial), "Copied primitive current check failed")
            let next = AtomicRecordStorage<Int>.Version(1)
            try require(primitive.install(next, replacing: initial), "Copied primitive install failed")
            try require(!primitive.isCurrent(initial), "Copied primitive stale check failed")
            try require(!primitive.install(.init(2), replacing: initial), "Copied primitive stale install accepted")
            try require(primitive.load().value == 1, "Copied primitive retained wrong value")
        }
        #endif
        let args = CommandLine.arguments
        func argument(_ name: String, _ fallback: String) -> String {
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return fallback }
            return args[index + 1]
        }
        let workload = argument("--workload", "pt001")
        let bytes = Int(argument("--bytes", "64"))!
        let operations = Int(argument("--operations", "100"))!
        let repetitions = Int(argument("--repetitions", "1"))!
        let writers = Int(argument("--writers", "1"))!
        let readers = Int(argument("--readers", "1"))!
        let allocation = args.contains("--allocations")
        let measuringLatency =
            !allocation && !args.contains("--instrumented") && !args.contains("--resource-instrumented")
        let probe = try allocation ? AllocatorProbe() : nil
        if let probe {
            probe.begin()
            probe.end()
        }
        func execute(timing: Bool, probe: AllocatorProbe?) async throws -> ResultRow {
            switch workload {
            case "pt001":
                return try await uncontended(bytes: bytes, operations: operations, timing: timing, probe: probe)
            case "pt001-local":
                return try uncontendedLocal(bytes: bytes, operations: operations, timing: timing, probe: probe)
            case "pt002":
                return try await concurrent(
                    bytes: bytes,
                    operations: operations,
                    writers: writers,
                    readers: readers,
                    timing: timing,
                    probe: probe
                )
            case "pt003": return try await pressure(bytes: bytes, operations: operations, timing: timing, probe: probe)
            case "pt004": return try await lifecycle(bytes: bytes, operations: operations, timing: timing, probe: probe)
            default: throw Failure(description: "Unknown workload")
            }
        }
        // The same process runs a full-size validated warmup, then its measured repetitions.
        // Each iteration owns and tears down a fresh owner. JSON encoding stays outside measurement windows.
        for iteration in -1 ..< repetitions {
            #if PERFORMANCE_LOCK_INSTRUMENTED
            typealias Action = @convention(c) () -> Void
            let process = dlopen(nil, RTLD_NOW)!
            let reset = unsafeBitCast(dlsym(process, "performance_lock_reset")!, to: Action.self)
            reset()
            _performanceCalibrateClock()
            #endif
            if iteration >= 0, let probe {
                probe.begin()
                probe.end()
            }
            let baseline = iteration >= 0 ? probe?.snapshot() : nil
            if iteration >= 0 { probe?.begin() }
            var row = try await execute(timing: measuringLatency && iteration >= 0, probe: iteration >= 0 ? probe : nil)
            if iteration >= 0, let probe {
                let after = probe.snapshot()
                probe.end()
                try require(
                    after.droppedRecords == 0 && after.taskInfoResult == 0,
                    "Allocation records dropped or physical-footprint query failed"
                )
                row.memory["baseline"] = baseline
                row.memory["afterWorkloadTeardown"] = after
                row.notes.append(
                    "Allocation-only process with latency samples disabled. The measurement window includes control bookkeeping and ResultRow storage, so compare held and released checkpoints alongside process heap data rather than window-live counts alone. Entry counts cover the listed allocator entrypoints rather than every possible process allocation."
                )
            }
            if args.contains("--instrumented") {
                typealias Count = @convention(c) (UInt32) -> UInt64
                typealias Sample = @convention(c) (UInt32, UInt64) -> UInt64
                let handle = dlopen(nil, RTLD_NOW)!
                let count = unsafeBitCast(dlsym(handle, "performance_lock_count")!, to: Count.self)
                let sample = unsafeBitCast(dlsym(handle, "performance_lock_sample")!, to: Sample.self)
                for (kind, name) in ["load", "isCurrent", "install", "clockCalibration"].enumerated() {
                    let total = count(UInt32(kind))
                    try require(total <= 1_048_576, "Critical-section sample capacity exceeded")
                    row.lockBodyNanoseconds[name] = (0 ..< total).map { sample(UInt32(kind), $0) }
                }
                row.notes.append(
                    "Separate hash-matched nonshipping core. Lock-body timestamps exclude acquisition and unlock. C clock calls and timestamp return values perturb the body, and clockCalibration records paired reads. The recorder runs after unlocking. These are not shipping latency samples."
                )
            }
            #if PERFORMANCE_LOCK_INSTRUMENTED
            row.counts["primitiveFunctionalControlPassed"] = 1
            #endif
            row.counts["warmup"] = iteration == -1 ? 1 : 0
            row.counts["repetition"] = iteration
            row.counts["modelValueInlineBytes"] = MemoryLayout<PerformanceFlow.Ready>.size
            row.counts["snapshotValueInlineBytes"] = MemoryLayout<PerformanceFlow.Snapshot>.size
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(row)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([10]))
        }
    }
}
