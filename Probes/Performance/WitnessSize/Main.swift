import Dispatch
import Foundation
import StateMachine

struct VerificationFailure: Error, CustomStringConvertible { let description: String }

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw VerificationFailure(description: message) }
}

@inline(never)
func mix(_ acc: inout UInt64, _ value: UInt64) {
    acc = (acc &* 6_364_136_223_846_793_005) &+ value &+ 1_442_695_040_888_963_407
}

@inline(never)
func mixText(_ acc: inout UInt64, _ text: String) {
    mix(&acc, UInt64(text.utf8.count))
    for byte in text.utf8.prefix(12) { mix(&acc, UInt64(byte)) }
}

@inline(never)
func observe(_ snapshot: DocumentSyncFlow.Snapshot, checksum: inout UInt64) -> Int {
    mix(&checksum, snapshot.revision)
    if snapshot.isClosed { mix(&checksum, 0xDEAD_BEEF) }
    switch snapshot.model {
    case .idle(let v): mix(&checksum, UInt64(v.pendingTags.count))
    case .preparing(let v): mix(&checksum, UInt64(v.checks.count))
    case .queued(let v): mix(&checksum, UInt64(v.headers.count))
    case .running(let v): mix(&checksum, UInt64(v.activeHeaders.count))
    case .verifying(let v): mix(&checksum, UInt64(v.unresolved.count))
    case .reviewing(let v): mix(&checksum, UInt64(v.reviewers.count))
    case .publishing(let v): mix(&checksum, UInt64(v.receipts.count))
    case .degraded(let v): mix(&checksum, UInt64(v.prior.count))
    case .archived(let v): mix(&checksum, UInt64(v.sealNotes.count))
    }
    switch snapshot {
    case .idle(let o):
        mixText(&checksum, o.value.note)
        return 0
    case .preparing(let o):
        mixText(&checksum, o.value.startedBy)
        return 1
    case .queued(let o):
        mixText(&checksum, o.value.queueName)
        return 2
    case .running(let o):
        mixText(&checksum, o.value.workerID)
        return 3
    case .verifying(let o):
        mix(&checksum, UInt64(o.value.digests.count))
        return 4
    case .reviewing(let o):
        mixText(&checksum, o.value.summary ?? "")
        return 5
    case .publishing(let o):
        mixText(&checksum, o.value.channel)
        return 6
    case .degraded(let o):
        mix(&checksum, UInt64(o.value.prior.count))
        return 7
    case .archived(let o):
        mixText(&checksum, o.value.archiveURL.absoluteString)
        return 8
    }
}

func makeIdle(seed: UInt64, cycle: Int, baseURL: URL) -> DocumentSyncFlow.Idle {
    let envelope = DocumentSyncFlow.Envelope(
        documentID: "doc-\(seed & 0xFFFF)-\(cycle)",
        title: "Spec \(cycle)",
        endpoint: baseURL,
        detail: .local(id: "rev-\(cycle)", branch: "main", notes: ["init"]),
        tags: ["isolated", "v\(cycle & 3)"],
        attributes: ["bucket": "\(cycle & 7)"],
        lease: DocumentSyncFlow.Lease(label: "lease-\(cycle)", sequence: seed &+ UInt64(cycle))
    )
    return DocumentSyncFlow.Idle(envelope: envelope, note: "init-\(cycle)", pendingTags: [], extra: [:])
}

struct Counters {
    var cycles = 0
    var transitions = 0
    var snapshotsRead = 0
    var commandsDrained = 0
    var deliveries = 0
    var rejectionsObserved = 0
    var phaseMask: UInt32 = 0
    var checksum: UInt64 = 0
}

