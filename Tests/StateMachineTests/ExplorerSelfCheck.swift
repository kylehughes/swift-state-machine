import Combine
import Dispatch
import Foundation
import StateMachineTestSupport
import os

// The explorer's self-check. Each invariant that guards a past defect class decides through one of the checks
// below, and the slices call that same code. For each, `explorerSelfChecks()` plants the defect (a broken
// fake value, history, or report sequence) that the check must report, beside a control it must accept. An
// invariant whose check no planted defect trips is not trusted; `Tests/ScheduleExplorer.md` lists the
// invariants without a self-check as untested.

/// One planted defect and its control.
struct ExplorerSelfCheck: Sendable {
    let invariant: ExplorerInvariant
    let defect: String
    /// The check reported the planted defect.
    let planted: Bool
    /// The check accepted the control.
    let control: Bool
    var trusted: Bool { planted && control }
}

// MARK: Checks the slices call

/// I37 at a driving `true`: why the shown revision is older than the live registration's seed, or `nil`.
func explorerSeedVisibleProblem(registration: Int, seed: UInt64?, shown: UInt64) -> String? {
    guard let seed, shown < seed else { return nil }
    return "true reported for registration #\(registration) while r\(shown) is shown, older than its seed r\(seed)"
}

/// A client value delivered to a registration, as I54 reads it at quiescence.
struct ExplorerSettledValue: Sendable {
    let id: Int
    let revision: UInt64
    let registration: Int
    /// The registration's cancellation has returned and its slot is free.
    let settled: Bool
    /// The presentation showed it, or shows it now.
    let shown: Bool
    let alive: Bool
}

/// I54 on a driving presentation: why a value of a settled registration is still alive, or `nil`.
///
/// Once a registration's cancellation has settled, the presentation holds none of its values that it never
/// showed: stopping discards an unannounced value, so keeping one is custody without a purpose, and a
/// value that captures the presentation would keep both alive.
func explorerSettledCustodyProblem(_ values: [ExplorerSettledValue]) -> String? {
    let kept = values.filter { $0.settled && !$0.shown && $0.alive }.sorted { $0.id < $1.id }
    guard let first = kept.first else { return nil }
    return
        "r\(first.revision), never shown, of registration #\(first.registration) is still alive after its cancellation settled"
}

/// I55: why `live` payloads of completed works exceed what the owner may keep for its pending-completion
/// registrations, `bound`, or `nil`.
func explorerRetainedPayloadProblem(live: Int, bound: Int) -> String? {
    live > bound ? "\(live) payloads of completed works are alive, more than the \(bound) the live work allows" : nil
}

/// I53: why `flush(through:)` of the held batch's receipt broke its boundary, or `nil`. `result` is what
/// the flush returned so far (`nil` while it runs); `held` says whether the batch's handler is still held.
func explorerFlushProblem(held: Bool, result: Bool?) -> String? {
    if held {
        return result == nil
            ? nil : "flush(through:) of the held batch's receipt returned while its emission handler is held"
    }
    return result == true
        ? nil : "flush(through:) of the held batch's receipt did not return true once the batch was processed"
}

/// I23 at quiescence: why a subscriber received a value the presentation never showed, or `nil`.
///
/// A presentation publishes exactly what it shows, so a received value is one the harness saw shown, whatever
/// its revision.
func explorerUnshownProblem(_ subscriber: Int, _ received: [(id: Int, revision: UInt64)], shown: Set<Int>) -> String? {
    guard let value = received.first(where: { !shown.contains($0.id) }) else { return nil }
    return "subscriber \(subscriber) received r\(value.revision), which was never shown"
}

/// I10 on a driving presentation: why a newly shown value belongs to an observation that ended first.
///
/// `nil` when it does not. Stopping discards an observation value (a seed or a
/// delivery) whose publication was not announced; a change admitted through the presentation still publishes
/// its receipt.
func explorerEndedObservationProblem(
    registration: Int?,
    admittedThroughPresentation: Bool,
    endedByPresentation: Set<Int>,
    hostDeliveryAfterFinish: Bool
) -> String? {
    if admittedThroughPresentation { return nil }
    guard let registration else { return nil }
    if endedByPresentation.contains(registration) {
        return "a value of registration #\(registration) never announced before the presentation ended it"
    }
    return hostDeliveryAfterFinish ? "the host's delivery" : nil
}

