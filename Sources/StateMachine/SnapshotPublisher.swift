#if canImport(Combine)
import Combine
import os

/// A Combine publisher of one owner's snapshots, delivered on the main actor.
///
/// Creating the publisher registers one observer, so it holds one of the owner's subscriber slots
/// from creation. Its subscriber receives the snapshot current at registration, unless a newer one
/// has replaced it, and then each newer snapshot as demand allows. The publisher keeps only one
/// pending snapshot and replaces it with any newer one, so a subscriber that requests slowly
/// receives the latest value and never an older one. The value a unit of demand reaches is the
/// newest the owner had handed over when the publisher claimed that unit, or a newer one, even when
/// it is still on its way to the main actor when the subscriber asks.
///
/// After the owner's closed snapshot, which waits for demand, the publisher finishes. An owner
/// released without closing first processes every batch it accepted and delivers each here as usual,
/// then the publisher finishes at once without a closed snapshot and discards every undelivered
/// ordinary value, even while a delivery is still projecting a snapshot. Demand first made after
/// that receives only the completion, and any unit of demand that a discarded value would have spent
/// is kept. Release ends every publisher of the owner at one instant, so once any of them can finish
/// for it, none begins an ordinary delivery.
///
/// The publisher has one subscriber, and any later subscriber receives `.finished` at once.
/// Cancelling the subscription frees the slot before returning from any thread, as does releasing a
/// publisher that was never subscribed. No value or completion is delivered after a cancellation
/// that returned before the publisher decided that delivery, including one made by the destructor of
/// a value released while deciding it. A cancellation on another thread that races a delivery
/// already decided on the main actor can still return before that delivery runs.
///
/// Subscription, delivery, and completion happen on the main actor. The publisher delivers at most
/// 32 values in one main-actor turn, counting deliveries from subscription, owner hand-offs, and
/// demand requests together, and continues on a later turn with the outstanding demand, pending
/// value, and finish. Neither a subscriber that triggers another value on each receipt nor an owner
/// that hands over many values in one turn can hold the main actor, and a cancellation between those
/// turns delivers nothing more. Subscribing off the main actor stops the program instead of racing,
/// while requesting demand and cancelling are accepted from any thread. An owner released on another
/// thread while the main actor delivers a value decided before the release can return before that
/// delivery, just as a cancellation can.
///
/// `Output` is `Sendable`, because a Combine pipeline can move each value to another thread, as
/// `receive(on:)` does. An owner whose snapshots are not `Sendable` publishes a `Sendable` projection.
@MainActor public struct SnapshotPublisher<Output: Sendable> {
    /// Demand and cancellation, which Combine may change from any thread.
    fileprivate final class Control: Subscription, Sendable {
        private struct State: Sendable {
            var demand = Subscribers.Demand.none
            var cancelled = false
            var scheduled = false
        }
        private let state = AtomicRecordStorage(State())
        private let channel: Channel
        private let lifetime: Lifetime

        init(_ channel: Channel, lifetime: Lifetime) {
            self.channel = channel
            self.lifetime = lifetime
        }

        var isCancelled: Bool { state.load().value.cancelled }

        /// Whether the subscriber has demand that a delivery step has not claimed, and has not cancelled.
        var hasDemand: Bool {
            let current = state.load().value
            return !current.cancelled && current.demand > 0
        }

        /// Consumes one unit of demand of a subscription that has not been cancelled, and reports
        /// whether there was one to consume.
        func claim() -> Bool {
            while true {
                let previous = state.load()
                guard !previous.value.cancelled, previous.value.demand > 0 else { return false }
                var next = previous.value
                next.demand -= 1
                if state.install(.init(next), replacing: previous) { return true }
            }
        }

        /// Adds demand from outside the delivery loop and reports whether the caller must schedule a
        /// delivery turn, since the first addition since the last turn reserves the next one.
        func reserve(_ demand: Subscribers.Demand) -> Bool {
            guard demand > 0 else { return false }
            while true {
                let previous = state.load()
                guard !previous.value.cancelled else { return false }
                var next = previous.value
                next.demand += demand
                let schedule = !next.scheduled
                next.scheduled = true
                if state.install(.init(next), replacing: previous) { return schedule }
            }
        }

        /// Adds the demand a delivery returned.
        ///
        /// The running delivery loop consumes it, so it reserves no turn.
        func add(_ demand: Subscribers.Demand) {
            guard demand > 0 else { return }
            while true {
                let previous = state.load()
                guard !previous.value.cancelled else { return }
                var next = previous.value
                next.demand += demand
                if state.install(.init(next), replacing: previous) { return }
            }
        }

        func clearScheduled() {
            while true {
                let previous = state.load()
                guard previous.value.scheduled else { return }
                var next = previous.value
                next.scheduled = false
                if state.install(.init(next), replacing: previous) { return }
            }
        }

        func request(_ demand: Subscribers.Demand) {
            guard reserve(demand) else { return }
            Task { @MainActor [channel] in channel.wake() }
        }

        // The registration's gate closes before the flag is set, so every call that returns, including
        // one that finds the subscription already cancelled, returns after the owner stopped counting it.
        func cancel() {
            lifetime.close()
            while true {
                let previous = state.load()
                guard !previous.value.cancelled else { return }
                var next = previous.value
                next.cancelled = true
                if state.install(.init(next), replacing: previous) { break }
            }
            lifetime.cancel()
            Task { @MainActor [channel] in channel.wake() }
        }
    }

