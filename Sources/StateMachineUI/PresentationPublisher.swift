import Combine
import StateMachine
import os

/// A Combine publisher of the snapshots an `ObservableObject` presentation shows, or of a `Sendable`
/// projection of each.
///
/// ``SnapshotObservableObject/presentedSnapshots`` and ``StateMachineObservableObject/presentedSnapshots``
/// publish the snapshots themselves when they are `Sendable`, and
/// ``SnapshotObservableObject/presentedSnapshots(projecting:)`` and
/// ``StateMachineObservableObject/presentedSnapshots(projecting:)`` publish a projection that the
/// presentation computes on the main actor, which is how a snapshot confined to the main actor reaches
/// Combine.
///
/// A subscriber first receives the snapshot the presentation shows when the subscriber attaches, then
/// each snapshot the presentation shows afterward. An immediately deliverable change arrives after
/// `objectWillChange` and before `snapshot` returns it. A buffered one arrives once the subscriber has
/// demand and its previous callback has returned, when `snapshot` may already return it, so render the
/// value delivered. The publisher registers the subscriber and hands it its subscription before it
/// reads that first snapshot, so a snapshot shown from inside the subscriber's subscription, or while
/// its first value is projected, replaces that first value, and one shown from the subscriber's first
/// value reaches it next. The publisher keeps one pending value for each subscriber, which a newer one
/// replaces, so a subscriber that requests slowly receives the latest value and never an older one.
///
/// A subscriber receives the presentation's publications in the order the presentation shows them.
/// Revision order belongs to one observation: within it, each value a subscriber receives has a higher
/// revision than the one before, and no revision arrives twice. A passive presentation that starts
/// observing another owner shows that owner's current snapshot as a new baseline, so the first value of
/// the new observation can carry a lower or equal revision, as `9` from one owner followed by `0` from
/// another.
///
/// The publisher belongs to the presentation, not to one observation: it stays open across
/// `stopObserving()` and every later observation, and it does not keep the presentation alive. Once the
/// presentation's release has begun, it delivers no value: it discards a value its demand has not
/// reached, a later main-actor turn finishes every subscriber, and a subscriber that attaches after the
/// release receives `.finished` at once. A client that keeps the publisher can therefore tell a presentation that is not observing from
/// one that can never publish again.
///
/// Subscription, delivery, and completion happen on the main actor. Subscribing off the main actor stops
/// the program instead of racing; requesting demand and cancelling are accepted from any thread. No
/// value or completion follows a cancellation that returned before the publisher decided a delivery; a
/// cancellation on another thread that races a delivery already decided on the main actor can return
/// before it. `Output` is `Sendable`, because a Combine pipeline can move each value to another thread,
/// as `receive(on:)` does.
@MainActor public struct PresentationPublisher<Output: Sendable> {
    private let attach: @MainActor (AnySubscriber<Output, Never>) -> Void

    init<Snapshot>(_ feed: PresentationFeed<Snapshot>, _ transform: @escaping @MainActor (Snapshot) -> Output) {
        attach = { feed.attach($0, transform) }
    }
}

extension PresentationPublisher: @MainActor Publisher {
    /// Delivery never fails.
    public typealias Failure = Never

    /// Attaches a subscriber, or finishes it at once when the presentation has been released.
    public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
        // Combine does not check isolation, so a subscription off the main actor stops here rather than
        // racing. The check asserts the isolation this method already requires; it decides nothing.
        MainActor.assumeIsolated {}
        attach(AnySubscriber(subscriber))
    }
}

/// The subscribers of one presentation's publisher, which the presentation tells of each snapshot it
/// shows, and which finishes them when the presentation is released.
///
/// It holds no snapshot: it reads the one the presentation shows through `current`, which captures the
/// presentation weakly and so reads `nil` once the presentation's release has begun.
@MainActor final class PresentationFeed<Snapshot> {
    /// The snapshot the presentation shows, or `nil` once the presentation is being released.
    var current: @MainActor () -> Snapshot? = { nil }
    // In attachment order. An ended listener stays until enough have ended to compact them in one pass,
    // which keeps removal linear in the number of listeners.
    private var listeners: [any PresentationListener<Snapshot>] = []
    private var ended = 0
    // Whether `send` is telling the listeners now, which defers compaction to it.
    private var sending = false
    private var finished = false

    /// Attaches a subscriber of the values `transform` projects.
    ///
    /// The subscriber is registered first, so a snapshot shown while it takes its subscription or while
    /// its first value is projected is offered to it in turn.
    func attach<Output: Sendable>(
        _ subscriber: AnySubscriber<Output, Never>,
        _ transform: @escaping @MainActor (Snapshot) -> Output
    ) {
        guard !finished else {
            subscriber.receive(subscription: Subscriptions.empty)
            subscriber.receive(completion: .finished)
            return
        }
        let channel = PresentationChannel(subscriber, transform: transform, feed: self)
        listeners.append(channel)
        channel.drain()
    }
    /// Offers a snapshot the presentation is about to assign to every subscriber, including one that
    /// attaches while this runs; that subscriber's first value is the snapshot still assigned, so this
    /// one follows it.
    func send(_ snapshot: Snapshot) {
        let outer = sending
        sending = true
        var index = 0
        while index < listeners.count {
            listeners[index].offer(snapshot)
            index += 1
        }
        sending = outer
        compact()
    }
    /// Finishes every subscriber, and every later one at once, because the presentation was released.
    func finish() {
        guard !finished else { return }
        finished = true
        let ending = listeners
        listeners = []
        ended = 0
        for listener in ending { listener.finish() }
    }
    fileprivate func noteEnded() {
        ended += 1
        compact()
    }
    private func compact() {
        guard !sending, ended > 0, ended * 2 >= listeners.count else { return }
        listeners.removeAll(where: \.isEnded)
        ended = 0
    }
}