/// I52 at a read that returned an element: why `value` cannot follow `reads`, and its anchor.
///
/// The owner held the projections `history` since the sequence's registration; the problem is `nil` when
/// `value` can follow. Each element stands for a state the owner held after the previous element's, in order, and two equal
/// elements need a different projection between them.
func explorerDistinctReadProblem(
    _ value: String,
    reads: [String],
    history: [String],
    lastRead: Int
) -> (problem: String?, anchor: Int) {
    let from = reads.isEmpty ? 0 : lastRead + 1
    let eligible = from < history.count ? history[from...] : []
    guard let position = eligible.firstIndex(of: value) else {
        return (
            "read \(value) after \(reads), which the owner did not hold after the previous element (\(history))",
            lastRead
        )
    }
    return (nil, position)
}

/// I52 at a read that returned the end: why a sequence the harness did not cancel may not end there.
///
/// `nil` when it may. Only the owner's closing ends one, and only after the closed phase, unless that equals its last element.
func explorerDistinctEndProblem(reads: [String], closed: Bool, closedProjection: String?) -> String? {
    if !closed { return "ended while the owner is open" }
    if let final = closedProjection, reads.last != final {
        return "ended after \(reads) without the closed phase \(final)"
    }
    return nil
}

/// I50 at an ingress delivery: why the delivered value was never staged, or `nil`.
func explorerIngressMembershipProblem(id: Int, revision: UInt64, staged: Set<Int>) -> String? {
    staged.contains(id) ? nil : "r\(revision) was delivered but never staged"
}

// MARK: The planted defects