    /// The registration with the owner, cancelled once and on release.
    fileprivate final class Lifetime: Sendable {
        enum Registration: Sendable {
            case shared(SnapshotSubscription)
            case mainActor(MainActorSnapshotSubscription, RuntimeRegistrationGate)
        }
        private let registration: Registration

        init(_ registration: Registration) { self.registration = registration }

        /// Stops the owner's delivery and frees its slot when the owner admits through the
        /// registration's gate, ahead of ``cancel()``.
        func close() {
            switch registration {
            case .shared(let token): token.gate?.close()
            case .mainActor(_, let gate): gate.close()
            }
        }
        // Closing a main-actor registration's gate frees its slot at once, and the token removes it on the main actor.
        func cancel() {
            switch registration {
            case .shared(let token): token.cancel()
            case .mainActor(let token, let gate):
                gate.close()
                Task { @MainActor in token.cancel() }
            }
        }
        deinit { cancel() }
    }

    /// The pending snapshot and the subscriber, confined to the main actor.
    ///
    /// Every delivery decision is one step of ``drain()``. It claims one unit of the subscriber's
    /// demand, then takes the newest value and any finish from the ingress and applies the owner's
    /// release, releasing the values that replaces, and repeats that until a pass releases nothing,
    /// since a released value's destructor can hand over another value, release the owner, request
    /// demand, or cancel. Only then does it read the cancellation, choose the value, and check the
    /// release again before delivering an ordinary value, with no client code in between. No decision
    /// rests on a fact read before client code ran.
    @MainActor fileprivate final class Channel {
        // The owner's lifetime gate, shared by every publisher of the owner. It stays open until the
        // owner is released without closing, which closes it once before notifying any registration so
        // after one publisher can finish, no publisher can begin an ordinary delivery. Every value and
        // finish the owner delivered before that release reaches the ingress first, so a step that
        // finds the gate closed and then takes the ingress has everything the owner promised. A
        // `Sendable` owner closes it even while a delivery is in progress, while a confined owner's
        // deliveries run in its own turn.
        private let source: RuntimeRegistrationGate
        // The hand-off from a `Sendable` owner. A scheduled hand-off turn retains it while it holds a
        // value or a finish, so a value is never lost when the owner releases the callbacks.
        private weak var ingress: SnapshotPublisherIngress<Output>?
        private var downstream: AnySubscriber<Output, Never>?
        private var control: Control?
        private var pending: Output?
        // Whether the pending value projects the owner's closed snapshot, which finishing keeps for demand.
        private var pendingIsFinal = false
        private var finished = false
        private var claimed = false
        private var ended = false
        private var delivering = false
        // The values the channel may still deliver before a later main-actor job refills it. Every
        // entry into delivery spends from it, the attachment, each offer and hand-off, and each demand
        // wake alike, so one turn delivers at most `deliveriesPerTurn` values however often the owner
        // offers and the subscriber reenters within it.
        private var remaining = Channel.deliveriesPerTurn
        // Whether a refill is scheduled. The first value spent from a full allowance schedules it, so
        // it runs as a job of its own after the turn that spent it, and an empty allowance always has
        // one scheduled to continue delivery.
        private var refilling = false

        nonisolated init(source: RuntimeRegistrationGate) { self.source = source }

        func connect(_ ingress: SnapshotPublisherIngress<Output>) { self.ingress = ingress }

        func offer(_ value: Output, final: Bool) {
            let released = stage(value, final: final)
            withExtendedLifetime(released) {}
            drain()
        }

        // Returns the value that will not reach the subscriber, either the displaced pending value or
        // `value` itself after the finish, for the caller to release once the channel is consistent.
        private func stage(_ value: Output, final: Bool) -> Output? {
            guard !finished, !ended else { return value }
            let displaced = pending
            pending = value
            pendingIsFinal = final
            return displaced
        }

        // Closing promises its closed snapshot, so a pending final value waits for demand. An owner
        // released without closing promises nothing more, so an undelivered ordinary value is dropped
        // and the subscriber finishes at once.
        func finish() {
            let released = settleFinish()
            withExtendedLifetime(released) {}
            drain()
        }

        private func settleFinish() -> Output? {
            guard !finished else { return nil }
            finished = true
            guard !pendingIsFinal else { return nil }
            let discarded = pending
            pending = nil
            return discarded
        }

        /// Moves what the ingress holds into the channel and returns the values it releases.
        ///
        /// Its newest value replaces an older pending one, and its finish settles the channel. A finish
        /// without the closed snapshot promises nothing more, so an ordinary value that reached the
        /// ingress with it is discarded.
        private func absorb(_ handed: consuming SnapshotPublisherIngress<Output>.Handed) -> [Output] {
            var released: [Output] = []
            if let value = handed.value {
                if value.final || !handed.finished {
                    if let displaced = stage(value.value, final: value.final) { released.append(displaced) }
                } else {
                    released.append(value.value)
                }
            }
            if handed.finished, let discarded = settleFinish() { released.append(discarded) }
            return released
        }

        /// Absorbs what a hand-off turn took from the ingress, then runs a delivery step.
        fileprivate func handOff(_ handed: SnapshotPublisherIngress<Output>.Handed) {
            let released = absorb(handed)
            withExtendedLifetime(released) {}
            drain()
        }

        func attach(_ subscriber: AnySubscriber<Output, Never>, lifetime: Lifetime) {
            guard !claimed else {
                subscriber.receive(subscription: Subscriptions.empty)
                subscriber.receive(completion: .finished)
                return
            }
            claimed = true
            let control = Control(self, lifetime: lifetime)
            self.control = control
            downstream = subscriber
            subscriber.receive(subscription: control)
            drain()
        }

        func wake() {
            control?.clearScheduled()
            drain()
        }

        /// The number of values one main-actor turn delivers, and the number of passes one decision
        /// settles, before a later turn continues.
        nonisolated private static var deliveriesPerTurn: Int { 32 }

        // Schedules the job that restores the allowance and continues delivery with the demand, the
        // pending value, and the finish that earlier turns left where they are.
        private func scheduleRefill() {
            guard !refilling else { return }
            refilling = true
            Task { @MainActor [self] in
                refilling = false
                remaining = Self.deliveriesPerTurn
                drain()
            }
        }
        // Gives up the rest of the turn's allowance so the refill continues on a later turn.
        private func yieldTurn() {
            remaining = 0
            scheduleRefill()
        }

        // The owner was released without closing, and its lifetime gate is already closed.
        func released() { drain() }

        // One delivery loop runs at a time, so any value offered while the subscriber is receiving
        // waits for it. Each pass is one step. One unit of demand is claimed first so the value
        // spending it is the newest the owner had handed over by then or newer. A unit that no value
        // spends, because none is pending or the owner's release discarded it, is returned. Once the
        // turn's allowance is spent the loop stops, leaving the demand and pending value for the
        // refill, so a subscriber that makes the owner hand over another value from each one it
        // receives cannot hold the main actor.
        private func drain() {
            guard !delivering, !ended, let control, let downstream else { return }
            delivering = true
            defer { delivering = false }
            while true {
                if control.isCancelled {
                    end()
                    return
                }
                guard remaining > 0 else { return }
                let claimed = control.claim()
                guard settle() else {
                    // Destructors kept handing over values, so a later turn continues.
                    if claimed { control.add(.max(1)) }
                    yieldTurn()
                    return
                }
                // The last pass of `settle()` ran no client code, so nothing can change the decision
                // between here and the subscriber's call.
                if control.isCancelled {
                    end()
                    return
                }
                guard let value = pending else {
                    if claimed { control.add(.max(1)) }
                    if finished {
                        end()
                        downstream.receive(completion: .finished)
                    }
                    return
                }
                guard claimed else {
                    // A destructor that ran while settling may have requested the demand.
                    if control.hasDemand { continue }
                    return
                }
                // Demand first made after the release cannot have been claimed before this check,
                // so it never reaches an ordinary value, and the next pass settles the finish.
                if !pendingIsFinal, !source.isOpen {
                    control.add(.max(1))
                    continue
                }
                pending = nil
                pendingIsFinal = false
                remaining -= 1
                scheduleRefill()
                DecidedDeliveryPause.reached()
                control.add(downstream.receive(value))
            }
        }

        // Takes the ingress, and applies the owner's release, until a pass releases no value, and
        // reports whether it got there within its passes. A released value's destructor runs between
        // passes, so a pass that releases nothing is the last thing before the step decides.
        private func settle() -> Bool {
            for _ in 0 ..< Self.deliveriesPerTurn {
                var released: [Output] = []
                if let ingress { released += absorb(ingress.take()) }
                // The release follows everything the owner delivered, so the ingress is taken again
                // after the closed gate is seen to keep any closed snapshot delivered before it.
                if !source.isOpen {
                    if let ingress { released += absorb(ingress.take()) }
                    if let discarded = settleFinish() { released.append(discarded) }
                }
                if released.isEmpty { return true }
                released.removeAll()
            }
            return false
        }

        // Releases the subscriber and the pending value after the last callback, breaking the
        // subscriber's reference cycle with its subscription.
        private func end() {
            ended = true
            let released = (downstream, control, pending)
            downstream = nil
            control = nil
            pending = nil
            withExtendedLifetime(released) {}
        }
    }

