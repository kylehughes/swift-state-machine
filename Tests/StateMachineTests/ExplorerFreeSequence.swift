import Dispatch
import Foundation
import StateMachine
import os

// The free-standing sequence slice (E7): a `SnapshotSequence(register:)` of the fake shared host A that
// the harness keeps and reads itself, with no presentation. Its verbs: register a seeded or an unseeded
// sequence, claim an iterator (a second claim ends at once), start a read on the main actor, which
// returns a pending element at once or waits, cancel the reading task, `cancel()` the sequence, deliver,
// finish, the host's cancellation on a worker or on the main thread, and drop the sequence and its
// iterators. A waiting read completes on a later main-actor turn; the harness waits for that completion
// itself, with a safety net, after every event that can complete it.
//
// Invariants: I33 (reads return strictly increasing revisions, the first not older than the snapshot
// current at a seeded registration), I41 (a finish keeps the element unread at the finish readable, and
// every read after the end returns `nil`; a later iterator ends at once), I2 (an unread element is
// released only once its slot is free), I15 (nothing outlives quiescence). The documentation promises no
// executor for an element a worker's cancellation releases, so I1 does not apply here.

/// Runs one sequence against a fresh free-standing snapshot sequence.
@MainActor final class ExplorerFreeSequenceRun: ExplorerRunner {
    let world: ExplorerWorld
    private let host: ExplorerHost
    private var sequence: SnapshotSequence<ExplorerShot>?
    private var iterator: SnapshotSequence<ExplorerShot>.AsyncIterator?
    private var claims = 0
    private var reading: Task<Void, Never>?
    private var readDone = true
    private var reads: [UInt64] = []
    private var registeredAt: UInt64?
    private var endRead = false
    private var readsAfterEnd = 0
    private var expectedFinal: Int?
    private var turns = 0
    private var made = false

    init(verbose: Bool = false) {
        world = ExplorerWorld(verbose: verbose)
        world.state.withLock { $0.offMainExempt = true }
        host = ExplorerHost(0, world)
    }