/// Runs every planted defect and its control against the checks above and the harness's own components.
@MainActor func explorerSelfChecks() -> [ExplorerSelfCheck] {
    var checks: [ExplorerSelfCheck] = []
    func check(_ invariant: ExplorerInvariant, _ defect: String, planted: Bool, control: Bool) {
        checks.append(.init(invariant: invariant, defect: defect, planted: planted, control: control))
    }

    // Early `true`: a registration reported live while the snapshot shown is older than its seed.
    check(
        .trueBeforeLive,
        "true reported before the registration's seed is shown",
        planted: explorerSeedVisibleProblem(registration: 2, seed: 30, shown: 10) != nil,
        control: explorerSeedVisibleProblem(registration: 2, seed: 30, shown: 30) == nil
    )

    // Out-of-order and incomplete reports, through the reconcile slice's own log.
    func reports(_ steps: (ExplorerReportsLog) -> Void) -> Bool {
        let log = ExplorerReportsLog()
        steps(log)
        return !log.state.withLock { $0.violations }.isEmpty
    }
    // Work 3 is a candidate on its first preparation; a second, after an edit, refuses.
    func prepared(_ log: ExplorerReportsLog) {
        log.offered(work: 3, serial: 1)
        _ = log.prepare(work: 3, accepts: true, model: 0)
        log.left()
        _ = log.prepare(work: 3, accepts: true, model: 1)
        log.left()
    }
    check(
        .attemptOrder,
        "a later attempt reported before an earlier one (C2 before C1)",
        planted: reports { log in
            prepared(log)
            _ = log.record(work: 3, attempt: 2, serial: 1, entry: 0, requiresReconciliation: true, reason: .preparation)
            _ = log.record(work: 3, attempt: 1, serial: 1, entry: 0, requiresReconciliation: true, reason: .admission)
        },
        control: !reports { log in
            prepared(log)
            _ = log.record(work: 3, attempt: 1, serial: 1, entry: 0, requiresReconciliation: true, reason: .admission)
            _ = log.record(work: 3, attempt: 2, serial: 1, entry: 0, requiresReconciliation: true, reason: .preparation)
        }
    )
    check(
        .attemptOrder,
        "a refused attempt skipped",
        planted: reports { log in
            log.offered(work: 1, serial: 1)
            for model in 0 ..< 2 {
                _ = log.prepare(work: 1, accepts: false, model: model)
                log.left()
            }
            _ = log.record(work: 1, attempt: 2, serial: 1, entry: 0, requiresReconciliation: true, reason: .preparation)
        },
        control: !reports { log in
            log.offered(work: 1, serial: 1)
            for model in 0 ..< 2 {
                _ = log.prepare(work: 1, accepts: false, model: model)
                log.left()
            }
            for attempt: UInt64 in 1 ... 2 {
                _ = log.record(
                    work: 1,
                    attempt: attempt,
                    serial: 1,
                    entry: 0,
                    requiresReconciliation: true,
                    reason: .preparation
                )
            }
        }
    )
    check(
        .attemptOrder,
        "a report carrying a later payload than the first under the same ticket, or the wrong reason",
        planted: reports { log in
            log.offered(work: 1, serial: 1)
            log.offered(work: 1, serial: 2)
            _ = log.prepare(work: 1, accepts: false, model: 0)
            log.left()
            _ = log.record(work: 1, attempt: 1, serial: 2, entry: 0, requiresReconciliation: true, reason: .preparation)
        }
            && reports { log in
                log.offered(work: 1, serial: 1)
                _ = log.prepare(work: 1, accepts: false, model: 0)
                log.left()
                _ = log.record(
                    work: 1,
                    attempt: 1,
                    serial: 1,
                    entry: 0,
                    requiresReconciliation: true,
                    reason: .admission
                )
            },
        control: !reports { log in
            log.offered(work: 1, serial: 1)
            log.offered(work: 1, serial: 2)
            _ = log.prepare(work: 1, accepts: false, model: 0)
            log.left()
            _ = log.record(work: 1, attempt: 1, serial: 1, entry: 0, requiresReconciliation: true, reason: .preparation)
        }
    )

    // One queue per owner: B1's handler reconciles B while C1 is decided and undelivered, so B2 follows C1.
    func ordered(_ second: [(work: Int, attempt: UInt64)]) -> Bool {
        reports { log in
            for work in [2, 3] {
                log.offered(work: work, serial: work)
                _ = log.prepare(work: work, accepts: false, model: 0)
                log.left()
            }
            _ = log.record(work: 2, attempt: 1, serial: 2, entry: 0, requiresReconciliation: true, reason: .preparation)
            log.reconciling(2, owed: [(work: 3, attempt: 1)])
            _ = log.prepare(work: 2, accepts: false, model: 1)
            log.left()
            for (work, attempt) in second {
                _ = log.record(
                    work: work,
                    attempt: attempt,
                    serial: work,
                    entry: work == 2 ? 0 : 1,
                    requiresReconciliation: true,
                    reason: .preparation
                )
            }
        }
    }
    check(
        .attemptOrder,
        "a handler's reconciliation reported before a report decided earlier (B1, B2, C1)",
        planted: ordered([(2, 2), (3, 1)]),
        control: !ordered([(3, 1), (2, 2)])
    )

    // A lost final element, and a value accepted from anywhere in the history.
    check(
        .distinctProjection,
        "a sequence that ends without the closed phase",
        planted: explorerDistinctEndProblem(reads: ["idle"], closed: true, closedProjection: "loading") != nil,
        control: explorerDistinctEndProblem(reads: ["idle", "loading"], closed: true, closedProjection: "loading")
            == nil
    )
    check(
        .distinctProjection,
        "reads A, B, A against the history A, B",
        planted: explorerDistinctReadProblem("A", reads: ["A", "B"], history: ["A", "B"], lastRead: 1).problem != nil,
        control: explorerDistinctReadProblem("A", reads: ["A", "B"], history: ["A", "B", "A"], lastRead: 1).problem
            == nil
    )

    // An invalidation of the wrong property: an extra one, or a change without one.
    let world = ExplorerWorld()
    let extra = ExplorerPropertyTrace<Int>("snapshot")
    extra.begin(1)
    extra.invalidated(1, world)
    extra.invalidated(1, world)
    let missing = ExplorerPropertyTrace<Bool>("isObserving")
    missing.begin(false)
    missing.end(true, world)
    let plantedInvalidations = world.violations.count == 2
    let clean = ExplorerWorld()
    let chain = ExplorerPropertyTrace<Int>("snapshot")
    chain.begin(1)
    chain.invalidated(1, clean)
    chain.invalidated(2, clean)
    chain.end(3, clean)
    check(
        .propertyInvalidation,
        "an invalidation without a change, and a change without an invalidation",
        planted: plantedInvalidations,
        control: clean.violations.isEmpty
    )

    // A value shown after stop.
    check(
        .shownAfterEnd,
        "an unannounced seed of a stopped registration shown after the stop",
        planted: explorerEndedObservationProblem(
            registration: 2,
            admittedThroughPresentation: false,
            endedByPresentation: [2],
            hostDeliveryAfterFinish: false
        ) != nil,
        control: explorerEndedObservationProblem(
            registration: 2,
            admittedThroughPresentation: true,
            endedByPresentation: [2],
            hostDeliveryAfterFinish: false
        ) == nil
    )

    // A slot held after `false`: a let-go registration still holds its slot.
    let held = ExplorerWorld()
    held.setContext(.call(attempt: 1))
    let registration = held.admit(host: 0)
    held.setContext(.spontaneous)
    held.letGo([1])
    let plantedSlot = !held.unfreedEnded.isEmpty
    if let registration { held.freed(registration) }
    check(
        .falseWhileOccupied,
        "false reported while a let-go registration holds its slot",
        planted: plantedSlot,
        control: held.unfreedEnded.isEmpty
    )

    // A client value released off the main thread.
    let threads = ExplorerWorld()
    let box = ExplorerOffMainRelease(threads.makeValue(.applied(attempt: nil), attempt: nil))
    let released = DispatchSemaphore(value: 0)
    runOnOwnThread {
        box.release()
        released.signal()
    }
    _ = explorerWait(released)
    let plantedOffMain = threads.violations.contains { $0.invariant == .offMain }
    let main = ExplorerWorld()
    var value: ExplorerShot? = main.makeValue(.applied(attempt: nil), attempt: nil)
    _ = value
    value = nil
    check(
        .offMain,
        "a client value released off the main thread",
        planted: plantedOffMain,
        control: !main.violations.contains { $0.invariant == .offMain }
    )

    // Over-allowance: 33 elements of one registration in one main-actor turn.
    var over = ExplorerTurnBudget()
    var trips = 0
    for _ in 0 ..< ExplorerTurnBudget.allowance + 1 where over.read(registration: 1, task: 7).exceeded {
        trips += 1
    }
    var within = ExplorerTurnBudget()
    var none = true
    for _ in 0 ..< ExplorerTurnBudget.allowance where within.read(registration: 1, task: 7).exceeded {
        none = false
    }
    check(.presentationTurnBound, "33 elements of one registration in one turn", planted: trips == 1, control: none)

    // A stopped driving presentation that keeps a value of a settled registration it never showed.
    func settled(alive: Bool, shown: Bool, settled: Bool) -> ExplorerSettledValue {
        ExplorerSettledValue(id: 3, revision: 30, registration: 1, settled: settled, shown: shown, alive: alive)
    }
    check(
        .custodyAfterSettlement,
        "an unshown value of a stopped registration kept after its cancellation settled",
        planted: explorerSettledCustodyProblem([settled(alive: true, shown: false, settled: true)]) != nil,
        control: explorerSettledCustodyProblem([
            settled(alive: false, shown: false, settled: true), settled(alive: true, shown: true, settled: true),
            settled(alive: true, shown: false, settled: false),
        ]) == nil
    )

    // Completed payloads kept behind a held report handler beyond one unread and one handed collection per
    // pending registration.
    check(
        .retainedPayloads,
        "every completed payload kept behind a held handler for one pending registration",
        planted: explorerRetainedPayloadProblem(live: 4, bound: 2) != nil,
        control: explorerRetainedPayloadProblem(live: 2, bound: 2) == nil
    )

    // Two works' reports naming one retained entry.
    check(
        .attemptOrder,
        "reports of two works naming one retained entry",
        planted: reports { log in
            for work in [1, 2] {
                log.offered(work: work, serial: work)
                _ = log.prepare(work: work, accepts: false, model: 0)
                log.left()
            }
            _ = log.record(work: 2, attempt: 1, serial: 2, entry: 7, requiresReconciliation: true, reason: .preparation)
            _ = log.record(work: 1, attempt: 1, serial: 1, entry: 7, requiresReconciliation: true, reason: .preparation)
        },
        control: !reports { log in
            for work in [1, 2] {
                log.offered(work: work, serial: work)
                _ = log.prepare(work: work, accepts: false, model: 0)
                log.left()
            }
            _ = log.record(work: 2, attempt: 1, serial: 2, entry: 7, requiresReconciliation: true, reason: .preparation)
            _ = log.record(work: 1, attempt: 1, serial: 1, entry: 8, requiresReconciliation: true, reason: .preparation)
        }
    )

    // A flush that returns while the batch it waits for is held, or never returns once it is processed.
    check(
        .flushBoundary,
        "flush(through:) returning while its batch's handler is held, and failing to return after it",
        planted: explorerFlushProblem(held: true, result: true) != nil
            && explorerFlushProblem(held: false, result: nil) != nil,
        control: explorerFlushProblem(held: true, result: nil) == nil
            && explorerFlushProblem(held: false, result: true) == nil
    )

    // A subscriber given a value the presentation never showed, below the one it shows.
    check(
        .combineUnshown,
        "a subscriber receives an unshown value older than the snapshot shown",
        planted: explorerUnshownProblem(0, [(1, 10), (4, 15), (2, 20)], shown: [1, 2]) != nil,
        control: explorerUnshownProblem(0, [(1, 10), (2, 20)], shown: [1, 2]) == nil
    )

    // Combine protocol and delivery: a second subscription, a value before its announcement, a value beyond
    // demand, a duplicate, and a value after cancellation.
    func subscriber(_ world: ExplorerWorld, unlimited: Bool = false) -> ExplorerSubscriber {
        let made = ExplorerSubscriber(index: 0, unlimited: unlimited, shownAtAttach: 0, attachedAfterRelease: false)
        made.world = world
        made.shownAtAttachID = nil
        return made
    }
    func flagged(_ invariant: ExplorerInvariant, _ steps: (ExplorerWorld) -> Void) -> Bool {
        let world = ExplorerWorld()
        steps(world)
        return world.violations.contains { $0.invariant == invariant }
    }
    check(
        .subscriptionProtocol,
        "a subscriber given two subscriptions",
        planted: flagged(.subscriptionProtocol) { world in
            let twice = subscriber(world)
            twice.receive(subscription: ExplorerNullSubscription())
            twice.receive(subscription: ExplorerNullSubscription())
        },
        control: !flagged(.subscriptionProtocol) { world in
            let once = subscriber(world)
            once.receive(subscription: ExplorerNullSubscription())
            once.checkHandshake()
        }
    )
    check(
        .callbackOrder,
        "a newly published value delivered before objectWillChange announced it",
        planted: flagged(.callbackOrder) { world in
            let early = subscriber(world, unlimited: true)
            early.willChangeAtLastNew = 3
            explorerCheckOrder(
                world,
                early,
                world.makeValue(.applied(attempt: nil), attempt: nil),
                willChange: 3,
                shownNow: nil,
                shownBefore: false
            )
        },
        control: !flagged(.callbackOrder) { world in
            let timely = subscriber(world, unlimited: true)
            timely.willChangeAtLastNew = 3
            explorerCheckOrder(
                world,
                timely,
                world.makeValue(.applied(attempt: nil), attempt: nil),
                willChange: 4,
                shownNow: nil,
                shownBefore: false
            )
        }
    )
    func delivering(
        _ world: ExplorerWorld,
        _ count: Int,
        demand: Int,
        cancelAfter: Int? = nil,
        repeatLast: Bool = false
    ) {
        let limited = subscriber(world)
        limited.receive(subscription: ExplorerNullSubscription())
        limited.demand = demand
        var values: [ExplorerShot] = []
        for index in 0 ..< count {
            if index == cancelAfter { limited.cancel() }
            let value =
                repeatLast && index > 0 ? values[index - 1] : world.makeValue(.applied(attempt: nil), attempt: nil)
            values.append(value)
            explorerCheckReceived(world, limited, value)
        }
    }
    check(
        .combineDemand,
        "a limited subscriber given more values than it requested",
        planted: flagged(.combineDemand) { delivering($0, 2, demand: 1) },
        control: !flagged(.combineDemand) { delivering($0, 2, demand: 2) }
    )
    check(
        .combineDuplicate,
        "a subscriber given the same value twice",
        planted: flagged(.combineDuplicate) { delivering($0, 2, demand: 2, repeatLast: true) },
        control: !flagged(.combineDuplicate) { delivering($0, 2, demand: 2) }
    )
    check(
        .combineAfterCancel,
        "a value after the subscriber's cancellation returned",
        planted: flagged(.combineAfterCancel) { delivering($0, 2, demand: 2, cancelAfter: 1) },
        control: !flagged(.combineAfterCancel) { delivering($0, 1, demand: 2, cancelAfter: 1) }
    )

    // A value of an earlier observation published after one of a later observation, and a regression within one.
    let order = ExplorerWorld()
    let older = order.makeValue(.delivered(registration: 1), attempt: 1)
    let newer = order.makeValue(.delivered(registration: 2), attempt: 2)
    let applied = order.makeValue(.applied(attempt: 2), attempt: 2)
    check(
        .revisionRegressed,
        "a value of an older observation, or a lower revision within one, published after a newer one",
        planted: order.publicationProblem(next: older.id, previous: newer.id, strict: true) != nil
            && order.publicationProblem(next: newer.id, previous: applied.id, strict: true) != nil,
        control: order.publicationProblem(next: newer.id, previous: older.id, strict: true) == nil
            && order.publicationProblem(next: applied.id, previous: newer.id, strict: true) == nil
    )

    // A subscriber's first value older than the snapshot shown when it attached; a value after the release.
    check(
        .combineSeed,
        "a subscriber's first value older than the snapshot shown at its attach",
        planted: flagged(.combineSeed) { world in
            let first = world.makeValue(.applied(attempt: nil), attempt: nil)
            let shown = world.makeValue(.applied(attempt: nil), attempt: nil)
            let late = subscriber(world, unlimited: true)
            late.shownAtAttachID = shown.id
            explorerCheckReceived(world, late, first)
        },
        control: !flagged(.combineSeed) { world in
            let shown = world.makeValue(.applied(attempt: nil), attempt: nil)
            let timely = subscriber(world, unlimited: true)
            timely.shownAtAttachID = shown.id
            explorerCheckReceived(world, timely, shown)
        }
    )
    check(
        .publishedAfterRelease,
        "a subscriber given a value after the presentation was deallocated",
        planted: flagged(.publishedAfterRelease) { world in
            world.state.withLock { $0.presentationGone = true }
            explorerCheckReceived(world, subscriber(world, unlimited: true), world.makeValue(.initial, attempt: nil))
        },
        control: !flagged(.publishedAfterRelease) { world in
            explorerCheckReceived(world, subscriber(world, unlimited: true), world.makeValue(.initial, attempt: nil))
        }
    )
    check(
        .combineFinish,
        "a subscriber attached after the release given a value",
        planted: flagged(.combineFinish) { world in
            let late = ExplorerSubscriber(index: 0, unlimited: true, shownAtAttach: 0, attachedAfterRelease: true)
            late.world = world
            explorerCheckReceived(world, late, world.makeValue(.initial, attempt: nil))
        },
        control: !flagged(.combineFinish) { world in
            explorerCheckReceived(world, subscriber(world, unlimited: true), world.makeValue(.initial, attempt: nil))
        }
    )

    // An unread element of a let-go registration destroyed while its slot is still occupied.
    func unread(freeFirst: Bool) -> Bool {
        flagged(.unreadBeforeSlotFree) { world in
            world.setContext(.call(attempt: 1))
            guard let registration = world.admit(host: 0) else { return }
            world.setContext(.spontaneous)
            var element: ExplorerShot? = world.makeValue(.delivered(registration: registration), attempt: 1)
            if let id = element?.id { world.offered(id, into: registration) }
            world.letGo([1])
            if freeFirst { world.freed(registration) }
            _ = element
            element = nil
            if !freeFirst { world.freed(registration) }
        }
    }
    check(
        .unreadBeforeSlotFree,
        "an unread element of a let-go registration released before its slot is free",
        planted: unread(freeFirst: false),
        control: !unread(freeFirst: true)
    )

    // An invented ingress delivery.
    check(
        .ingressDelivery,
        "a delivered value that was never staged",
        planted: explorerIngressMembershipProblem(id: 9, revision: 30, staged: [1, 2]) != nil,
        control: explorerIngressMembershipProblem(id: 2, revision: 20, staged: [1, 2]) == nil
    )
    return checks
}

/// A subscription that does nothing, for the self-check's subscribers.
final class ExplorerNullSubscription: Subscription {
    func request(_ demand: Subscribers.Demand) {}
    func cancel() {}
}

/// Holds one client value until a worker releases it, the planted off-main release of the self-check.
nonisolated final class ExplorerOffMainRelease: Sendable {
    private let slot: OSAllocatedUnfairLock<ExplorerShot?>
    init(_ value: ExplorerShot) { slot = OSAllocatedUnfairLock(initialState: value) }
    func release() {
        let taken = slot.withLock { $0.take() }
        _ = consume taken
    }
}
