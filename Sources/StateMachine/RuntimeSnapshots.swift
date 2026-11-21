import os

/// A single-pass asynchronous sequence of an owner's complete snapshots.
///
/// Creating the sequence registers one observer. The first element is the snapshot that was
/// current at registration unless a newer one has replaced it, and later elements have strictly
/// increasing revisions. One pending snapshot is retained: a consumer that reads slowly receives
/// the latest value and never an older one.
///
/// The sequence ends after the owner's closed snapshot, when the owner is released without
/// closing, when ``cancel(isolation:)`` is called, and when a read finds its task cancelled, whether it was
/// cancelled before or during the read. Only a read observes task cancellation: a task cancelled
/// after its last read, or a loop that leaves early with `break` or `first(where:)`, leaves the
/// registration in place for as long as the sequence is kept. A consumer that keeps the sequence beyond its loop ends it explicitly:
///
/// ```swift
/// let snapshots = try host.snapshots()
/// defer { snapshots.cancel() }
/// let closed = await snapshots.first { $0.isClosed }
/// ```
///
/// Only the first iterator receives elements; a later iterator ends immediately. Releasing the
/// sequence and its iterator removes the registration, and the sequence does not keep its owner
/// alive.
nonisolated public struct SnapshotSequence<Element: Sendable>: AsyncSequence, Sendable {
    /// Iteration never throws.
    public typealias Failure = Never

    /// The sole consumer of a snapshot sequence.
    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var lifetime: Lifetime?

        /// Returns the latest unread snapshot, waiting for one when none is pending.
        ///
        /// Returns `nil` once the sequence has ended, and removes the registration. The call
        /// runs on the caller's actor.
        nonisolated(nonsending) public mutating func next() async -> Element? { await step() }

        /// Returns the latest unread snapshot on `actor`, waiting for one when none is pending.
        ///
        /// Returns `nil` once the sequence has ended, and removes the registration.
        @available(iOS 18, macOS 15, tvOS 18, watchOS 11, visionOS 2, *)
        public mutating func next(isolation actor: isolated (any Actor)?) async -> Element? { await step() }

        nonisolated(nonsending) private mutating func step() async -> Element? {
            guard let current = lifetime else { return nil }
            if let element = await current.mailbox.next() { return element }
            lifetime = nil
            current.end(isolation: #isolation)
            return nil
        }
    }

    /// What a consumer finds when it looks for an element without waiting.
    package enum Poll: Sendable {
        /// The pending element, which the consumer has now read.
        case element(Element)
        /// No element is pending, and the sequence has not ended.
        case empty
        /// The sequence has ended and holds no unread element.
        case ended
    }

    /// The claimed consumer of a sequence, which reads it from any isolation domain.
    ///
    /// Claiming is the same one-time decision that ``makeAsyncIterator()`` makes, so a sequence has at
    /// most one consumer of either kind.
    package struct Consumer: Sendable {
        fileprivate let lifetime: Lifetime

        /// Takes the pending element without waiting; reading the end removes the registration.
        package func poll(isolation: isolated (any Actor)? = #isolation) -> Poll {
            let found = lifetime.mailbox.poll()
            if case .ended = found { lifetime.end(isolation: isolation) }
            return found
        }
        /// Whether the sequence can still deliver: neither finished nor cancelled, whether or not an
        /// element is pending.
        package var isOpen: Bool { lifetime.mailbox.isOpen }
        /// Returns the latest unread element, waiting for one when none is pending, or `nil` once the
        /// sequence has ended, and then removes the registration.
        nonisolated(nonsending) package func next() async -> Element? {
            if let element = await lifetime.mailbox.next() { return element }
            lifetime.end(isolation: #isolation)
            return nil
        }
        /// The gate that stops delivery and frees the slot at once, from any thread.
        ///
        /// The owner admits through it, so closing it stops delivery without removing the registration
        /// or releasing an element; it is `nil` for a host of your own. A destructor closes it and
        /// leaves the removal to an end on the owner's actor. It is a flag of its own, so closing it
        /// reads no element and no token.
        package var gate: RuntimeRegistrationGate? { lifetime.registration.gate }
        /// Ends the sequence and, for a main-actor owner, removes its registration before returning.
        @MainActor package func cancelOnMainActor() {
            lifetime.mailbox.cancel()
            lifetime.endOnMainActor()
        }
        /// Ends the sequence as ``cancelOnMainActor()`` does, then runs `completion` on the main actor
        /// once the registration has been removed, right after the element the end discarded has been
        /// released there, in the same main-actor turn.
        @MainActor package func cancelOnMainActor(then completion: @escaping @MainActor @Sendable () -> Void) {
            lifetime.mailbox.cancel()
            lifetime.endOnMainActor(then: completion)
        }
        /// Runs `completion` on the main actor once the registration has been removed, which is the
        /// moment a host of your own frees its slot: before this returns when it has been removed by
        /// then, and otherwise on a later main-actor turn after the removal, as when the host is
        /// cancelling the registration's token at that moment and the sequence was ended from inside
        /// that cancellation.
        @MainActor package func afterRemoval(_ completion: @escaping @MainActor @Sendable () -> Void) {
            let later = lifetime.registration.observeRemoval { Task { @MainActor in completion() } }
            if !later { completion() }
        }
    }

    // Capacity one, behind one lock. Every change takes what it displaces out of the state, the
    // replaced element or the waiting consumer, and releases or resumes it after unlocking, so no
    // destructor or continuation runs locked. A reader copies the flags it needs out of the state and
    // never retains the element, so a call that only reads, from any thread, runs no client code, and
    // the end, whether a finish or a cancellation, is recorded in the same change that every reader
    // sees.
    //
    // An element for the waiting read is stored in the state, and the continuation only tells the read
    // whether one was handed to it, which it then takes under the lock. The Swift runtime does not
    // report to the thread sanitizer the ordering of a continuation resumed before its task suspends,
    // so an element carried in that resumption would look unsynchronized with the thread that offered
    // it; the lock orders the two in a way the sanitizer observes.
    fileprivate final class Mailbox: Sendable {
        private struct State: Sendable {
            var pending: Element?
            // Resumed with `true` once `handed` holds the read's element, and with `false` when the read
            // ends without one.
            var waiter: CheckedContinuation<Bool, Never>?
            // The element given to the read that waited, which that read takes once it resumes. It is
            // empty whenever a waiter is installed.
            var handed: Element?
            var finished = false
            var cancelled = false
            var claimed = false
        }
        private let state = OSAllocatedUnfairLock(initialState: State())

        func claim() -> Bool {
            state.withLock { state in
                guard !state.claimed else { return false }
                state.claimed = true
                return true
            }
        }

        func offer(_ element: Element) {
            var handed = state.withLock {
                state -> (waiter: CheckedContinuation<Bool, Never>?, displaced: Element?) in
                guard !state.finished, !state.cancelled else { return (nil, nil) }
                if let waiter = state.waiter.take() {
                    state.handed = element
                    return (waiter, nil)
                }
                return (nil, exchange(&state.pending, with: element))
            }
            handed.waiter?.resume(returning: true)
            handed.displaced = nil
        }

        // A pending final value stays readable after the mailbox has finished.
        func finish() {
            let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
                guard !state.finished else { return nil }
                state.finished = true
                return state.waiter.take()
            }
            waiter?.resume(returning: false)
        }

        /// Whether the mailbox can still deliver, pending element or not, read without retaining an
        /// element.
        var isOpen: Bool { state.withLock { !$0.finished && !$0.cancelled } }

        // Also runs inside a task cancellation handler, so it only records the flag and wakes the
        // consumer; no later read returns the element still pending. Whoever ends the sequence then
        // removes its registration and only afterward discards that element, so a destructor that
        // registers again finds the slot free.
        func cancel() {
            let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
                guard !state.cancelled else { return nil }
                state.cancelled = true
                return state.waiter.take()
            }
            waiter?.resume(returning: false)
        }

        /// Takes the element that no read can return any more, once the mailbox is cancelled.
        ///
        /// The caller releases it after the registration is removed. A finished mailbox keeps its
        /// unread final element for a read until it is cancelled.
        func discard() -> Element? {
            state.withLock { state in state.cancelled ? state.pending.take() : nil }
        }

        /// Takes the pending element without waiting, or reports that none is pending or that the
        /// mailbox has ended, in one change.
        func poll() -> Poll {
            state.withLock { state in
                if state.cancelled { return .ended }
                if let pending = state.pending.take() { return .element(pending) }
                return state.finished ? .ended : .empty
            }
        }

        nonisolated(nonsending) func next() async -> Element? {
            let handed = await withTaskCancellationHandler {
                await withCheckedContinuation { wait($0) }
            } onCancel: {
                cancel()
            }
            // An offer, or this read itself, stored the element before resuming the read.
            guard handed else { return nil }
            return state.withLock { $0.handed.take() }
        }

        // The cancelled flag is read in the same change that stores the waiter, so a cancellation on
        // either side of it resumes the consumer. A read that finds another read waiting, or not yet
        // done taking the element handed to it, ends at once.
        private func wait(_ continuation: CheckedContinuation<Bool, Never>) {
            let answer = state.withLock { state -> Bool? in
                if state.cancelled || state.waiter != nil || state.handed != nil { return false }
                if let pending = state.pending.take() {
                    state.handed = pending
                    return true
                }
                if state.finished { return false }
                state.waiter = continuation
                return nil
            }
            guard let answer else {
                SnapshotWaitPause.reached()
                return
            }
            continuation.resume(returning: answer)
        }
    }

    // The only object an owner's callbacks retain. An owner releases its callbacks when
    // it closes, when the registration is removed, and when the owner itself is
    // released, so each of those ends the sequence and its registration.
    private final class Feeder: Sendable {
        let mailbox: Mailbox
        let registration: Registration
        private let onDetach: @Sendable () -> Void

        init(_ mailbox: Mailbox, _ registration: Registration, onDetach: @escaping @Sendable () -> Void) {
            self.mailbox = mailbox
            self.registration = registration
            self.onDetach = onDetach
        }
        // A finish ends the registration at once; an element offered before it stays readable.
        func finish() {
            mailbox.finish()
            registration.release()
        }
        deinit {
            finish()
            onDetach()
        }
    }

    /// The token of the sequence's registration, which the sequence releases exactly once.
    fileprivate enum Token: Sendable {
        case shared(SnapshotSubscription)
        case mainActor(MainActorSnapshotSubscription, RuntimeRegistrationGate)

        /// The gate a managed owner admits the registration through, or `nil` for a host of your own.
        var gate: RuntimeRegistrationGate? {
            switch self {
            case .shared(let token): token.gate
            case .mainActor(_, let gate): gate
            }
        }
        /// The token a main-actor owner removes the registration with, which only the main actor can
        /// cancel.
        var onMainActor: MainActorSnapshotSubscription? {
            if case .mainActor(let token, _) = self { return token }
            return nil
        }
    }

    // Whether the registration is still being made, is held, is being removed, or has been removed.
    // The owner can finish the sequence before `register` returns its token, so a release that comes
    // first is recorded and carried out when the token arrives. A host may keep its own reference to
    // the token, so the sequence cancels it explicitly instead of relying on its release.
    //
    // Every release follows one order: close the registration's gate, record the release, cancel the
    // token, and only then release the elements the releases discarded and tell the calls waiting for
    // the removal. Closing the gate first means that a later release that finds the release recorded
    // returns after the gate closed, so an owner that admits through the gate stops counting the
    // registration, whichever release cancels the token. Until the token's cancellation has returned,
    // the state keeps every element a release discarded, and whoever cancels the token releases them
    // afterward, so a destructor that registers again finds the slot free. A main-actor owner's token
    // can be cancelled only on the main actor: a release elsewhere keeps it in the state and queues its
    // cancellation there, and whichever main-actor release comes first takes it and cancels it.
    //
    // The state sits behind one lock. A change that replaces a stage holding elements or a token takes
    // the replaced stage out and releases it after unlocking, and the gate is kept apart from the
    // stage, so closing it from another thread, as a destructor does, reads no element and no token.
    fileprivate final class Registration: Sendable {
        private enum Stage: Sendable {
            // `released` holds the elements discarded once a release came first, and is `nil` until then.
            case registering(released: [Element]?)
            case registered(Token)
            // Released, and the token not yet cancelled: a main-actor owner's token waits in `queued` for a
            // main-actor release, or a release is cancelling it now. `discarded` waits for that to return.
            case removing(queued: MainActorSnapshotSubscription?, discarded: [Element])
            case removed
        }
        private struct State: Sendable {
            var stage = Stage.registering(released: nil)
            // The gate of the token, recorded with it.
            var gate: RuntimeRegistrationGate?
            // What runs once the removal is complete, after the discarded elements are released.
            var removal: [@Sendable () -> Void] = []
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        /// Whether the owner is a `MainActor` owner, whose token only the main actor cancels, so the
        /// removal completes on the main actor and runs what waits for it there.
        let completesOnMainActor: Bool

        init(completesOnMainActor: Bool = false) { self.completesOnMainActor = completesOnMainActor }

        /// The gate a managed owner admits the registration through, once the owner has returned it.
        var gate: RuntimeRegistrationGate? { state.withLock { $0.gate } }

        /// Holds the token `register` returned, or cancels it at once when the sequence has already ended.
        func install(_ token: Token) {
            guard let released = record(token) else { return }
            cancel(released)
        }
        /// Holds the token a `MainActor` owner returned, or, when the sequence has already ended,
        /// cancels it before returning.
        @MainActor func installOnMainActor(_ token: Token) {
            guard let released = record(token) else { return }
            if case .shared(let token) = released {
                token.cancel { self.completeRemoval() }
            }
            removeQueued()
        }
        // Records the token, or, when a release came first, records the release and returns the token,
        // with its gate closed, for the caller to cancel.
        private func record(_ token: Token) -> Token? {
            let released = state.withLock { state -> Bool in
                guard case .registering(let released) = state.stage else { return false }
                state.gate = token.gate
                guard let released else {
                    state.stage = .registered(token)
                    return false
                }
                state.stage = .removing(queued: token.onMainActor, discarded: released)
                return true
            }
            guard released else { return nil }
            token.gate?.close()
            return token
        }
        /// Closes the gate of a held registration and changes nothing else, so a later release removes it.
        func closeGate() { gate?.close() }
        /// Records that the owner answered without a registration, as a closed owner does.
        func decline() {
            var ended = state.withLock { state in
                (stage: exchange(&state.stage, with: .removed), removal: exchange(&state.removal, with: []))
            }
            ended.stage = .removed
            for next in ended.removal { next() }
        }
        /// Runs `observer` once the registration has been removed and the elements its releases
        /// discarded are released, and returns `true`, or returns `false`, running nothing, when that
        /// has already happened.
        func observeRemoval(_ observer: @escaping @Sendable () -> Void) -> Bool {
            state.withLock { state in
                if case .removed = state.stage { return false }
                state.removal.append(observer)
                return true
            }
        }
        /// Cancels the registration once, from any thread, and releases `discarded`, the element the
        /// end discarded, once the registration is removed: at once, after another release's
        /// cancellation of the token has returned, or after the main actor has removed a main-actor
        /// owner's registration.
        func release(discarding discarded: Element? = nil) {
            guard let token = take(discarding: discarded) else { return }
            cancel(token)
        }
        /// Cancels the registration once and, for a main-actor owner, removes it before returning,
        /// even when a release on another thread came first and queued its removal.
        @MainActor func releaseOnMainActor() {
            if case .shared(let token)? = take(discarding: nil) {
                token.cancel { self.completeRemoval() }
            }
            removeQueued()
        }

        // Cancels a token whose release is recorded, then releases the discarded elements once the
        // token's cancellation has returned: a shared owner's at once, and a main-actor owner's on the
        // main actor, where the first main-actor release to come takes it from the state. A host that
        // is cancelling the token itself, and ends the sequence from its `onCancel`, finds that
        // cancellation in progress: the elements wait until it returns.
        private func cancel(_ token: Token) {
            switch token {
            case .shared(let token):
                token.cancel { self.completeRemoval() }
            case .mainActor:
                Task { @MainActor [self] in self.removeQueued() }
            }
        }
        // Closes the gate of a held registration and records its release, in that order, and returns
        // its token, or `nil` when the registration was already released or never made. A release that
        // finds the registration still being removed leaves `discarded` with that removal; one that
        // finds it removed releases `discarded` at once.
        private func take(discarding discarded: Element?) -> Token? {
            closeGate()
            var change = state.withLock { state -> (token: Token?, retired: Stage?) in
                switch state.stage {
                case .removed:
                    return (nil, nil)
                case .registering(let released):
                    let held = (released ?? []) + (discarded.map { [$0] } ?? [])
                    return (nil, exchange(&state.stage, with: .registering(released: held)))
                case .removing(let queued, let held):
                    guard let discarded else { return (nil, nil) }
                    return (nil, exchange(&state.stage, with: .removing(queued: queued, discarded: held + [discarded])))
                case .registered(let registered):
                    let next = Stage.removing(queued: registered.onMainActor, discarded: discarded.map { [$0] } ?? [])
                    return (registered, exchange(&state.stage, with: next))
                }
            }
            change.retired = nil
            return change.token.take()
        }
        // Takes the main-actor token whose cancellation a release left to the main actor, cancels it,
        // and then releases the elements the releases discarded meanwhile.
        @MainActor private func removeQueued() {
            var queued = state.withLock { state -> MainActorSnapshotSubscription? in
                guard case .removing(let queued?, let discarded) = state.stage else { return nil }
                state.stage = .removing(queued: nil, discarded: discarded)
                return queued
            }
            guard let token = queued.take() else { return }
            token.cancel { self.completeRemoval() }
        }
        // Records that the token's cancellation has returned, then releases what the releases
        // discarded, and then runs what waits for the removal.
        private func completeRemoval() {
            var finished = state.withLock { state -> (retired: Stage, removal: [@Sendable () -> Void])? in
                guard case .removing(nil, _) = state.stage else { return nil }
                return (exchange(&state.stage, with: .removed), exchange(&state.removal, with: []))
            }
            guard let removal = finished?.removal else { return }
            finished = nil
            for next in removal { next() }
        }
    }

    // The sequence and its iterator share it; when the last of them goes away, the registration ends.
    fileprivate final class Lifetime: Sendable {
        let mailbox: Mailbox
        let registration: Registration

        init(_ mailbox: Mailbox, _ registration: Registration) {
            self.mailbox = mailbox
            self.registration = registration
        }
        /// Removes the registration, then releases the element no read can return any more, so its
        /// destructor runs once the slot is free: before this returns, or, when the main actor removes
        /// the registration later, after it has.
        func end() {
            registration.release(discarding: mailbox.discard())
        }
        /// Ends the sequence as ``end()`` does, removing a main-actor owner's registration before it
        /// returns, and releases the element no read can return any more on the main actor once the
        /// registration is removed.
        @MainActor func endOnMainActor() { endOnMainActor(then: nil) }
        /// Ends the sequence as ``endOnMainActor()`` does, then runs `completion` on the main actor once
        /// the registration has been removed and the discarded element released.
        ///
        /// The element is taken out of the mailbox here, on the main actor, and the registration never
        /// holds it, so whichever thread returns the token's cancellation, as a host of your own that
        /// is cancelling the token on a worker at this moment does, it releases nothing of the main
        /// actor's. The element is released, and then `completion` runs, before this returns when the
        /// registration is removed by then. Otherwise a `MainActor` owner's removal, which completes on
        /// the main actor, does both there as it completes, and any other owner's removal leaves both
        /// to the main-actor turn that follows, in that order.
        @MainActor func endOnMainActor(then completion: (@MainActor @Sendable () -> Void)?) {
            let custody = MainActorCustody(mailbox.discard())
            registration.releaseOnMainActor()
            guard custody.holds || completion != nil else { return }
            // One action for the removal, so the element is always released before `completion` runs, in
            // the same main-actor turn, whichever thread completes the removal and whether or not it has
            // completed by now.
            let pause = RemovalCompletionPause.afterCustody
            let removed: @MainActor @Sendable () -> Void = {
                custody.release()
                pause?()
                completion?()
            }
            let observer: @Sendable () -> Void
            if registration.completesOnMainActor {
                observer = { MainActor.assumeIsolated { removed() } }
            } else {
                observer = { Task { @MainActor in removed() } }
            }
            RemovalObservationPause.reached()
            if !registration.observeRemoval(observer) { removed() }
        }
        /// Ends the sequence from code isolated to `isolation`.
        ///
        /// The caller's isolation, not the thread it runs on, decides how a main-actor owner's
        /// registration is removed: only code isolated to the main actor runs on its executor,
        /// whichever thread that is, and code isolated to another actor can run on the main thread.
        /// Code isolated to the main actor removes it before returning, and any other code leaves that
        /// to the next main-actor turn.
        func end(isolation: isolated (any Actor)?) {
            if let isolation, isolation === MainActor.shared {
                MainActor.assumeIsolated { endOnMainActor() }
            } else {
                end()
            }
        }
        deinit {
            mailbox.cancel()
            end()
        }
    }

    // Holds an element that a main-actor end discarded until the main actor releases it, which it
    // does by taking it out, so the element is released there however the holder's references go.
    fileprivate final class MainActorCustody: Sendable {
        private let held: OSAllocatedUnfairLock<Element?>

        init(_ element: Element?) { held = OSAllocatedUnfairLock(initialState: element) }

        var holds: Bool { held.withLock { $0 != nil } }

        @MainActor func release() {
            let taken = held.withLock { $0.take() }
            withExtendedLifetime(taken) {}
        }
    }

    private let lifetime: Lifetime

    /// Registers a sequence with a host of your own, such as a test double or a preview, through
    /// `register`.
    ///
    /// `register` receives the two callbacks that feed the sequence and returns the registration's
    /// token, typically one made with ``SnapshotSubscription/init(onCancel:)``. `receive` offers an
    /// element from any thread, one call at a time, and replaces an element not yet read; `finish`
    /// ends the sequence once any offered element has been read. Releasing both callbacks without
    /// calling `finish` ends the sequence too, as an owner released without closing does. A host
    /// that conforms to a hosting protocol offers the snapshot current at registration first and then
    /// each newer one, as a generated owner does.
    ///
    /// The sequence cancels the token exactly once, whether or not the host keeps its own reference
    /// to it: when `finish` is called, or the callbacks are released, even with an element still
    /// unread, which stays readable; when a read finds the end, or its task is cancelled while it
    /// waits; when ``cancel(isolation:)`` is called; and when the sequence and its iterator are released. A
    /// `finish` that `register` calls before returning cancels the token as soon as it is returned.
    ///
    /// A sequence is observation only, so creating one grants no authority over any owner.
    public init(
        register: (
            _ receive: @escaping @Sendable (Element) -> Void,
            _ finish: @escaping @Sendable () -> Void
        ) throws(SubscriptionFailure) -> SnapshotSubscription
    ) throws(SubscriptionFailure) {
        try self.init({ (element: Element) -> Element? in element }, register: register)
    }

    /// Registers through `register` and projects each raw observation with `transform`.
    ///
    /// An observation that `transform` maps to `nil` is not offered. `onDetach` runs once the owner
    /// has released this sequence's callbacks.
    package init<Raw>(
        _ transform: @escaping @Sendable (Raw) -> Element?,
        onDetach: @escaping @Sendable () -> Void = {},
        register: (
            _ receive: @escaping @Sendable (Raw) -> Void,
            _ finish: @escaping @Sendable () -> Void
        ) throws(SubscriptionFailure) -> SnapshotSubscription
    ) throws(SubscriptionFailure) {
        try self.init(transform, onDetach: onDetach) { (receive, finish) throws(SubscriptionFailure) in
            .registered(try register(receive, finish))
        }
    }

    /// Registers through `register`, which either registers or, for a closed owner, answers at once
    /// with the closed observation, and projects each raw observation with `transform`.
    ///
    /// A sequence of a closed owner holds that observation's projection and has already ended, and
    /// no registration exists to remove. `onDetach` runs once the owner has released this sequence's
    /// callbacks.
    package init<Raw>(
        _ transform: @escaping @Sendable (Raw) -> Element?,
        onDetach: @escaping @Sendable () -> Void = {},
        registering register: (
            _ receive: @escaping @Sendable (Raw) -> Void,
            _ finish: @escaping @Sendable () -> Void
        ) throws(SubscriptionFailure) -> SnapshotRegistration<Raw>
    ) throws(SubscriptionFailure) {
        let mailbox = Mailbox()
        let registration = Registration()
        let feeder = Feeder(mailbox, registration, onDetach: onDetach)
        switch try register(
            { if let element = transform($0) { feeder.mailbox.offer(element) } },
            { feeder.finish() }
        ) {
        case .registered(let token): registration.install(.shared(token))
        case .closed(let closed):
            registration.decline()
            if let element = transform(closed) { mailbox.offer(element) }
            mailbox.finish()
        }
        lifetime = Lifetime(mailbox, registration)
    }

    /// Registers with an owner confined to one actor through `register`, and projects each raw
    /// observation with `transform` on that actor.
    ///
    /// An observation that `transform` maps to `nil` is not offered. `onDetach` runs once the owner
    /// has released this sequence's callbacks.
    package init<Raw>(
        confined transform: @escaping (Raw) -> Element?,
        onDetach: @escaping @Sendable () -> Void = {},
        register: (
            _ receive: @escaping (Raw) -> Void,
            _ finish: @escaping () -> Void
        ) throws(SubscriptionFailure) -> SnapshotSubscription
    ) throws(SubscriptionFailure) {
        let mailbox = Mailbox()
        let registration = Registration()
        let feeder = Feeder(mailbox, registration, onDetach: onDetach)
        let token = try register(
            { if let element = transform($0) { feeder.mailbox.offer(element) } },
            { feeder.finish() }
        )
        registration.install(.shared(token))
        lifetime = Lifetime(mailbox, registration)
    }

    /// Registers with a `MainActor` owner through `register` and projects each raw observation
    /// with `transform` on the main actor.
    ///
    /// An observation that `transform` maps to `nil` is not offered. `onDetach` runs once the owner
    /// has released this sequence's callbacks.
    @MainActor package init<Raw>(
        mainActor transform: @escaping @MainActor (Raw) -> Element?,
        onDetach: @escaping @Sendable () -> Void = {},
        register: (
            _ receive: @escaping @MainActor (Raw) -> Void,
            _ finish: @escaping @MainActor () -> Void,
            _ gate: RuntimeRegistrationGate
        ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription
    ) throws(SubscriptionFailure) {
        let mailbox = Mailbox()
        let registration = Registration(completesOnMainActor: true)
        let feeder = Feeder(mailbox, registration, onDetach: onDetach)
        let gate = RuntimeRegistrationGate()
        let token = try register(
            { if let element = transform($0) { feeder.mailbox.offer(element) } },
            { feeder.finish() },
            gate
        )
        registration.installOnMainActor(.mainActor(token, gate))
        lifetime = Lifetime(mailbox, registration)
    }

    /// Claims the sequence for one consumer; a later iterator ends immediately.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(lifetime: lifetime.mailbox.claim() ? lifetime : nil)
    }

    /// Claims the sequence for one consumer, or returns `nil` when an iterator or another consumer
    /// has already claimed it.
    package func claim() -> Consumer? {
        lifetime.mailbox.claim() ? Consumer(lifetime: lifetime) : nil
    }

    /// Ends the sequence and removes its registration, from any isolation domain.
    ///
    /// A read waiting for an element returns `nil`, unless the owner had already handed it an element,
    /// which that read still returns. Every later read returns `nil`. An element still unread is
    /// discarded and released only once the registration is removed, so a destructor that registers
    /// again finds the slot free: before this returns, or, when another call or the owner's finish is
    /// removing the registration at that moment, or a `MainActor` owner's registration is removed on a
    /// later main-actor turn, right after that removal. A call isolated to the main actor releases the
    /// element on the main actor, on the main-actor turn after the removal when another thread
    /// completes it.
    ///
    /// The owner stops delivering before this returns, and a generated owner frees the subscriber slot
    /// by then, whichever call cancels first; an owner confined to an actor removes the registration's
    /// callbacks on its next turn there. A `MainActor` host of your own frees its slot when its
    /// subscription is cancelled, which only the main actor can do: a call isolated to the main actor,
    /// whose `isolation` is `MainActor.shared`, cancels it before returning, including when a call
    /// elsewhere came first, and any other call, from another actor, a nonisolated function, or a
    /// destructor, leaves it to the next main-actor turn. A host registered through
    /// ``init(register:)`` frees its slot when its token's `onCancel` returns, which the first call
    /// runs; a concurrent call can return before then, and the element it discarded waits for that
    /// return. So does a call that the host makes from inside that `onCancel` while it cancels the
    /// token itself: the call returns at once, and the element is released once `onCancel` returns.
    /// Calling it again, or after the sequence has ended, changes nothing.
    ///
    /// `isolation` is the caller's actor, which every call passes by default; ordinary calls spell this
    /// `cancel()`. Call it when a consumer that keeps the sequence stops reading early, as
    /// `defer { snapshots.cancel() }` does, because a task that stops reading gives the sequence no
    /// cancellation to observe.
    public func cancel(isolation: isolated (any Actor)? = #isolation) {
        lifetime.mailbox.cancel()
        lifetime.end(isolation: isolation)
    }
}