    func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        if !made { result += [.observe(0), .observeUnseeded] }
        if sequence != nil {
            if claims < 2 { result.append(.claim) }
            result += [.stop, .dropMain, .dropElsewhere]
        }
        // One read after the end, which must return `nil` at once.
        if iterator != nil, readDone, !endRead || readsAfterEnd == 0 { result.append(.read) }
        if !readDone { result.append(.cancelReader) }
        if let id = world.slot(of: 0), let record = world.registration(id), record.phase == .active, !record.parked {
            result += [.deliver(0), .finish(0), .hostCancel(0), .hostCancelMain(0)]
        }
        if !host.parked.isEmpty { result.append(.hostCancelReturn(0)) }
        if turns < 2 { result.append(.turn) }
        return result
    }

    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        var enabledAfter = sequence.isEmpty ? enabled() : []
        for (index, event) in sequence.enumerated() {
            world.note("step \(index + 1): \(event)")
            turns = event == .turn ? turns + 1 : 0
            await perform(event)
            if !world.violations.isEmpty { break }
            if index == sequence.count - 1 { enabledAfter = enabled() }
        }
        await quiesce()
        return ExplorerOutcome(
            violations: world.violations,
            enabled: enabledAfter,
            fingerprint: "",
            trace: world.state.withLock { $0.trace }
        )
    }

    private func perform(_ event: ExplorerEvent) async {
        switch event {
        case .observe, .observeUnseeded:
            made = true
            world.setLatestAttempt(1)
            world.setContext(.call(attempt: 1))
            if event != .observeUnseeded { registeredAt = world.state.withLock { $0.revision } }
            sequence = try? host.sequence(seeded: event != .observeUnseeded)
            world.setContext(.spontaneous)
        case .claim:
            guard let sequence else { return }
            claims += 1
            if claims == 1 {
                iterator = sequence.makeAsyncIterator()
                return
            }
            // A later iterator ends at once: its first read returns `nil` without waiting.
            let second = sequence.makeAsyncIterator()
            let ended = OSAllocatedUnfairLock(initialState: false)
            guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
            let task = Task.immediate { @MainActor [world] in
                var later = second
                let value = await later.next()
                if let value {
                    world.violate(.finishLostFinal, "a second iterator read r\(value.revision)")
                }
                ended.withLock { $0 = true }
            }
            if !ended.withLock({ $0 }) {
                world.violate(.finishLostFinal, "a second iterator's first read waited instead of ending at once")
                task.cancel()
            }
        case .read:
            startRead()
        case .cancelReader:
            expectedFinal = nil
            reading?.cancel()
            await awaitRead()
        case .stop:
            // A read waiting for an element returns `nil` unless it had been handed one already.
            world.letGo([1])
            expectedFinal = nil
            sequence?.cancel()
            await awaitRead()
        case .deliver:
            guard let id = world.slot(of: 0) else { return }
            host.deliver(to: id)
            await awaitRead()
        case .finish:
            guard let id = world.slot(of: 0) else { return }
            // Saved before the finish: the newest element offered and not yet read, alive or not.
            expectedFinal = world.state.withLock { state in
                guard let record = state.registrations[id], let latest = record.latestOffer,
                    let value = state.values[latest], !value.considered
                else { return nil }
                return latest
            }
            host.finish(id)
            await awaitRead()
        case .hostCancel:
            guard let id = world.slot(of: 0) else { return }
            expectedFinal = nil
            if !host.beginCancelling(id) { world.violate(.stuck, "the host's worker never entered onCancel") }
        case .hostCancelReturn:
            for id in host.parked where !host.finishCancelling(id) {
                world.violate(.stuck, "the host's cancellation of #\(id) never returned")
            }
            await awaitRead()
        case .hostCancelMain:
            guard let id = world.slot(of: 0) else { return }
            expectedFinal = nil
            host.cancelHere(id)
            await awaitRead()
        case .dropMain:
            world.letGo([1])
            expectedFinal = nil
            sequence = nil
            iterator = nil
        case .dropElsewhere:
            world.letGo([1])
            expectedFinal = nil
            let kept = OSAllocatedUnfairLock<SnapshotSequence<ExplorerShot>?>(initialState: sequence)
            sequence = nil
            iterator = nil
            let dropped = DispatchSemaphore(value: 0)
            DispatchQueue.global()
                .async {
                    kept.withLock { $0 = nil }
                    dropped.signal()
                }
            if !explorerWait(dropped) { world.violate(.stuck, "release on a worker never returned") }
        case .turn:
            await Task { @MainActor in }.value
        default:
            break
        }
    }

    // A read on the main actor: it returns a pending element before `Task.immediate` returns, or waits.
    private func startRead() {
        guard let start = iterator, readDone else { return }
        readDone = false
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        reading = Task.immediate { @MainActor [weak self] in
            var reader = start
            let value = await reader.next()
            self?.finishRead(value, reader)
        }
    }

    private func finishRead(_ value: ExplorerShot?, _ reader: SnapshotSequence<ExplorerShot>.AsyncIterator) {
        readDone = true
        reading = nil
        if iterator != nil { iterator = reader }
        let expected = expectedFinal
        expectedFinal = nil
        if endRead { readsAfterEnd += 1 }
        guard let value else {
            if let expected {
                world.violate(
                    .finishLostFinal,
                    "a read returned the end while r\(world.revision(of: expected)) was unread at the host's finish"
                )
            }
            endRead = true
            reads.append(0)
            return
        }
        world.considered(value.id)
        world.note("read r\(value.revision)")
        if endRead { world.violate(.finishLostFinal, "a read after the end returned r\(value.revision)") }
        if let expected, expected != value.id {
            world.violate(
                .finishLostFinal,
                "the read after the host's finish returned r\(value.revision), not r\(world.revision(of: expected))"
            )
        }
        if let last = reads.last(where: { $0 > 0 }), value.revision <= last {
            world.violate(.sequenceOrder, "read r\(value.revision) after r\(last)")
        }
        if reads.isEmpty, let registeredAt, value.revision < registeredAt {
            world.violate(
                .sequenceOrder,
                "first read r\(value.revision) is older than r\(registeredAt), current at registration"
            )
        }
        reads.append(value.revision)
    }

    // Waits for a read in flight that the event just completed: an offer, the end, or a cancellation each
    // completes a waiting read. The turns are a safety net that fails a stuck run.
    private func awaitRead() async {
        guard !readDone else { return }
        for _ in 0 ..< 2000 {
            if readDone { return }
            await Task { @MainActor in }.value
        }
        world.violate(.stuck, "a waiting read did not return after an event that completes it")
    }

    private func quiesce() async {
        world.note("quiesce")
        for id in host.parked where !host.finishCancelling(id) {
            world.violate(.stuck, "the host's cancellation of #\(id) never returned")
        }
        sequence?.cancel()
        reading?.cancel()
        for _ in 0 ..< 2000 where !readDone { await Task { @MainActor in }.value }
        if !readDone { world.violate(.stuck, "a read never returned after the sequence was cancelled") }
        sequence = nil
        iterator = nil
        host.forget()
        for _ in 0 ..< 2000 {
            if world.allUnfreed.isEmpty, world.liveValues().isEmpty { return }
            await Task { @MainActor in }.value
        }
        let live = world.state.withLock { $0.values.filter { !$0.value.destroyed }.map { "r\($0.value.revision)" } }
        world.violate(.leak, "at quiescence: slots \(world.allUnfreed.map(\.id)), live values \(live)")
    }
}