    private let channel: Channel
    private let lifetime: Lifetime

    private init(_ channel: Channel, _ lifetime: Lifetime) {
        self.channel = channel
        self.lifetime = lifetime
    }

    /// Registers with a `MainActor` owner through `register`, projecting each snapshot with `transform`.
    ///
    /// `isFinal` reports whether a snapshot is the owner's closed snapshot. `ownerLifetime` is the
    /// owner's own gate, which it closes once, first, when released without closing, before
    /// cancelling any worker or releasing any callback. It then finishes the registration on a later
    /// main-actor turn. A delivery runs inside the owner's own turn, which retains it, so no
    /// delivery is in progress when the owner is released.
    package init<Raw>(
        mainActor transform: @escaping @MainActor (Raw) -> Output,
        isFinal: @escaping @MainActor (Raw) -> Bool,
        ownerLifetime: RuntimeRegistrationGate,
        register: (
            _ receive: @escaping @MainActor (Raw) -> Void,
            _ finish: @escaping @MainActor () -> Void,
            _ gate: RuntimeRegistrationGate
        ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription
    ) throws(SubscriptionFailure) {
        let channel = Channel(source: ownerLifetime)
        let gate = RuntimeRegistrationGate()
        let token = try register(
            { snapshot in channel.offer(transform(snapshot), final: isFinal(snapshot)) },
            { channel.finish() },
            gate
        )
        self.init(channel, Lifetime(.mainActor(token, gate)))
    }

    /// Creates the channel and ingress of a `Sendable` owner's registration, the receive and finish
    /// callbacks that feed them, and the release notice that wakes the channel on the main actor.
    private static func ingress<Raw>(
        _ transform: @escaping @Sendable (Raw) -> Output,
        isFinal: @escaping @Sendable (Raw) -> Bool,
        ownerLifetime: RuntimeRegistrationGate
    ) -> (Channel, receive: @Sendable (Raw) -> Void, finish: @Sendable () -> Void, released: @Sendable () -> Void) {
        let channel = Channel(source: ownerLifetime)
        let ingress = SnapshotPublisherIngress(channel)
        channel.connect(ingress)
        return (
            channel,
            { raw in ingress.offer(transform(raw), final: isFinal(raw)) },
            { ingress.finish() },
            { Task { @MainActor [channel] in channel.released() } }
        )
    }

    /// Registers with a `Sendable` owner through `register`, projecting each snapshot with `transform`
    /// on the owner's delivery path before it moves to the main actor.
    ///
    /// `isFinal` reports whether a snapshot is the owner's closed snapshot. `ownerLifetime` is the
    /// owner's own gate, shared by every publisher of that owner. An owner released without closing
    /// closes it once, first, even while a delivery is still in progress, so a delivery cannot keep
    /// the publisher open after its owner is gone. The owner then runs the third callback, which wakes
    /// the channel on the main actor.
    package init<Raw>(
        _ transform: @escaping @Sendable (Raw) -> Output,
        isFinal: @escaping @Sendable (Raw) -> Bool,
        ownerLifetime: RuntimeRegistrationGate,
        register: (
            _ receive: @escaping @Sendable (Raw) -> Void,
            _ finish: @escaping @Sendable () -> Void,
            _ released: @escaping @Sendable () -> Void
        ) throws(SubscriptionFailure) -> SnapshotSubscription
    ) throws(SubscriptionFailure) where Output: Sendable {
        let (channel, receive, finish, released) = Self.ingress(
            transform,
            isFinal: isFinal,
            ownerLifetime: ownerLifetime
        )
        let token = try register(receive, finish, released)
        self.init(channel, Lifetime(.shared(token)))
    }

    /// Registers with an actor owner through `register`, which awaits the actor.
    ///
    /// `isFinal` reports whether a snapshot is the owner's closed snapshot. `ownerLifetime` is the
    /// owner's own gate, which an owner released without closing closes once, first, before
    /// cancelling any worker or releasing any callback, and then runs the third callback.
    package init<Raw>(
        actor transform: @escaping @Sendable (Raw) -> Output,
        isFinal: @escaping @Sendable (Raw) -> Bool,
        ownerLifetime: RuntimeRegistrationGate,
        register: (
            _ receive: @escaping @Sendable (Raw) -> Void,
            _ finish: @escaping @Sendable () -> Void,
            _ released: @escaping @Sendable () -> Void
        ) async throws(SubscriptionFailure) -> SnapshotSubscription
    ) async throws(SubscriptionFailure) where Output: Sendable {
        let (channel, receive, finish, released) = Self.ingress(
            transform,
            isFinal: isFinal,
            ownerLifetime: ownerLifetime
        )
        let token = try await register(receive, finish, released)
        self.init(channel, Lifetime(.shared(token)))
    }
}

/// Forwards a `Sendable` owner's callbacks to the main actor, keeping only the latest snapshot.
///
/// The channel takes what it holds at the start of every delivery step, and a hand-off turn on the
/// main actor takes it when no step runs. The turn stays scheduled while the ingress holds a value or
/// a finish, and retains the ingress until then. Its state sits behind one lock, and each change
/// takes any replaced value out of the state and releases it after unlocking, so a call checking
/// whether the owner finished never holds a value.
nonisolated private final class SnapshotPublisherIngress<Output: Sendable>: Sendable {
    /// What the owner handed over since the channel last took it.
    struct Handed: Sendable {
        var value: (value: Output, final: Bool)?
        var finished: Bool
    }
    private struct State: Sendable {
        var pending: (value: Output, final: Bool)?
        var finished = false
        var scheduled = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let channel: SnapshotPublisher<Output>.Channel

    init(_ channel: SnapshotPublisher<Output>.Channel) { self.channel = channel }

    func offer(_ value: Output, final: Bool) {
        update { exchange(&$0.pending, with: (value, final)) }
    }

    func finish() {
        update { state in
            state.finished = true
            return nil
        }
    }

    /// Takes the newest value and reports whether the owner has finished, leaving any scheduled
    /// hand-off turn scheduled.
    @MainActor func take() -> Handed { take(unscheduling: false) }

    @MainActor private func take(unscheduling: Bool) -> Handed {
        state.withLock { state in
            if unscheduling { state.scheduled = false }
            return Handed(value: state.pending.take(), finished: state.finished)
        }
    }

    // Applies `change`, which returns the value it replaced, unless the owner has finished, and
    // schedules a hand-off turn unless one is scheduled.
    private func update(_ change: @Sendable (inout State) -> (value: Output, final: Bool)?) {
        var changed = state.withLock { state -> (wake: Bool, replaced: (value: Output, final: Bool)?)? in
            guard !state.finished else { return nil }
            let replaced = change(&state)
            let wake = !state.scheduled
            state.scheduled = true
            return (wake, replaced)
        }
        guard let wake = changed?.wake else { return }
        changed = nil
        if wake { Task { @MainActor in self.deliver() } }
    }

    @MainActor private func deliver() {
        let handed = take(unscheduling: true)
        HandOffPause.reached()
        channel.handOff(handed)
    }
}

extension SnapshotPublisher: @MainActor Publisher {
    /// Delivery never fails.
    public typealias Failure = Never

    /// Attaches the publisher's one subscriber, or finishes a later one at once.
    public func receive<S: Subscriber>(subscriber: S) where S.Input == Output, S.Failure == Never {
        // Combine does not check isolation, so a subscription off the main actor stops here rather than
        // racing. This check asserts the isolation the method already requires and decides nothing.
        MainActor.assumeIsolated {}
        channel.attach(AnySubscriber(subscriber), lifetime: lifetime)
    }
}

extension RuntimeMainActorHost {
    /// Registers a Combine publisher of `Sendable` projected snapshots, delivered on the main actor, taking
    /// a subscriber slot when called, before anything subscribes.
    ///
    /// `transform` runs on the main actor when a snapshot is delivered.
    public func snapshotPublisher<Output: Sendable>(
        _ transform: @escaping @MainActor (Engine.Snapshot) -> Output
    ) throws(SubscriptionFailure) -> SnapshotPublisher<Output> {
        try SnapshotPublisher(mainActor: transform, isFinal: { $0.isClosed }, ownerLifetime: ownerLifetime) {
            (receive, finish, gate) throws(SubscriptionFailure) in
            try subscribe(receive, onFinish: finish, gate: gate)
        }
    }
}

extension RuntimeSharedHost {
    /// Registers a Combine publisher of projected snapshots, delivered on the main actor, taking a
    /// subscriber slot when called, before anything subscribes.
    ///
    /// `transform` runs on the registration's serial delivery path, outside every lock.
    @MainActor public func snapshotPublisher<Output: Sendable>(
        _ transform: @escaping @Sendable (Engine.Snapshot) -> Output
    ) throws(SubscriptionFailure) -> SnapshotPublisher<Output> {
        try SnapshotPublisher(transform, isFinal: { $0.isClosed }, ownerLifetime: ownerLifetime) {
            (receive, finish, released) throws(SubscriptionFailure) in
            try subscribe(receive, onFinish: finish, onRelease: released)
        }
    }
}

extension RuntimeActorHost {
    /// Registers a Combine publisher of projected snapshots, delivered on the main actor, taking a
    /// subscriber slot when called, before anything subscribes.
    ///
    /// `transform` runs in this actor's delivery turn.
    @MainActor public func snapshotPublisher<Output: Sendable>(
        _ transform: @escaping @Sendable (Engine.Snapshot) -> Output
    ) async throws(SubscriptionFailure) -> SnapshotPublisher<Output> {
        try await SnapshotPublisher(actor: transform, isFinal: { $0.isClosed }, ownerLifetime: ownerLifetime) {
            (receive, finish, released) async throws(SubscriptionFailure) in
            try await subscribe(receive, onFinish: finish, onRelease: released)
        }
    }
}
#endif
