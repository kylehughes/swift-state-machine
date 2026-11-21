import Dispatch
import Foundation
import StateMachine
import StateMachineTestSupport
import os

// The confined-stream slice: a `MainActorSnapshotSequence` registered with the fake
// `MainActorStateMachineHost` (M), or an `IsolatedSnapshotSequence` registered with the fake
// `IsolatedStateMachineHost<MainActor>` (I), kept by an object the harness releases here, on a worker,
// or in the job-first schedule. Checks: I1 (an element is destroyed on the main actor; for the isolated
// stream, except the documented case of a stream dropped elsewhere after its host finished it), I2
// (an unread element is destroyed only once its slot is free), I33 (reads return strictly increasing
// revisions, the first no older than the snapshot current at registration), I15 (nothing outlives
// quiescence).

/// The object that stores a stream, as an app object does; releasing it releases the stream.
@MainActor final class ExplorerStreamKeeper {
    var main: MainActorSnapshotSequence<ExplorerShot>?
    var isolated: IsolatedSnapshotSequence<ExplorerShot>?
}

/// Runs one sequence against a fresh confined stream.
@MainActor final class ExplorerSequenceRun: ExplorerRunner {
    let kind: ExplorerPassiveKind
    let world: ExplorerWorld
    private let mainHost: ExplorerMainHost
    private let isolatedHost: ExplorerMainIsolatedHost
    private var keeper: ExplorerStreamKeeper? = ExplorerStreamKeeper()
    private weak var weakKeeper: ExplorerStreamKeeper?
    private var made = false
    private var ended = false
    private var pending = false
    private var reads: [UInt64] = []
    private var registeredAt: UInt64 = 0
    private var turns = 0
    private var finishedByHost = false
    // I41: the element unread when the host finished, which the next read must return, saved before the
    // read rather than looked up after it, and whether a read has returned the end.
    private var expectedFinal: Int?
    private var readEnd = false
    private var readsAfterEnd = 0

    // The newest element delivered to the stream that no read has returned and that is still alive.
    private func unreadValue() -> Int? {
        world.state.withLock { state in
            guard let record = state.registrations.values.first, let latest = record.latestOffer,
                let value = state.values[latest], !value.considered, !value.destroyed
            else { return nil }
            return latest
        }
    }

    init?(_ kind: ExplorerPassiveKind, verbose: Bool = false) {
        self.kind = kind
        world = ExplorerWorld(verbose: verbose)
        mainHost = ExplorerMainHost(world, index: 2)
        isolatedHost = ExplorerMainIsolatedHost(world)
        weakKeeper = keeper
    }

    private var hostIndex: Int { kind == .sequenceMain ? 2 : 3 }