/// How an owner answered one registration: with a registration, or, for a closed owner, with its
/// closed observation, which no registration follows.
package enum SnapshotRegistration<Raw> {
    case registered(SnapshotSubscription)
    case closed(Raw)
}

/// A single-consumer stream of a `MainActor` owner's complete snapshots.
///
/// It is read on the main actor, which lets it carry snapshots that are not `Sendable`. Read it with
/// `next()`:
///
/// ```swift
/// var snapshots = try host.snapshots()
/// while let snapshot = await snapshots.next() { show(snapshot) }
/// ```
///
/// It is deliberately not an `AsyncSequence`. The standard sequence operators run their closures off
/// the main actor, which would move a confined snapshot off it. For `for await`, operators, or generic
/// `AsyncSequence` code, register a `Sendable` projection, whose result is a ``SnapshotSequence``: a
/// generated `MainActorHost` registers one with `snapshots(_:)`, and a raw `RuntimeMainActorHost` with
/// `sendableSnapshots(_:)`, whose `snapshots(_:)` returns this confined stream of the projected values
/// instead.
///
/// Creating it registers one observer. The first element is the snapshot that was current at
/// registration unless a newer one has replaced it, and later elements have strictly increasing
/// revisions. One pending snapshot is retained: a consumer that reads slowly receives the latest value
/// and never an older one. It is noncopyable, so it has exactly one consumer.
///
/// It ends after the owner's closed snapshot, when the owner is released without closing, when
/// ``cancel()`` is called, and when a read finds its task cancelled, whether it was cancelled
/// before or during the read. A task that stops reading never gives it that chance. Ending it removes
/// the registration at once. Releasing it before it ends, which can happen on another thread when an
/// object that stores it is released there, stops delivery and frees its slot at once; a later
/// main-actor turn removes the registration and then releases the snapshot it held unread, including
/// the closed snapshot of an owner that has already released its callbacks, so that snapshot is never
/// destroyed off the main actor. A stream kept beyond its loop, such as one an object stores, ends with
/// ``cancel()``. It does not keep its owner alive.
nonisolated public struct MainActorSnapshotSequence<Element>: ~Copyable {
    // Confined to the main actor, except for the waiter slot that a task cancellation
    // handler reaches from any thread.
    @MainActor fileprivate final class Mailbox {
        private struct Signal: Sendable {
            var waiter: CheckedContinuation<Void, Never>?
            var cancelled = false
        }
        private let signal = AtomicRecordStorage(Signal())
        private var pending: Element?
        private var finished = false

        private var isCancelled: Bool { signal.load().value.cancelled }

        func offer(_ element: Element) {
            guard !finished, !isCancelled else { return }
            let displaced = pending
            pending = element
            wake(cancelling: false)
            withExtendedLifetime(displaced) {}
        }

        /// Ends the stream on the main actor: records the cancellation and returns the element no
        /// later read can return, for the caller to release once the stream is consistent.
        func discard() -> Element? {
            cancel()
            let discarded = pending
            pending = nil
            return discarded
        }

        // A pending final value stays readable after the mailbox has finished.
        func finish() {
            guard !finished else { return }
            finished = true
            wake(cancelling: false)
        }

        // Runs inside a task cancellation handler, so it only records the flag and wakes
        // the consumer. The consumer removes its registration on the main actor.
        nonisolated func cancel() { wake(cancelling: true) }

        nonisolated private func wake(cancelling: Bool) {
            while true {
                let previous = signal.load()
                guard previous.value.waiter != nil || (cancelling && !previous.value.cancelled) else { return }
                var next = previous.value
                let waiter = next.waiter
                next.waiter = nil
                if cancelling { next.cancelled = true }
                if signal.install(.init(next), replacing: previous) {
                    waiter?.resume()
                    return
                }
            }
        }

        // The continuation is a wake signal only. The element is read here, on the main
        // actor, so no snapshot crosses an isolation boundary.
        func next() async -> Element? {
            while true {
                // A consumer cancelled before it waits has installed no handler, so the task is asked
                // too. The element no later read can return stays until the stream has removed its
                // registration, and is then discarded on the main actor.
                if isCancelled || Task.isCancelled {
                    cancel()
                    return nil
                }
                if let element = pending {
                    pending = nil
                    return element
                }
                if finished { return nil }
                await withTaskCancellationHandler {
                    await withCheckedContinuation { wait($0) }
                } onCancel: {
                    cancel()
                }
            }
        }

        private func wait(_ continuation: CheckedContinuation<Void, Never>) {
            guard pending == nil, !finished else {
                continuation.resume()
                return
            }
            while true {
                let previous = signal.load()
                var next = previous.value
                if next.cancelled {
                    continuation.resume()
                    return
                }
                next.waiter = continuation
                if signal.install(.init(next), replacing: previous) { return }
            }
        }
    }

    // The only object an owner's callbacks retain. An owner releases its callbacks when
    // it closes, when the registration is removed, and when the owner itself is
    // released, so each of those ends the stream. Release can happen inside the owner's
    // own mutation, so the mailbox is finished on a later turn.
    private final class Feeder: Sendable {
        let mailbox: Mailbox
        private let onDetach: @Sendable () -> Void

        init(_ mailbox: Mailbox, onDetach: @escaping @Sendable () -> Void) {
            self.mailbox = mailbox
            self.onDetach = onDetach
        }
        deinit {
            let mailbox = mailbox
            let onDetach = onDetach
            Task { @MainActor in
                mailbox.finish()
                onDetach()
            }
        }
    }

    private let mailbox: Mailbox
    private var token: MainActorSnapshotSubscription?

    /// Registers through `register` and projects each raw observation with `transform`.
    ///
    /// An observation that `transform` maps to `nil` is not offered. `onDetach` runs once the owner
    /// has released this stream's callbacks.
    @MainActor package init<Raw>(
        _ transform: @escaping @MainActor (Raw) -> Element?,
        onDetach: @escaping @Sendable () -> Void = {},
        register: (
            _ receive: @escaping @MainActor (Raw) -> Void,
            _ finish: @escaping @MainActor () -> Void
        ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription
    ) throws(SubscriptionFailure) {
        let mailbox = Mailbox()
        let feeder = Feeder(mailbox, onDetach: onDetach)
        token = try register(
            { if let element = transform($0) { feeder.mailbox.offer(element) } },
            { feeder.mailbox.finish() }
        )
        self.mailbox = mailbox
    }

    /// Returns the latest unread snapshot, waiting for one when none is pending.
    ///
    /// Returns `nil` once the stream has ended, and removes the registration.
    @MainActor public mutating func next() async -> Element? {
        guard token != nil else { return nil }
        if let element = await mailbox.next() { return element }
        end()
        return nil
    }

    /// Ends the stream and removes its registration before returning.
    ///
    /// Every later `next()` returns `nil`, and a snapshot still unread is released before this
    /// returns, unless the host is cancelling the registration's token at that moment, as a host of
    /// your own that ends the stream from its `onCancel` does: the snapshot is then released once
    /// that cancellation returns. Calling it again, or after the stream has ended, changes nothing.
    @MainActor public mutating func cancel() { end() }

    // Takes the element no read can return any more and cancels the token, releasing that element once
    // the token's cancellation has returned, so a destructor that registers again finds the slot free.
    @MainActor private mutating func end() {
        let discarded = mailbox.discard()
        let ended = token
        token = nil
        guard let ended else {
            withExtendedLifetime(discarded) {}
            return
        }
        ended.cancel { withExtendedLifetime(discarded) {} }
    }

    // A stream dropped before it ended, which can happen on another thread when an object that stores
    // it is released there, stops delivery and frees its slot at once. The owner may have released
    // its callbacks already, so the stream can hold the mailbox's last reference, and its unread
    // element is not `Sendable`: the main actor removes the registration and then discards that
    // element, in one later turn.
    deinit {
        guard let token else { return }
        token.close()
        let mailbox = mailbox
        Task { @MainActor in
            let discarded = mailbox.discard()
            token.cancel { withExtendedLifetime(discarded) {} }
        }
        DestructorPause.reached()
    }
}

extension RuntimeSharedHost {
    /// Registers a single-pass latest-value sequence of complete snapshots, taking a subscriber slot when called.
    public func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Engine.Snapshot> {
        try snapshots { $0 }
    }
    /// Registers a single-pass latest-value sequence of projected snapshots, taking a subscriber slot when called.
    public func snapshots<Element: Sendable>(
        _ transform: @escaping @Sendable (Engine.Snapshot) -> Element
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        try snapshots(transform, onDetach: {})
    }
    /// Registers a sequence and reports when this host has released its callbacks.
    package func snapshots<Element: Sendable>(
        _ transform: @escaping @Sendable (Engine.Snapshot) -> Element,
        onDetach: @escaping @Sendable () -> Void
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        try SnapshotSequence(
            transform,
            onDetach: onDetach,
            registering: { (receive, finish) throws(SubscriptionFailure) in
                try register(receive, onFinish: finish)
            }
        )
    }
}

extension RuntimeActorHost {
    /// Registers a single-pass latest-value sequence of complete snapshots, taking a subscriber slot when called.
    public func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Engine.Snapshot> {
        try snapshots { $0 }
    }
    /// Registers a single-pass latest-value sequence of projected snapshots, taking a subscriber slot when called.
    public func snapshots<Element: Sendable>(
        _ transform: @escaping @Sendable (Engine.Snapshot) -> Element
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        try snapshots(transform, onDetach: {})
    }
    /// Registers a sequence and reports when this host has released its callbacks.
    package func snapshots<Element: Sendable>(
        _ transform: @escaping @Sendable (Engine.Snapshot) -> Element,
        onDetach: @escaping @Sendable () -> Void
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        try SnapshotSequence(transform, onDetach: onDetach) {
            (receive, finish) throws(SubscriptionFailure) in
            try subscribe(receive, onFinish: finish)
        }
    }
}

extension RuntimeMainActorHost {
    /// Registers a single-pass latest-value sequence of complete snapshots, taking a subscriber slot when called.
    public func snapshots() throws(SubscriptionFailure) -> MainActorSnapshotSequence<Engine.Snapshot> {
        try snapshots { $0 }
    }
    /// Registers a single-pass latest-value sequence of projected snapshots, taking a subscriber slot when called.
    public func snapshots<Element>(
        _ transform: @escaping @MainActor (Engine.Snapshot) -> Element
    ) throws(SubscriptionFailure) -> MainActorSnapshotSequence<Element> {
        try snapshots(transform, onDetach: {})
    }
    /// Registers a sequence and reports when this host has released its callbacks.
    package func snapshots<Element>(
        _ transform: @escaping @MainActor (Engine.Snapshot) -> Element,
        onDetach: @escaping @Sendable () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSequence<Element> {
        try MainActorSnapshotSequence(transform, onDetach: onDetach) {
            (receive, finish) throws(SubscriptionFailure) in
            try subscribe(receive, onFinish: finish)
        }
    }

    /// Registers a single-pass latest-value sequence of complete `Sendable` snapshots, taking a subscriber
    /// slot when called.
    ///
    /// The sequence supports every `AsyncSequence` operator on every supported OS version.
    public func sendableSnapshots() throws(SubscriptionFailure) -> SnapshotSequence<Engine.Snapshot>
    where Engine.Snapshot: Sendable {
        try sendableSnapshots { $0 }
    }
    /// Registers a single-pass latest-value sequence of `Sendable` projections, taking a subscriber slot
    /// when called.
    ///
    /// `transform` runs on the main actor when a snapshot is delivered. The sequence supports
    /// every `AsyncSequence` operator on every supported OS version.
    public func sendableSnapshots<Element: Sendable>(
        _ transform: @escaping @MainActor (Engine.Snapshot) -> Element
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        try sendableSnapshots(transform, onDetach: {})
    }
    /// Registers a sequence and reports when this host has released its callbacks.
    package func sendableSnapshots<Element: Sendable>(
        _ transform: @escaping @MainActor (Engine.Snapshot) -> Element,
        onDetach: @escaping @Sendable () -> Void
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        try SnapshotSequence(mainActor: transform, onDetach: onDetach) {
            (receive, finish, gate) throws(SubscriptionFailure) in
            try subscribe(receive, onFinish: finish, gate: gate)
        }
    }
}

extension RuntimeSharedHost {
    /// Registers a single-pass latest-value sequence of the retained completions, projected by `transform`,
    /// taking a subscriber slot when called.
    ///
    /// Each element is the whole collection, starting with the one current at registration. A newer
    /// collection replaces one not yet read, and the sequence ends after the final, empty collection
    /// that closing delivers.
    public func pendingCompletionUpdates<Element: Sendable>(
        _ transform: @escaping @Sendable ([Ledger.Pending]) -> Element
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        try SnapshotSequence(transform) { (receive, finish) throws(SubscriptionFailure) in
            try subscribePending(receive, onFinish: finish)
        }
    }
}

extension RuntimeActorHost {
    /// Registers a single-pass latest-value sequence of the retained completions, projected by `transform`,
    /// taking a subscriber slot when called.
    ///
    /// Each element is the whole collection, starting with the one current at registration. A newer
    /// collection replaces one not yet read, and the sequence ends after the final, empty collection
    /// that closing delivers.
    public func pendingCompletionUpdates<Element: Sendable>(
        _ transform: @escaping @Sendable ([Ledger.Pending]) -> Element
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        try SnapshotSequence(transform) { (receive, finish) throws(SubscriptionFailure) in
            try subscribePending(receive, onFinish: finish)
        }
    }
}

extension RuntimeMainActorHost {
    /// Registers a single-pass latest-value sequence of the retained completions, projected by
    /// `transform` on the main actor, taking a subscriber slot when called.
    ///
    /// Each element is the whole collection, starting with the one current at registration. A newer
    /// collection replaces one not yet read, and the sequence ends after the final, empty collection
    /// that closing delivers.
    public func pendingCompletionUpdates<Element>(
        _ transform: @escaping @MainActor ([Ledger.Pending]) -> Element
    ) throws(SubscriptionFailure) -> MainActorSnapshotSequence<Element> {
        try MainActorSnapshotSequence(transform) { (receive, finish) throws(SubscriptionFailure) in
            try subscribePending(receive, onFinish: finish)
        }
    }
    /// Registers a single-pass latest-value sequence of `Sendable` projections of the retained completions,
    /// taking a subscriber slot when called.
    ///
    /// `transform` runs on the main actor. The sequence supports every `AsyncSequence` operator on
    /// every supported OS version.
    public func sendablePendingCompletionUpdates<Element: Sendable>(
        _ transform: @escaping @MainActor ([Ledger.Pending]) -> Element
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        try SnapshotSequence(mainActor: transform) { (receive, finish, gate) throws(SubscriptionFailure) in
            try subscribePending(receive, onFinish: finish, gate: gate)
        }
    }
}

/// Remembers the last projection a registration offered, so that an equal successor is not offered.
///
/// One registration calls it serially. The equality check runs between loading and installing the
/// record, outside the installation primitive's lock, and a displaced projection is released after it.
nonisolated package final class RuntimeDistinctProjection<Value: Equatable & Sendable>: Sendable {
    private let last = AtomicRecordStorage<Value?>(nil)

    package init() {}

    /// Returns `value` when it differs from the last admitted projection, and `nil` otherwise.
    package func admit(_ value: Value) -> Value? {
        while true {
            let previous = last.load()
            if let prior = previous.value, prior == value { return nil }
            if last.install(.init(value), replacing: previous) { return value }
        }
    }
}

extension RuntimeSharedHost {
    /// Registers a single-pass latest-value sequence of projected snapshots that omits a projection
    /// equal to the one before it, taking a subscriber slot when
    /// called.
    ///
    /// `transform` and the comparison run on the registration's serial delivery path, outside every lock.
    public func distinctSnapshots<Element: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Engine.Snapshot) -> Element
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        let distinct = RuntimeDistinctProjection<Element>()
        return try SnapshotSequence(
            { distinct.admit(transform($0)) },
            registering: {
                (receive, finish) throws(SubscriptionFailure) in
                try register(receive, onFinish: finish)
            }
        )
    }
}