@inline(never)
func runWorkflow(cycles: Int, seed: UInt64) throws -> Counters {
    let baseURL = URL(string: "https://sync.example.invalid/doc/\(seed)")!
    let queueURL = URL(string: "https://queue.example.invalid/work")!
    let mirrorURL = URL(string: "https://mirror.example.invalid/release")!
    let archiveURL = URL(string: "https://archive.example.invalid/\(seed)")!

    var counters = Counters(checksum: seed ^ 0x51A7_E001)
    var owner = DocumentSyncFlow.Local(makeIdle(seed: seed, cycle: 0, baseURL: baseURL))
    var retained: [DocumentSyncFlow.Snapshot] = []
    retained.reserveCapacity(8)

    func record(_ snapshot: DocumentSyncFlow.Snapshot) {
        counters.phaseMask |= (1 << UInt32(observe(snapshot, checksum: &counters.checksum)))
        counters.snapshotsRead += 1
    }

    for cycle in 0 ..< cycles {
        if cycle > 0 {
            record(try owner.reset(to: makeIdle(seed: seed, cycle: cycle, baseURL: baseURL)).snapshot)
            counters.transitions += 1
        }
        retained.removeAll(keepingCapacity: true)

        // Prepare + commit plus stale-snapshot conflict rejection.
        let initial = owner.snapshot()
        try require(owner.owns(initial), "Owner must own its snapshot")
        record(initial)
        retained.append(initial)

        guard case .idle(let observed) = initial else { throw VerificationFailure(description: "Expected idle") }
        guard case .committed(let editReceipt) = owner.commit(observed.annotate("tag-\(cycle & 7)")) else {
            throw VerificationFailure(description: "Expected annotate commit")
        }
        record(editReceipt.snapshot)
        retained.append(editReceipt.snapshot)
        counters.transitions += 1

        switch owner.commit(observed.annotate("stale")) {
        case .committed: throw VerificationFailure(description: "Stale commit must reject")
        case .rejected(let reason, let current):
            try require(reason == .conflict, "Expected conflict rejection")
            record(current)
            counters.rejectionsObserved += 1
        }

        // Idle -> Preparing -> Queued -> Running (starts Process).
        record(try owner.send(.prepare("actor-\(cycle & 3)")).snapshot)
        record(try owner.send(.enqueue(queueURL)).snapshot)
        let runReceipt = try owner.send(.start("worker-\(cycle & 3)"))
        record(runReceipt.snapshot)
        retained.append(runReceipt.snapshot)
        counters.transitions += 3

        let batches = owner.drainCommands(limit: 8)
        var work: DocumentSyncFlow.ProcessWork?
        for batch in batches {
            mix(&counters.checksum, batch.receipt.revision)
            for command in batch.commands {
                counters.commandsDrained += 1
                switch command {
                case .process(let item): work = item
                case .cancel: mix(&counters.checksum, 0xCA1C_E101)
                }
            }
        }
        guard let activeWork = work else { throw VerificationFailure(description: "Missing ProcessWork") }
        try require(
            owner.acknowledgeExecution(activeWork.execution, disposition: .terminated) == .recorded,
            "Expected execution ack"
        )

        if cycle % 4 == 3 {
            // Failure branch: Running -> Degraded -> Idle.
            let reason = DocumentSyncFlow.FailureReason.network(
                host: "edge",
                detail: "timeout-\(cycle)",
                hints: ["retry"]
            )
            guard case .committed(let degReceipt) = owner.deliver(activeWork.failed(reason)) else {
                throw VerificationFailure(description: "Expected failure delivery")
            }
            record(degReceipt.snapshot)
            retained.append(degReceipt.snapshot)
            counters.deliveries += 1
            record(try owner.send(.recover("recovered-\(cycle)")).snapshot)
            counters.transitions += 2
        } else {
            // Success branch: Running -> Verifying -> Reviewing -> Publishing -> Idle.
            let remote = DocumentSyncFlow.Detail.remote(
                etag: "e-\(cycle)",
                endpoint: baseURL,
                headers: ["x": "\(cycle)"]
            )
            guard case .committed(let verReceipt) = owner.deliver(activeWork.succeeded(remote)) else {
                throw VerificationFailure(description: "Expected success delivery")
            }
            record(verReceipt.snapshot)
            retained.append(verReceipt.snapshot)
            counters.deliveries += 1
            record(try owner.send(.advanceReview("rev-\(cycle & 3)")).snapshot)
            record(try owner.send(.approvePublish(mirrorURL)).snapshot)
            let merged = DocumentSyncFlow.Detail.merged(
                base: "b-\(cycle)",
                heads: ["e-\(cycle)"],
                metadata: ["ok": "1"]
            )
            record(try owner.send(.finishPublish(merged)).snapshot)
            counters.transitions += 4
        }

        for historical in retained {
            try require(owner.owns(historical), "Historical snapshot lost ownership")
            record(historical)
        }
        try require(owner.pendingCompletions().isEmpty, "Unexpected pending completions")
        counters.cycles += 1
    }

    // Exercise pending/discard APIs on live code paths without altering cycle counts.
    if let pending = owner.pendingCompletions().first {
        _ = owner.discardPending(id: pending.id)
    }

    record(try owner.send(.archive(archiveURL)).snapshot)
    counters.transitions += 1
    record(owner.close().snapshot)
    _ = owner.drainCommands(limit: 8)
    try require(owner.isQuiescent, "Owner failed quiescence")
    return counters
}

