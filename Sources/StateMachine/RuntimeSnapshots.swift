/// A single-pass asynchronous sequence of an owner's complete snapshots.
///
/// Creating the sequence registers one observer. The first element is the snapshot that was
/// current at registration unless a newer one has replaced it, and later elements have strictly
/// increasing revisions. One pending snapshot is retained: a consumer that reads slowly receives
/// the latest value and never an older one.
///
/// The sequence ends after the owner's closed snapshot, when the consuming task is cancelled, or
/// when the owner is released without closing. Only the first iterator receives elements; a later
/// iterator ends immediately. Releasing the sequence and its iterator removes the registration,
/// and the sequence does not keep its owner alive.
nonisolated public struct RuntimeSnapshots<Element: Sendable>: AsyncSequence, Sendable {
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
            current.cancel()
            return nil
        }
    }

    // Capacity one. Continuations are resumed and displaced values are released after
    // the installation primitive has unlocked.
    fileprivate final class Mailbox: Sendable {
        private struct State: Sendable {
            var pending: Element?
            var waiter: CheckedContinuation<Element?, Never>?
            var finished = false
            var cancelled = false
            var claimed = false
        }
        private let storage = AtomicRecordStorage(State())

        func claim() -> Bool {
            while true {
                let previous = storage.load()
                guard !previous.value.claimed else { return false }
                var next = previous.value
                next.claimed = true
                if storage.install(.init(next), replacing: previous) { return true }
            }
        }

        func offer(_ element: Element) {
            while true {
                let previous = storage.load()
                guard !previous.value.finished, !previous.value.cancelled else { return }
                var next = previous.value
                let waiter = next.waiter
                next.waiter = nil
                if waiter == nil { next.pending = element }
                if storage.install(.init(next), replacing: previous) {
                    waiter?.resume(returning: element)
                    return
                }
            }
        }

        // A pending final value stays readable after the mailbox has finished.
        func finish() {
            while true {
                let previous = storage.load()
                guard !previous.value.finished else { return }
                var next = previous.value
                next.finished = true
                let waiter = next.waiter
                next.waiter = nil
                if storage.install(.init(next), replacing: previous) {
                    waiter?.resume(returning: nil)
                    return
                }
            }
        }

        // Runs inside a task cancellation handler, so it only records the flag and wakes
        // the consumer. The consumer removes its registration on its own task.
        func cancel() {
            while true {
                let previous = storage.load()
                guard !previous.value.cancelled else { return }
                var next = previous.value
                next.cancelled = true
                let waiter = next.waiter
                next.waiter = nil
                if storage.install(.init(next), replacing: previous) {
                    waiter?.resume(returning: nil)
                    return
                }
            }
        }

        nonisolated(nonsending) func next() async -> Element? {
            await withTaskCancellationHandler {
                await withCheckedContinuation { wait($0) }
            } onCancel: {
                cancel()
            }
        }

        // The cancelled flag is read in the same installation that stores the waiter,
        // so a cancellation on either side of it resumes the consumer.
        private func wait(_ continuation: CheckedContinuation<Element?, Never>) {
            while true {
                let previous = storage.load()
                var next = previous.value
                if next.cancelled || next.waiter != nil {
                    continuation.resume(returning: nil)
                    return
                }
                if let pending = next.pending {
                    next.pending = nil
                    guard storage.install(.init(next), replacing: previous) else { continue }
                    continuation.resume(returning: pending)
                    return
                }
                if next.finished {
                    continuation.resume(returning: nil)
                    return
                }
                next.waiter = continuation
                if storage.install(.init(next), replacing: previous) { return }
            }
        }
    }

    // The only object an owner's callbacks retain. An owner releases its callbacks when
    // it closes, when the registration is removed, and when the owner itself is
    // released, so each of those ends the sequence.
    private final class Feeder: Sendable {
        let mailbox: Mailbox
        private let onDetach: @Sendable () -> Void

        init(_ mailbox: Mailbox, onDetach: @escaping @Sendable () -> Void) {
            self.mailbox = mailbox
            self.onDetach = onDetach
        }
        deinit {
            mailbox.finish()
            onDetach()
        }
    }

    // Releasing the token removes the registration; `cancel` removes it early.
    fileprivate final class Lifetime: Sendable {
        let mailbox: Mailbox
        let cancel: @Sendable () -> Void
        private let token: any Sendable

        init(_ mailbox: Mailbox, _ token: any Sendable, cancel: @escaping @Sendable () -> Void) {
            self.mailbox = mailbox
            self.token = token
            self.cancel = cancel
        }
    }

    private let lifetime: Lifetime

    /// Registers through `register` and projects each raw observation with `transform`.
    ///
    /// `onDetach` runs once the owner has released this sequence's callbacks.
    package init<Raw>(
        _ transform: @escaping @Sendable (Raw) -> Element,
        onDetach: @escaping @Sendable () -> Void = {},
        register: (
            _ receive: @escaping @Sendable (Raw) -> Void,
            _ finish: @escaping @Sendable () -> Void
        ) throws(RuntimeHostSubscriptionFailure) -> RuntimeSubscription
    ) throws(RuntimeHostSubscriptionFailure) {
        let mailbox = Mailbox()
        let feeder = Feeder(mailbox, onDetach: onDetach)
        let token = try register({ feeder.mailbox.offer(transform($0)) }, { feeder.mailbox.finish() })
        lifetime = Lifetime(mailbox, token) { token.cancel() }
    }

    /// Registers with a `MainActor` owner through `register` and projects each raw observation
    /// with `transform` on the main actor.
    ///
    /// `onDetach` runs once the owner has released this sequence's callbacks.
    @MainActor package init<Raw>(
        mainActor transform: @escaping @MainActor (Raw) -> Element,
        onDetach: @escaping @Sendable () -> Void = {},
        register: (
            _ receive: @escaping @MainActor (Raw) -> Void,
            _ finish: @escaping @MainActor () -> Void
        ) throws(RuntimeHostSubscriptionFailure) -> RuntimeMainActorSubscription
    ) throws(RuntimeHostSubscriptionFailure) {
        let mailbox = Mailbox()
        let feeder = Feeder(mailbox, onDetach: onDetach)
        let token = try register({ feeder.mailbox.offer(transform($0)) }, { feeder.mailbox.finish() })
        // The consumer may finish on any actor; the registration is removed on the main actor.
        lifetime = Lifetime(mailbox, token) { Task { @MainActor in token.cancel() } }
    }

    /// Claims the sequence for one consumer; a later iterator ends immediately.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(lifetime: lifetime.mailbox.claim() ? lifetime : nil)
    }
}