extension RuntimeActorHost {
    /// Registers a single-pass latest-value sequence of projected snapshots that omits a projection
    /// equal to the one before it, taking a subscriber slot when
    /// called.
    ///
    /// `transform` and the comparison run in this actor's delivery turn, outside mutable access.
    public func distinctSnapshots<Element: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Engine.Snapshot) -> Element
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        let distinct = RuntimeDistinctProjection<Element>()
        return try SnapshotSequence({ distinct.admit(transform($0)) }) {
            (receive, finish) throws(SubscriptionFailure) in
            try subscribe(receive, onFinish: finish)
        }
    }
}

extension RuntimeMainActorHost {
    /// Registers a single-pass latest-value sequence of `Sendable` projections that omits a projection
    /// equal to the one before it.
    ///
    /// `transform` and the comparison run on the main actor, outside mutable access.
    public func distinctSendableSnapshots<Element: Sendable & Equatable>(
        _ transform: @escaping @MainActor (Engine.Snapshot) -> Element
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        let distinct = RuntimeDistinctProjection<Element>()
        return try SnapshotSequence(mainActor: { distinct.admit(transform($0)) }) {
            (receive, finish, gate) throws(SubscriptionFailure) in
            try subscribe(receive, onFinish: finish, gate: gate)
        }
    }
}

