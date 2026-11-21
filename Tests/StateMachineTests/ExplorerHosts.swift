import Dispatch
import Foundation
import StateMachine
import StateMachineUI
import os

/// A one-slot shared host the explorer controls.
///
/// Each registration delivers a seed at once and keeps its token, which the host can cancel itself on
/// a worker thread that parks inside the token's `onCancel`, before the slot is free, until the
/// harness lets it go on. The token frees the slot when its `onCancel` returns and then releases the
/// registration's callbacks, which ends the sequence for its consumer. The host keeps no client value.
nonisolated final class ExplorerHost: SharedStateMachineHost, Sendable {
    typealias Snapshot = ExplorerShot

    /// A worker's cancellation of one token, which it runs inside `onCancel` only once released.
    final class Park: Sendable {
        let progressed = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        let returned = DispatchSemaphore(value: 0)
        let entered = OSAllocatedUnfairLock(initialState: false)
    }
    private struct Kept: Sendable {
        var receive: (@Sendable (ExplorerShot) -> Void)?
        var finish: (@Sendable () -> Void)?
        var token: SnapshotSubscription?
        var park: Park?
    }
    private struct State: Sendable {
        var kept: [Int: Kept] = [:]
        var onMainCancel: (@Sendable () -> Void)?
        var onMainSite: (@Sendable (ExplorerHook) -> Void)?
        var deliversInCancellation = false
    }

    let index: Int
    let world: ExplorerWorld
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// When set, the slot is freed by the destructor of a lease the token's action captures, not by
    /// the action itself: the slot is free only once the token has released its action (44).
    let leaseMode: Bool

    init(_ index: Int, _ world: ExplorerWorld, leaseMode: Bool = false) {
        self.index = index
        self.world = world
        self.leaseMode = leaseMode
    }

    /// Runs on the main thread inside every `onCancel` that runs there, before the slot is freed.
    func armOnCancel(_ hook: @escaping @Sendable () -> Void) { state.withLock { $0.onMainCancel = hook } }
    /// Runs on the main thread at the host's armable sites: `snapshot()`, and a registration after its seed.
    func armSites(_ hook: @escaping @Sendable (ExplorerHook) -> Void) { state.withLock { $0.onMainSite = hook } }
    private func site(_ hook: ExplorerHook) {
        guard Thread.isMainThread, let site = state.withLock({ $0.onMainSite }) else { return }
        site(hook)
    }
    /// From now on, every `onCancel` delivers a new value to its registration before the slot is freed.
    func deliverInCancellations() { state.withLock { $0.deliversInCancellation = true } }

    func snapshot() -> ExplorerShot {
        let read = world.makeValue(.hostRead(host: index), attempt: world.state.withLock { $0.latestAttempt })
        site(.hostRead)
        return read
    }
    func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<ExplorerShot> { try sequence() }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (ExplorerShot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try SnapshotSequence<Projection> { (receive, finish) throws(SubscriptionFailure) in
            try register({ receive(transform($0)) }, finish)
        }
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (ExplorerShot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> { try snapshots(transform) }

    /// A registration of this host's slot; an unseeded one delivers nothing until the host offers (E7).
    func sequence(seeded: Bool = true) throws(SubscriptionFailure) -> SnapshotSequence<ExplorerShot> {
        try SnapshotSequence<ExplorerShot> { (receive, finish) throws(SubscriptionFailure) in
            try register(receive, finish, seeded: seeded)
        }
    }

    private func register(
        _ receive: @escaping @Sendable (ExplorerShot) -> Void,
        _ finish: @escaping @Sendable () -> Void,
        seeded: Bool = true
    ) throws(SubscriptionFailure) -> SnapshotSubscription {
        guard let id = world.admit(host: index) else { throw .capacityExceeded }
        if seeded {
            let seed = world.makeValue(.delivered(registration: id), attempt: world.registration(id)?.attempt)
            world.offered(seed.id, into: id)
            receive(seed)
        }
        defer { site(.hostSubscribe) }
        let token: SnapshotSubscription
        if leaseMode {
            let lease = ExplorerLease(world, id)
            token = SnapshotSubscription { [self, lease] in
                withExtendedLifetime(lease) {}
                cancelled(id, freeing: false)
            }
        } else {
            token = SnapshotSubscription { [self] in cancelled(id) }
        }
        state.withLock { $0.kept[id] = Kept(receive: receive, finish: finish, token: token) }
        return token
    }

    // The token's `onCancel`: parks when a worker of this host cancels it, then frees the slot and
    // releases the registration's callbacks.
    private func cancelled(_ id: Int, freeing: Bool = true) {
        world.cancelling(id)
        if Thread.isMainThread, let hook = state.withLock({ $0.onMainCancel }) { hook() }
        let park = state.withLock { $0.kept[id]?.park }
        if let park, !Thread.isMainThread {
            park.entered.withLock { $0 = true }
            park.progressed.signal()
            _ = explorerWait(park.proceed)
        }
        if state.withLock({ $0.deliversInCancellation }) { deliverInCancellation(id) }
        if freeing { world.freed(id) }
        // Released outside the lock: the callbacks' release ends the sequence for its consumer.
        let released = state.withLock { state -> Kept? in
            guard var kept = state.kept[id] else { return nil }
            let callbacks = Kept(receive: kept.receive, finish: kept.finish, token: nil, park: nil)
            kept.receive = nil
            kept.finish = nil
            state.kept[id] = kept
            return callbacks
        }
        withExtendedLifetime(released) {}
    }

    // A host that delivers once more from inside the cancellation, on the cancelling thread. The value is
    // the host's until `receive` returns, and its own reference goes right after. An offer on a worker
    // releases the unread value it displaces there, as `deliverElsewhere`'s does (latest-value delivery).
    private func deliverInCancellation(_ id: Int) {
        guard let receive = state.withLock({ $0.kept[id]?.receive }) else { return }
        let previous = Thread.isMainThread ? nil : world.registration(id)?.latestOffer
        var value: ExplorerShot? = world.makeValue(
            .delivered(registration: id),
            attempt: world.registration(id)?.attempt
        )
        guard let shot = value else { return }
        let valueID = shot.id
        world.offered(valueID, into: id)
        world.deliveredInCancellation(valueID)
        if let previous { world.state.withLock { $0.workerDisplaced = previous } }
        receive(shot)
        if previous != nil { world.state.withLock { $0.workerDisplaced = nil } }
        _ = consume shot
        world.hostReleasing(valueID, true)
        value = nil
        world.hostReleasing(valueID, false)
    }

    /// Offers registration `id` a new value with the revision of its latest offer (E1).
    @discardableResult func deliverEqual(to id: Int) -> Bool {
        guard let receive = state.withLock({ $0.kept[id]?.receive }),
            let latest = world.registration(id)?.latestOffer
        else { return false }
        let value = world.makeValue(
            .delivered(registration: id),
            attempt: world.registration(id)?.attempt,
            revision: world.revision(of: latest)
        )
        world.markEqualOffer(value.id)
        world.offered(value.id, into: id)
        receive(value)
        return true
    }
    /// Offers a new value to registration `id`, from the calling thread.
    @discardableResult func deliver(to id: Int) -> Bool {
        guard let receive = state.withLock({ $0.kept[id]?.receive }) else { return false }
        let value = world.makeValue(.delivered(registration: id), attempt: world.registration(id)?.attempt)
        world.offered(value.id, into: id)
        receive(value)
        return true
    }
    /// Offers a new value to registration `id` from a worker thread; `false` means stuck.
    func deliverElsewhere(to id: Int) -> Bool {
        guard let receive = state.withLock({ $0.kept[id]?.receive }) else { return true }
        let previous = world.registration(id)?.latestOffer
        let value = world.makeValue(.delivered(registration: id), attempt: world.registration(id)?.attempt)
        world.offered(value.id, into: id)
        world.state.withLock { $0.workerDisplaced = previous }
        let slot = OSAllocatedUnfairLock<ExplorerShot?>(initialState: value)
        _ = consume value
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global()
            .async {
                if let shot = slot.withLock({ $0.take() }) { receive(shot) }
                done.signal()
            }
        let ok = explorerWait(done)
        world.state.withLock { $0.workerDisplaced = nil }
        return ok
    }
    /// Finishes registration `id`, as an owner that closes does.
    @discardableResult func finish(_ id: Int) -> Bool {
        guard let finish = state.withLock({ $0.kept[id]?.finish }) else { return false }
        world.hostEnded(id, finished: true)
        finish()
        return true
    }
    /// Starts cancelling a registration's token on a worker.
    ///
    /// Returns once the worker is parked inside `onCancel`, or once the cancellation returned without
    /// running it; `false` means stuck.
    func beginCancelling(_ id: Int) -> Bool {
        let park = Park()
        guard
            let token = state.withLock({ state -> SnapshotSubscription? in
                state.kept[id]?.park = park
                return state.kept[id]?.token
            })
        else { return false }
        world.hostEnded(id)
        world.setParked(id, true)
        DispatchQueue.global()
            .async {
                token.cancel()
                park.returned.signal()
                park.progressed.signal()
            }
        guard explorerWait(park.progressed) else { return false }
        if !park.entered.withLock({ $0 }) { world.setParked(id, false) }
        return true
    }
    /// Lets a parked cancellation of registration `id` free the slot and return. `false`: stuck.
    func finishCancelling(_ id: Int) -> Bool {
        guard let park = state.withLock({ $0.kept[id]?.park }) else { return true }
        state.withLock { $0.kept[id]?.park = nil }
        park.proceed.signal()
        let ok = explorerWait(park.returned)
        world.setParked(id, false)
        return ok
    }
    /// Cancels a registration's token on the calling thread, the main thread for the explorer.
    @discardableResult func cancelHere(_ id: Int) -> Bool {
        guard let token = state.withLock({ $0.kept[id]?.token }) else { return false }
        world.hostEnded(id)
        token.cancel()
        return true
    }
    /// Releases what the host still keeps for its registrations: their tokens and callbacks.
    func forget() {
        let kept = state.withLock { state -> [Int: Kept] in
            defer { state.kept = [:] }
            return state.kept
        }
        withExtendedLifetime(kept) {}
    }
    var parked: [Int] { state.withLock { $0.kept.filter { $0.value.park != nil }.keys.sorted() } }
}

/// Frees a registration's slot when it is destroyed, wherever that happens.
nonisolated final class ExplorerLease: Sendable {
    let world: ExplorerWorld
    let id: Int
    init(_ world: ExplorerWorld, _ id: Int) {
        self.world = world
        self.id = id
    }
    deinit { world.freed(id) }
}

/// The actor an isolated fake host is confined to.
actor ExplorerIsland {
    func observe(_ presentation: SnapshotObservableObject<ExplorerShot>, _ host: ExplorerIslandHost) async {
        try? await presentation.observe(host)
    }
    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    func observe(_ presentation: SnapshotPresentation<ExplorerShot>, _ host: ExplorerIslandHost) async {
        try? await presentation.observe(host)
    }
}

/// A one-slot host confined to `ExplorerIsland` that shares host A's slot.
///
/// Its registration call registers with host A, then parks the island's thread until the harness lets
/// it return the sequence, so the harness can cancel that registration's token, or replace the
/// observation, before the hand-off reaches the presentation.
nonisolated final class ExplorerIslandHost: IsolatedStateMachineHost, Sendable {
    typealias Owner = ExplorerIsland
    typealias Snapshot = ExplorerShot

    let host: ExplorerHost
    // The parked calls and the registrations they hold, which are not the presentation's until returned.
    private let state = OSAllocatedUnfairLock(
        initialState: (registered: false, returning: [DispatchSemaphore](), withheld: [Int]())
    )

    init(_ host: ExplorerHost) { self.host = host }

    /// Whether a registration call has registered and parked since the last `letReturn`.
    var registered: Bool { state.withLock { $0.registered } }
    /// Lets every parked registration call return its sequence.
    func letReturn() {
        let (parked, withheld) = state.withLock { state in
            defer {
                state.returning = []
                state.withheld = []
                state.registered = false
            }
            return (state.returning, state.withheld)
        }
        for id in withheld { host.world.withhold(id, false) }
        for semaphore in parked { semaphore.signal() }
    }

    func snapshot(isolation: isolated ExplorerIsland) -> ExplorerShot { host.snapshot() }
    func subscribe(
        _ receive: @escaping (ExplorerShot) -> Void,
        onFinish: @escaping () -> Void,
        isolation: isolated ExplorerIsland
    ) throws(SubscriptionFailure) -> IsolatedSnapshotSubscription<ExplorerIsland> { throw .capacityExceeded }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping (ExplorerShot) -> Projection,
        isolation: isolated ExplorerIsland
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        let sequence = try host.sequence()
        let returning = DispatchSemaphore(value: 0)
        let id = host.world.slot(of: host.index)
        if let id { host.world.withhold(id, true) }
        state.withLock { state in
            state.registered = true
            state.returning.append(returning)
            if let id { state.withheld.append(id) }
        }
        _ = explorerWait(returning)
        // The presentation registers the snapshots themselves.
        guard let projected = sequence as? SnapshotSequence<Projection> else { throw .capacityExceeded }
        return projected
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping (ExplorerShot) -> Projection,
        isolation: isolated ExplorerIsland
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> { try snapshots(transform, isolation: isolation) }
}

/// A one-slot `ActorStateMachineHost` that shares host A's slot and runs on its caller's actor.
///
/// Its registration call registers with host A, or throws the refusal at once, and then suspends until
/// the harness lets it return the sequence, so the harness can end, replace, or cancel the observation
/// while the owner is still inside that call.
nonisolated final class ExplorerActorHost: ActorStateMachineHost, Sendable {
    typealias Snapshot = ExplorerShot

    let host: ExplorerHost
    private let parked = OSAllocatedUnfairLock(initialState: [(id: Int?, resume: CheckedContinuation<Void, Never>)]())
    private let calls = OSAllocatedUnfairLock(initialState: Set<Int>())
    /// How many registration calls have reached their end or their suspension, and how many returned.
    let reached = OSAllocatedUnfairLock(initialState: 0)
    let returned = OSAllocatedUnfairLock(initialState: 0)

    init(_ host: ExplorerHost) { self.host = host }

    /// The number of registration calls waiting to return.
    var waiting: Int { parked.withLock { $0.count } }
    /// Lets the oldest waiting registration call return its sequence.
    func letOldestReturn() {
        let first = parked.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        guard let first else { return }
        if let id = first.id { host.world.withhold(id, false) }
        first.resume.resume()
    }

    nonisolated(nonsending) func snapshot() async -> ExplorerShot { host.snapshot() }
    nonisolated(nonsending) func snapshots() async throws(SubscriptionFailure) -> SnapshotSequence<ExplorerShot> {
        // An attempt's first registration call is a registering call; a later one is a retry, which I8
        // checks as a registration the presentation makes by itself.
        let world = host.world
        let attempt = world.state.withLock { $0.latestAttempt }
        let first = calls.withLock { calls in attempt.map { calls.insert($0).inserted } ?? false }
        if first, let attempt { world.setContext(.call(attempt: attempt)) }
        // An async host form waits for earlier registrations and then registers once.
        if !first, let attempt {
            world.violate(
                .lateAdmission,
                "the asynchronous observation of attempt \(attempt) called its actor host's registration again"
            )
        }
        defer { if first { world.setContext(.spontaneous) } }
        // The call runs wherever the presentation's call of this requirement runs, which can be the
        // cooperative pool; the harness waits for this count to change before it goes on.
        defer { reached.withLock { $0 += 1 } }
        let sequence = try host.sequence()
        let id = host.world.slot(of: host.index)
        if let id { host.world.withhold(id, true) }
        await withCheckedContinuation { continuation in
            parked.withLock { $0.append((id, continuation)) }
            reached.withLock { $0 += 1 }
        }
        returned.withLock { $0 += 1 }
        return sequence
    }
    nonisolated(nonsending) func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (ExplorerShot) -> Projection
    ) async throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        guard let projected = try await snapshots() as? SnapshotSequence<Projection> else { throw .capacityExceeded }
        return projected
    }
    nonisolated(nonsending) func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (ExplorerShot) -> Projection
    ) async throws(SubscriptionFailure) -> SnapshotSequence<Projection> { try await snapshots(transform) }
}
