import StateMachine
import Darwin
import Dispatch
import Foundation
import os

struct Failure: Error, CustomStringConvertible { let description: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(description: message) }
}
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func value(_ snapshot: PerformanceFlow.Snapshot) -> PerformanceFlow.Ready {
    switch snapshot {
    case .ready(let observed): return observed.value
    }
}

/// One producer event and one waiter; signaling is the progress proof, process timeout is the safety bound.
final class Event: Sendable {
    private struct State {
        var fired = false
        var waiter: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func signal() {
        let waiter = state.withLock { s -> CheckedContinuation<Void, Never>? in
            s.fired = true
            let waiter = s.waiter
            s.waiter = nil
            return waiter
        }
        waiter?.resume()
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let immediate = state.withLock { s in
                if s.fired { return true }
                precondition(s.waiter == nil)
                s.waiter = continuation
                return false
            }
            if immediate { continuation.resume() }
        }
    }
}

actor DriverGate {
    private var open = false
    private var permits: [CheckedContinuation<Void, Never>] = []
    private var starts: [Int] = []
    private var finishes: [Int] = []
    private var cancelled = 0
    private var startWaiter: (Int, CheckedContinuation<Void, Never>)?
    func run(_ id: Int) async -> Result<Int, Never> {
        starts.append(id)
        if let waiter = startWaiter, starts.count >= waiter.0 {
            startWaiter = nil
            waiter.1.resume()
        }
        if !open { await withCheckedContinuation { permits.append($0) } }
        finishes.append(id)
        if Task.isCancelled { cancelled += 1 }
        return .success(id)
    }
    func waitForStarts(_ count: Int) async {
        if starts.count >= count { return }
        await withCheckedContinuation { startWaiter = (count, $0) }
    }
    func release() {
        open = true
        let previous = permits
        permits = []
        for permit in previous { permit.resume() }
    }
    func counts() -> (starts: [Int], finishes: [Int], cancelled: Int) { (starts, finishes, cancelled) }
}

struct Memory: Codable, Sendable {
    var events: UInt64 = 0
    var requestedBytes: UInt64 = 0
    var liveBlocks: UInt64 = 0
    var liveRequestedBytes: UInt64 = 0
    var peakLiveBlocks: UInt64 = 0
    var peakLiveRequestedBytes: UInt64 = 0
    var droppedRecords: UInt64 = 0
    var heapBlocks: UInt64 = 0
    var heapBytes: UInt64 = 0
    var heapReservedBytes: UInt64 = 0
    var heapHighWaterBytes: UInt64 = 0
    var physicalFootprint: UInt64 = 0
    var taskInfoResult: UInt64 = 0
}
struct AllocatorProbe: Sendable {
    typealias Action = @convention(c) () -> Void
    typealias Metric = @convention(c) (UInt32) -> UInt64
    let begin: Action
    let end: Action
    let metric: Metric
    let captureHeap: Action
    let heapMetric: Metric
    init() throws {
        guard let handle = dlopen(nil, RTLD_NOW) else { throw Failure(description: "dlopen process failed") }
        func load<T>(_ name: String, _ type: T.Type) throws -> T {
            guard let symbol = dlsym(handle, name) else {
                throw Failure(description: "Missing allocation probe: \(name)")
            }
            return unsafeBitCast(symbol, to: type)
        }
        begin = try load("probe_begin", Action.self)
        end = try load("probe_end", Action.self)
        metric = try load("probe_metric", Metric.self)
        captureHeap = try load("probe_heap_capture", Action.self)
        heapMetric = try load("probe_heap_metric", Metric.self)
    }
    func snapshot() -> Memory {
        captureHeap()
        return Memory(
            events: metric(0),
            requestedBytes: metric(1),
            liveBlocks: metric(2),
            liveRequestedBytes: metric(3),
            peakLiveBlocks: metric(4),
            peakLiveRequestedBytes: metric(5),
            droppedRecords: metric(6),
            heapBlocks: heapMetric(0),
            heapBytes: heapMetric(1),
            heapReservedBytes: heapMetric(2),
            heapHighWaterBytes: heapMetric(3),
            physicalFootprint: heapMetric(4),
            taskInfoResult: heapMetric(5)
        )
    }
}

struct Participant: Codable, Sendable {
    var role: String
    var observedThreadID: UInt64 = 0
    var attempts = 0
    var accepted = 0
    var conflicts = 0
    var capacityRejections = 0
    var otherRejections = 0
    var checksum: UInt64 = 0
    var snapshotNanoseconds: [UInt64] = []
    var preparationNanoseconds: [UInt64] = []
    var commitNanoseconds: [UInt64] = []
    var operationNanoseconds: [UInt64] = []
    var settlementNanoseconds: [UInt64] = []
}
struct ResultRow: Codable {
    var workload: String
    var payloadBytes: Int
    var operationsPerParticipant: Int
    var writers: Int
    var readers: Int
    var wallNanoseconds: UInt64 = 0
    var participants: [Participant] = []
    var counts: [String: Int] = [:]
    var memory: [String: Memory] = [:]
    var notes: [String] = []
    var lockBodyNanoseconds: [String: [UInt64]] = [:]
}
func checksum(_ bytes: [UInt8]) -> UInt64 { bytes.reduce(0) { $0 + UInt64($1) } }
func prepared(_ snapshot: PerformanceFlow.Snapshot, salt: UInt64) throws -> PerformanceFlow.Prepared {
    guard case .ready(let observed) = snapshot else { throw Failure(description: "Unexpected phase") }
    return try observed.bump(salt)
}