extension RuntimeIsolatedHost {
    /// Registers a single-consumer latest-value stream of complete snapshots, confined to the owning actor.
    public func snapshots(
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> IsolatedSnapshotSequence<Engine.Snapshot> {
        try snapshots({ $0 }, isolation: isolation)
    }
    /// Registers a single-consumer latest-value stream of projected snapshots, confined to the owning actor.
    public func snapshots<Element>(
        _ transform: @escaping (Engine.Snapshot) -> Element,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> IsolatedSnapshotSequence<Element> {
        try IsolatedSnapshotSequence(transform) { (receive, finish) throws(SubscriptionFailure) in
            try subscribe(receive, onFinish: finish, isolation: isolation)
        }
    }
    /// Registers a single-pass latest-value sequence of `Sendable` projections, taking a subscriber slot
    /// when called.
    ///
    /// `transform` runs on the owning actor when a snapshot is delivered. The sequence supports every
    /// `AsyncSequence` operator and may be consumed on any actor. Ending it on another actor stops
    /// delivery and frees its slot at once; the owning actor releases `transform` on this host's next
    /// turn, and when the host is released.
    public func sendableSnapshots<Element: Sendable>(
        _ transform: @escaping (Engine.Snapshot) -> Element,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        try SnapshotSequence(confined: transform) { (receive, finish) throws(SubscriptionFailure) in
            try subscribeSendable(receive, onFinish: finish, isolation: isolation)
        }
    }
    /// Registers a single-pass latest-value sequence of `Sendable` projections that omits a projection
    /// equal to the one before it.
    ///
    /// `transform` and the comparison run on the owning actor, outside mutable access.
    public func distinctSendableSnapshots<Element: Sendable & Equatable>(
        _ transform: @escaping (Engine.Snapshot) -> Element,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        let distinct = RuntimeDistinctProjection<Element>()
        return try SnapshotSequence(confined: { distinct.admit(transform($0)) }) {
            (receive, finish) throws(SubscriptionFailure) in
            try subscribeSendable(receive, onFinish: finish, isolation: isolation)
        }
    }
    /// Registers a single-consumer latest-value stream of the retained completions, projected by
    /// `transform` on the owning actor.
    ///
    /// Each element is the whole collection, starting with the one current at registration. A newer
    /// collection replaces one not yet read, and the stream ends after the final, empty collection
    /// that closing delivers.
    public func pendingCompletionUpdates<Element>(
        _ transform: @escaping ([Ledger.Pending]) -> Element,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> IsolatedSnapshotSequence<Element> {
        try IsolatedSnapshotSequence(transform) { (receive, finish) throws(SubscriptionFailure) in
            try subscribePending(receive, onFinish: finish, isolation: isolation)
        }
    }
    /// Registers a single-pass latest-value sequence of `Sendable` projections of the retained completions,
    /// taking a subscriber slot when called.
    ///
    /// `transform` runs on the owning actor. The sequence supports every `AsyncSequence` operator.
    public func sendablePendingCompletionUpdates<Element: Sendable>(
        _ transform: @escaping ([Ledger.Pending]) -> Element,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Element> {
        try SnapshotSequence(confined: transform) { (receive, finish) throws(SubscriptionFailure) in
            try subscribeSendablePending(receive, onFinish: finish, isolation: isolation)
        }
    }
}