    func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        if keeper != nil {
            if !made { result.append(.observe(hostIndex)) }
            if made, !ended {
                result.append(.stop)
                if pending { result.append(.apply) }
            }
            // A read after the end returns at once (E7), once per sequence.
            if made, readEnd, readsAfterEnd == 0 { result.append(.apply) }
            result += [.dropMain, .dropElsewhere, .dropAfterJob]
        }
        if let id = world.slot(of: hostIndex), world.registration(id)?.phase == .active {
            result += [.deliver(hostIndex), .finish(hostIndex), .hostCancelMain(hostIndex)]
        }
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
        return ExplorerOutcome(violations: world.violations, enabled: enabledAfter, fingerprint: "", trace: [])
    }

    private func perform(_ event: ExplorerEvent) async {
        switch event {
        case .observe:
            made = true
            world.setLatestAttempt(1)
            world.setContext(.call(attempt: 1))
            defer { world.setContext(.spontaneous) }
            registeredAt = world.state.withLock { $0.revision }
            let mainHost = mainHost
            let isolatedHost = isolatedHost
            if kind == .sequenceMain {
                keeper?.main = try? MainActorSnapshotSequence<ExplorerShot>({ $0 }) {
                    (receive, finish) throws(SubscriptionFailure) in
                    try mainHost.subscribe(receive, onFinish: finish)
                }
            } else {
                keeper?.isolated = try? IsolatedSnapshotSequence<ExplorerShot>({ $0 }) {
                    (offer, finish) throws(SubscriptionFailure) in
                    try isolatedHost.subscribe(offer, onFinish: finish, isolation: MainActor.shared)
                }
            }
            pending = true
        case .apply:
            // A read with an element pending, so it returns without suspending.
            guard let keeper else { return }
            // The stream leaves its keeper for the read and goes back afterward.
            var value: ExplorerShot?
            if kind == .sequenceMain {
                if var stream = keeper.main.take() {
                    value = await stream.next()
                    keeper.main = consume stream
                }
            } else if var stream = keeper.isolated.take() {
                value = await stream.next()
                keeper.isolated = consume stream
            }
            pending = false
            let expected = expectedFinal
            expectedFinal = nil
            if readEnd {
                readsAfterEnd += 1
                if let value {
                    world.violate(.finishLostFinal, "a read after the end returned r\(value.revision)")
                }
                return
            }
            guard let value else {
                // A finish keeps the final unread element readable (OBS-005, OBS-006), even when the
                // element is already gone, which is how a dropped final element shows.
                if let expected {
                    world.violate(
                        .finishLostFinal,
                        "a read returned the end while r\(world.revision(of: expected)) was unread at the host's finish"
                    )
                }
                ended = true
                readEnd = true
                return
            }
            if let expected, expected != value.id {
                world.violate(
                    .finishLostFinal,
                    "the read after the host's finish returned r\(value.revision), not r\(world.revision(of: expected)), the element unread at the finish"
                )
            }
            world.considered(value.id)
            if let last = reads.last, value.revision <= last {
                world.violate(.sequenceOrder, "read r\(value.revision) after r\(last)")
            }
            if reads.isEmpty, value.revision < registeredAt {
                world.violate(
                    .sequenceOrder,
                    "first read r\(value.revision) is older than r\(registeredAt), current at registration"
                )
            }
            reads.append(value.revision)
        case .stop:
            ended = true
            readEnd = true
            expectedFinal = nil
            world.letGo([1])
            let unread = unreadValue()
            if kind == .sequenceMain { keeper?.main?.cancel() } else { keeper?.isolated?.cancel() }
            // Ending a confined stream releases its unread element on its actor before returning
            // (OBS-005); the fake hosts cancel synchronously, so no cancellation is in progress elsewhere.
            if let unread, world.liveValues().contains(unread) {
                world.violate(
                    .cancelKeptUnread,
                    "cancel() returned with its unread r\(world.revision(of: unread)) still alive"
                )
            }
        case .deliver:
            if kind == .sequenceMain { _ = mainHost.advance() } else { isolatedHost.advance() }
            pending = true
        case .finish:
            finishedByHost = true
            // Saved before the finish: the newest element offered and not yet read, alive or not.
            expectedFinal = world.state.withLock { state in
                guard let record = state.registrations.values.first, record.phase == .active, !record.hostEnded,
                    let latest = record.latestOffer, let value = state.values[latest], !value.considered
                else { return nil }
                return latest
            }
            if kind == .sequenceMain { mainHost.finish() } else { isolatedHost.finish() }
            pending = true
        case .hostCancelMain:
            // A host's cancellation ends the stream without the finish's promise about its last element.
            expectedFinal = nil
            if kind == .sequenceMain { mainHost.cancelSubscription() } else { isolatedHost.cancelSubscription() }
            pending = true
        case .dropMain:
            release()
            let held = keeper
            keeper = nil
            _ = consume held
        case .dropElsewhere:
            release()
            guard let held = keeper else { return }
            keeper = nil
            let slot = OSAllocatedUnfairLock<ExplorerStreamKeeper?>(initialState: held)
            _ = consume held
            let dropped = DispatchSemaphore(value: 0)
            runOnOwnThread {
                slot.withLock { $0 = nil }
                dropped.signal()
            }
            if !explorerWait(dropped) { world.violate(.stuck, "release on a worker never returned") }
        case .dropAfterJob:
            release()
            guard let held = keeper else { return }
            keeper = nil
            await explorerDropAfterItsJob(consume held)
        case .turn:
            await Task { @MainActor in }.value
        default:
            break
        }
    }

    // The stream is let go. An isolated stream dropped elsewhere after its host finished it releases
    // its unread element where it is dropped, as documented; that one destruction is exempt from I1.
    private func release() {
        world.letGo([1])
        if kind == .sequenceIsolated, world.state.withLock({ $0.registrations.values.contains { $0.finished } }) {
            world.state.withLock { $0.offMainExempt = true }
        }
    }

    private func quiesce() async {
        world.note("quiesce")
        if keeper != nil { await perform(.dropMain) }
        // A host of its own sweeps the callbacks of a registration whose isolated stream was dropped
        // off the owning actor, whose token therefore never ran (documented); the fake host does it here.
        if kind == .sequenceIsolated { isolatedHost.sweep() }
        for _ in 0 ..< 2000 {
            if weakKeeper == nil, world.unfreed.isEmpty, world.liveValues().isEmpty { return }
            await Task { @MainActor in }.value
        }
        let live = world.state.withLock { $0.values.filter { !$0.value.destroyed }.map { "r\($0.value.revision)" } }
        world.violate(
            .leak,
            "at quiescence: keeper alive \(weakKeeper != nil), slots \(world.unfreed.map(\.id)), live values \(live)"
        )
    }
}