/// A single-pass asynchronous sequence of a `MainActor` owner's complete snapshots.
///
/// The sequence is iterated on the main actor, which lets it carry snapshots that are not
/// `Sendable`. Creating it registers one observer. The first element is the snapshot that was
/// current at registration unless a newer one has replaced it, and later elements have strictly
/// increasing revisions. One pending snapshot is retained: a consumer that reads slowly receives
/// the latest value and never an older one.
///
/// The sequence ends after the owner's closed snapshot, when the consuming task is cancelled, or
/// when the owner is released without closing. Only the first iterator receives elements; a later
/// iterator ends immediately. Releasing the sequence and its iterator removes the registration,
/// and the sequence does not keep its owner alive.
///
/// The conformance to `AsyncSequence` is isolated to the main actor. Iterating with `for await`
/// is available on every supported OS version. Sequence operators such as `map` and generic
/// `AsyncSequence` algorithms require a deployment target of iOS 18, macOS 15, tvOS 18,
/// watchOS 11, or visionOS 2. A `Sendable` element has no such requirement when it is observed
/// through ``RuntimeMainActorHost/sendableSnapshots()`` or ``RuntimeMainActorHost/sendableSnapshots(_:)``.
nonisolated public struct RuntimeMainActorSnapshots<Element> {
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
        private var claimed = false

        func claim() -> Bool {
            guard !claimed else { return false }
            claimed = true
            return true
        }

        func offer(_ element: Element) {
            guard !finished else { return }
            pending = element
            wake(cancelling: false)
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
                // A consumer cancelled before it waits has installed no handler, so the task is asked too.
                if signal.load().value.cancelled || Task.isCancelled { return nil }
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
                if next.cancelled || next.waiter != nil {
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
    // released, so each of those ends the sequence. Release can happen on any thread
    // and inside the owner's own mutation, so the mailbox is finished on a later turn.
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

    fileprivate final class Lifetime: Sendable {
        let mailbox: Mailbox
        let token: RuntimeMainActorSubscription

        init(_ mailbox: Mailbox, _ token: RuntimeMainActorSubscription) {
            self.mailbox = mailbox
            self.token = token
        }
    }

    private let lifetime: Lifetime

    /// Registers through `register` and projects each raw observation with `transform`.
    ///
    /// `onDetach` runs once the owner has released this sequence's callbacks.
    @MainActor package init<Raw>(
        _ transform: @escaping @MainActor (Raw) -> Element,
        onDetach: @escaping @Sendable () -> Void = {},
        register: (
            _ receive: @escaping @MainActor (Raw) -> Void,
            _ finish: @escaping @MainActor () -> Void
        ) throws(RuntimeHostSubscriptionFailure) -> RuntimeMainActorSubscription
    ) throws(RuntimeHostSubscriptionFailure) {
        let mailbox = Mailbox()
        let feeder = Feeder(mailbox, onDetach: onDetach)
        let token = try register({ feeder.mailbox.offer(transform($0)) }, { feeder.mailbox.finish() })
        lifetime = Lifetime(mailbox, token)
    }
}

extension RuntimeMainActorSnapshots: @MainActor AsyncSequence {
    /// Iteration never throws.
    public typealias Failure = Never

    /// The sole consumer of a snapshot sequence.
    @MainActor public struct AsyncIterator: @MainActor AsyncIteratorProtocol {
        fileprivate var lifetime: Lifetime?

        /// Returns the latest unread snapshot, waiting for one when none is pending.
        ///
        /// Returns `nil` once the sequence has ended, and removes the registration.
        public mutating func next() async -> Element? {
            guard let current = lifetime else { return nil }
            if let element = await current.mailbox.next() { return element }
            lifetime = nil
            current.token.cancel()
            return nil
        }
    }

    /// Claims the sequence for one consumer; a later iterator ends immediately.
    @MainActor public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(lifetime: lifetime.mailbox.claim() ? lifetime : nil)
    }
}

extension RuntimeSharedHost {
    /// Registers a single-pass latest-value sequence of complete snapshots.
    public func snapshots() throws(SubscriptionFailure) -> RuntimeSnapshots<Engine.Snapshot> {
        try snapshots { $0 }
    }
    /// Registers a single-pass latest-value sequence of projected snapshots.
    public func snapshots<Element: Sendable>(
        _ transform: @escaping @Sendable (Engine.Snapshot) -> Element
    ) throws(SubscriptionFailure) -> RuntimeSnapshots<Element> {
        try snapshots(transform, onDetach: {})
    }
    /// Registers a sequence and reports when this host has released its callbacks.
    package func snapshots<Element: Sendable>(
        _ transform: @escaping @Sendable (Engine.Snapshot) -> Element,
        onDetach: @escaping @Sendable () -> Void
    ) throws(SubscriptionFailure) -> RuntimeSnapshots<Element> {
        try RuntimeSnapshots(transform, onDetach: onDetach) {
            (receive, finish) throws(RuntimeHostSubscriptionFailure) in
            try subscribe(receive, onFinish: finish)
        }
    }
}

extension RuntimeActorHost {
    /// Registers a single-pass latest-value sequence of complete snapshots.
    public func snapshots() throws(RuntimeHostSubscriptionFailure) -> RuntimeSnapshots<Engine.Snapshot> {
        try snapshots { $0 }
    }
    /// Registers a single-pass latest-value sequence of projected snapshots.
    public func snapshots<Element: Sendable>(
        _ transform: @escaping @Sendable (Engine.Snapshot) -> Element
    ) throws(RuntimeHostSubscriptionFailure) -> RuntimeSnapshots<Element> {
        try snapshots(transform, onDetach: {})
    }
    /// Registers a sequence and reports when this host has released its callbacks.
    package func snapshots<Element: Sendable>(
        _ transform: @escaping @Sendable (Engine.Snapshot) -> Element,
        onDetach: @escaping @Sendable () -> Void
    ) throws(RuntimeHostSubscriptionFailure) -> RuntimeSnapshots<Element> {
        try RuntimeSnapshots(transform, onDetach: onDetach) {
            (receive, finish) throws(RuntimeHostSubscriptionFailure) in
            try subscribe(receive, onFinish: finish)
        }
    }
}

extension RuntimeMainActorHost {
    /// Registers a single-pass latest-value sequence of complete snapshots.
    public func snapshots() throws(RuntimeHostSubscriptionFailure) -> RuntimeMainActorSnapshots<Engine.Snapshot> {
        try snapshots { $0 }
    }
    /// Registers a single-pass latest-value sequence of projected snapshots.
    public func snapshots<Element>(
        _ transform: @escaping @MainActor (Engine.Snapshot) -> Element
    ) throws(RuntimeHostSubscriptionFailure) -> RuntimeMainActorSnapshots<Element> {
        try snapshots(transform, onDetach: {})
    }
    /// Registers a sequence and reports when this host has released its callbacks.
    package func snapshots<Element>(
        _ transform: @escaping @MainActor (Engine.Snapshot) -> Element,
        onDetach: @escaping @Sendable () -> Void
    ) throws(RuntimeHostSubscriptionFailure) -> RuntimeMainActorSnapshots<Element> {
        try RuntimeMainActorSnapshots(transform, onDetach: onDetach) {
            (receive, finish) throws(RuntimeHostSubscriptionFailure) in
            try subscribe(receive, onFinish: finish)
        }
    }

    /// Registers a single-pass latest-value sequence of complete `Sendable` snapshots.
    ///
    /// The sequence supports every `AsyncSequence` operator on every supported OS version.
    public func sendableSnapshots() throws(RuntimeHostSubscriptionFailure) -> RuntimeSnapshots<Engine.Snapshot>
    where Engine.Snapshot: Sendable {
        try sendableSnapshots { $0 }
    }
    /// Registers a single-pass latest-value sequence of `Sendable` projections.
    ///
    /// `transform` runs on the main actor when a snapshot is delivered. The sequence supports
    /// every `AsyncSequence` operator on every supported OS version.
    public func sendableSnapshots<Element: Sendable>(
        _ transform: @escaping @MainActor (Engine.Snapshot) -> Element
    ) throws(RuntimeHostSubscriptionFailure) -> RuntimeSnapshots<Element> {
        try sendableSnapshots(transform, onDetach: {})
    }
    /// Registers a sequence and reports when this host has released its callbacks.
    package func sendableSnapshots<Element: Sendable>(
        _ transform: @escaping @MainActor (Engine.Snapshot) -> Element,
        onDetach: @escaping @Sendable () -> Void
    ) throws(RuntimeHostSubscriptionFailure) -> RuntimeSnapshots<Element> {
        try RuntimeSnapshots(mainActor: transform, onDetach: onDetach) {
            (receive, finish) throws(RuntimeHostSubscriptionFailure) in
            try subscribe(receive, onFinish: finish)
        }
    }
}