struct OutputRecord: Codable {
    var mode: String
    var cycles: Int
    var transitions: Int
    var snapshotsRead: Int
    var commandsDrained: Int
    var deliveries: Int
    var rejectionsObserved: Int
    var distinctPhasesVisited: Int
    var checksum: UInt64
    var wallNanoseconds: UInt64
    var warmup: Int
    var repetition: Int
    var inlineSizes: [String: Int]
}

@main
nonisolated enum WitnessSizeMain {
    static func main() throws {
        let args = CommandLine.arguments
        func arg(_ name: String, _ fallback: String) -> String {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
            return args[i + 1]
        }
        let mode = arg("--mode", "verify")
        let cycles = Int(arg("--cycles", mode == "verify" ? "16" : "800")) ?? 16
        let warmup = Int(arg("--warmup", mode == "verify" ? "0" : "1")) ?? 0
        let repetitions = Int(arg("--repetitions", mode == "verify" ? "1" : "5")) ?? 1
        let seed = UInt64(arg("--seed", "42")) ?? 42
        try require(cycles >= 4 && repetitions >= 1 && warmup >= 0, "Invalid arguments")

        let inlineSizes: [String: Int] = [
            "model": MemoryLayout<DocumentSyncFlow>.size,
            "snapshot": MemoryLayout<DocumentSyncFlow.Snapshot>.size,
            "prepared": MemoryLayout<DocumentSyncFlow.Prepared>.size,
            "receipt": MemoryLayout<DocumentSyncFlow.Receipt>.size,
            "commandBatch": MemoryLayout<DocumentSyncFlow.CommandBatch>.size,
            "local": MemoryLayout<DocumentSyncFlow.Local>.size,
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for iteration in (-warmup) ..< repetitions {
            let start = DispatchTime.now().uptimeNanoseconds
            let counters = try runWorkflow(cycles: cycles, seed: seed)
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            let visited = counters.phaseMask.nonzeroBitCount
            try require(visited == 9 && counters.rejectionsObserved == cycles, "Incomplete fixture run")
            let record = OutputRecord(
                mode: mode,
                cycles: counters.cycles,
                transitions: counters.transitions,
                snapshotsRead: counters.snapshotsRead,
                commandsDrained: counters.commandsDrained,
                deliveries: counters.deliveries,
                rejectionsObserved: counters.rejectionsObserved,
                distinctPhasesVisited: visited,
                checksum: counters.checksum,
                wallNanoseconds: elapsed,
                warmup: iteration < 0 ? 1 : 0,
                repetition: iteration,
                inlineSizes: inlineSizes
            )
            FileHandle.standardOutput.write(try encoder.encode(record))
            FileHandle.standardOutput.write(Data([10]))
        }
    }
}