/// One subscriber of a presentation's publisher, as the feed sees it.
@MainActor private protocol PresentationListener<Snapshot>: AnyObject {
    associatedtype Snapshot
    var isEnded: Bool { get }
    func offer(_ snapshot: Snapshot)
    func finish()
}

/// What one subscriber receives next, confined to the main actor.
///
/// `drain` is the only place the subscriber is called with its subscription or a value, and one drain
/// runs at a time: an offer made while the subscriber is being called, its seed included, replaces
/// `next` for that drain to deliver once the call returns. Every delivery reads the cancellation and
/// claims a unit of demand first, with no client code in between.
@MainActor private final class PresentationChannel<Snapshot, Output: Sendable>: PresentationListener {
    private enum Next {
        /// The subscriber has not yet received its subscription.
        case subscription
        /// The subscriber has its subscription, and the snapshot shown is its first value unless the
        /// presentation offers a newer one first.
        case seed
        /// A value waiting for demand, which a newer offer replaces.
        case value(Output)
        /// Nothing until the presentation offers a snapshot.
        case none
    }

    private var downstream: AnySubscriber<Output, Never>?
    private var transform: (@MainActor (Snapshot) -> Output)?
    private weak var feed: PresentationFeed<Snapshot>?
    private lazy var demand = PresentationDemand { [weak self] in Task { @MainActor in self?.wake() } }
    private var next = Next.subscription
    private var draining = false
    private(set) var isEnded = false

    init(
        _ downstream: AnySubscriber<Output, Never>,
        transform: @escaping @MainActor (Snapshot) -> Output,
        feed: PresentationFeed<Snapshot>
    ) {
        self.downstream = downstream
        self.transform = transform
        self.feed = feed
    }

    func offer(_ snapshot: Snapshot) {
        guard !isEnded, let transform else { return }
        guard !demand.isCancelled else {
            end()
            return
        }
        let value = transform(snapshot)
        guard !isEnded else { return }
        let displaced = exchange(&next, with: .value(value))
        withExtendedLifetime(displaced) {}
        drain()
    }
    func finish() {
        guard !isEnded else { return }
        let finishing = downstream
        let cancelled = demand.isCancelled
        end()
        if !cancelled { finishing?.receive(completion: .finished) }
    }
    // Runs after a request for demand or a cancellation from any thread.
    private func wake() {
        demand.unschedule()
        drain()
    }
    func drain() {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !isEnded, let downstream, let transform {
            if demand.isCancelled {
                end()
                return
            }
            switch next {
            case .subscription:
                next = .seed
                downstream.receive(subscription: demand)
            case .seed:
                next = .none
                guard let seed = feed?.current() else {
                    finish()
                    return
                }
                let first = transform(seed)
                // A snapshot offered while `transform` ran is newer than the one it read.
                if !isEnded, case .none = next { next = .value(first) }
            case .value:
                // Nothing is delivered once the presentation's release has begun: the value waiting for
                // demand is discarded, and the turn that disposes of the presentation finishes.
                guard feed?.current() != nil else {
                    let discarded = exchange(&next, with: .none)
                    withExtendedLifetime(discarded) {}
                    return
                }
                guard demand.claim(), case .value(let value) = exchange(&next, with: .none) else { return }
                demand.add(downstream.receive(value))
            case .none:
                return
            }
        }
    }
    // Releases the subscriber, the projection, and the pending value after the last callback, breaking
    // the subscriber's reference cycle with its subscription.
    private func end() {
        guard !isEnded else { return }
        isEnded = true
        let released = (downstream, transform, exchange(&next, with: .none))
        downstream = nil
        transform = nil
        withExtendedLifetime(released) {}
        feed?.noteEnded()
    }
}

/// The demand and cancellation of one subscription, which Combine may change from any thread.
///
/// It holds no value. A request or a cancellation made outside a delivery schedules one main-actor turn
/// that continues delivery, or ends the subscription.
nonisolated private final class PresentationDemand: Subscription, Sendable {
    private struct State: Sendable {
        var demand = Subscribers.Demand.none
        var cancelled = false
        var scheduled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let wake: @Sendable () -> Void

    init(wake: @escaping @Sendable () -> Void) { self.wake = wake }

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    /// Consumes one unit of demand of a subscription that has not been cancelled, and reports whether
    /// there was one to consume.
    func claim() -> Bool {
        state.withLock { state in
            guard !state.cancelled, state.demand > 0 else { return false }
            state.demand -= 1
            return true
        }
    }
    /// Adds the demand a delivery returned, which the running delivery loop consumes.
    func add(_ demand: Subscribers.Demand) {
        guard demand > 0 else { return }
        state.withLock { state in
            if !state.cancelled { state.demand += demand }
        }
    }
    func unschedule() { state.withLock { $0.scheduled = false } }

    func request(_ demand: Subscribers.Demand) {
        guard demand > 0 else { return }
        let schedule = state.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            state.demand += demand
            defer { state.scheduled = true }
            return !state.scheduled
        }
        if schedule { wake() }
    }
    func cancel() {
        let first = state.withLock { state -> Bool in
            guard !state.cancelled else { return false }
            state.cancelled = true
            return true
        }
        if first { wake() }
    }
}
