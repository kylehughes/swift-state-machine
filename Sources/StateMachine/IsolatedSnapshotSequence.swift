/// A single-consumer stream of the snapshots of an owner confined to one actor.
///
/// It belongs to the region of the actor that owns its host, which lets it carry snapshots that are
/// not `Sendable`, and the compiler keeps it there: it is created and read on that actor. Read it
/// with `next()`:
///
/// ```swift
/// var snapshots = try host.snapshots()
/// while let snapshot = await snapshots.next() { show(snapshot) }
/// ```
///
/// It is deliberately not an `AsyncSequence`. The standard sequence operators run their closures, and
/// on earlier systems their iteration, off the caller's actor, which would move a confined snapshot
/// off its actor. For `for await`, operators, or generic `AsyncSequence` code, register a `Sendable`
/// projection, whose result is a ``SnapshotSequence``: a generated `IsolatedHost` registers one with
/// `snapshots(_:)`, and a raw `RuntimeIsolatedHost` with `sendableSnapshots(_:isolation:)`, whose
/// `snapshots(_:isolation:)` returns this confined stream of the projected values instead.
///
/// Creating it registers one observer. The first element is the snapshot that was current at
/// registration unless a newer one has replaced it, and later elements have strictly increasing
/// revisions. One pending snapshot is retained: a consumer that reads slowly receives the latest
/// value and never an older one. It is noncopyable, so it has exactly one consumer.
///
/// It ends after the owner's closed snapshot, when the owner is released without closing, when
/// ``cancel(isolation:)`` is called, and when a read finds its task cancelled, whether it was
/// cancelled before or during the read. A task that stops reading never gives it that chance. Ending
/// it on the owning actor, by reading its end or with ``cancel(isolation:)``, removes the registration
/// and releases the snapshot it held unread there before returning; these are the two ways to release
/// that snapshot on the owning actor deterministically. Dropping it before it ends, which can happen
/// on another thread when an object that stores it is released there, stops delivery and frees its
/// slot at once, and the snapshot it held unread is released wherever the last reference to it goes:
/// while the host still holds the registration's callbacks, which share that reference, the host
/// releases them, and the snapshot, when it next sweeps its registrations on the owning actor; once
/// the host has finished the registration, as closing does, the stream holds the snapshot alone and
/// releases it where it is dropped. A stream kept beyond its loop, such as one an object on the owning
/// actor stores, ends with ``cancel(isolation:)``. It does not keep its owner alive. If an unread
/// projection retains the host, call ``cancel(isolation:)`` before dropping the stream to break that
/// reference cycle: the callbacks the host holds until its next sweep share the projection.
nonisolated public struct IsolatedSnapshotSequence<Element>: ~Copyable {
    // The waiter slot and the cancellation and termination flags, which a task cancellation handler and
    // the feeder's destructor reach from any thread.
    fileprivate final class Signal: Sendable {
        private struct State: Sendable {
            var waiter: CheckedContinuation<Void, Never>?
            var cancelled = false
            var finished = false
        }
        private let storage = AtomicRecordStorage(State())

        var isCancelled: Bool { storage.load().value.cancelled }
        var isFinished: Bool { storage.load().value.finished }

        // Records the flag, then resumes the waiting consumer outside the installation primitive.
        func wake(cancelling: Bool = false, finishing: Bool = false) {
            while true {
                let previous = storage.load()
                let raises = (cancelling && !previous.value.cancelled) || (finishing && !previous.value.finished)
                guard previous.value.waiter != nil || raises else { return }
                var next = previous.value
                let waiter = next.waiter
                next.waiter = nil
                if cancelling { next.cancelled = true }
                if finishing { next.finished = true }
                if storage.install(.init(next), replacing: previous) {
                    waiter?.resume()
                    return
                }
            }
        }

        func wait(_ continuation: CheckedContinuation<Void, Never>) {
            while true {
                let previous = storage.load()
                var next = previous.value
                if next.cancelled || next.finished {
                    continuation.resume()
                    return
                }
                next.waiter = continuation
                if storage.install(.init(next), replacing: previous) { return }
            }
        }
    }

    // Confined to the owning actor, except for its signal.
    fileprivate final class Mailbox {
        let signal = Signal()
        private var pending: Element?

        func offer(_ element: Element) {
            guard !signal.isFinished, !signal.isCancelled else { return }
            let displaced = pending
            pending = element
            signal.wake()
            withExtendedLifetime(displaced) {}
        }

        /// Ends the stream on the owning actor: records the cancellation and returns the element no
        /// later read can return, for the caller to release once the stream is consistent.
        func discard() -> Element? {
            signal.wake(cancelling: true)
            let discarded = pending
            pending = nil
            return discarded
        }

        // A pending final value stays readable after the mailbox has finished.
        func finish() { signal.wake(finishing: true) }

        // The continuation is a wake signal only. The element is read here, on the owning actor, so no
        // snapshot crosses an isolation boundary.
        nonisolated(nonsending) func next() async -> Element? {
            while true {
                // A consumer cancelled before it waits has installed no handler, so the task is asked
                // too. The element no later read can return stays until the stream has removed its
                // registration, and is then discarded on the owning actor.
                if signal.isCancelled || Task.isCancelled {
                    signal.wake(cancelling: true)
                    return nil
                }
                if let element = pending {
                    pending = nil
                    return element
                }
                if signal.isFinished { return nil }
                let signal = signal
                await withTaskCancellationHandler {
                    await withCheckedContinuation { wait($0) }
                } onCancel: {
                    signal.wake(cancelling: true)
                }
            }
        }

        private func wait(_ continuation: CheckedContinuation<Void, Never>) {
            guard pending == nil else {
                continuation.resume()
                return
            }
            signal.wait(continuation)
        }
    }

    // The only object an owner's callbacks retain. An owner releases its callbacks when it closes, when
    // the registration is removed, and when the owner itself is released, so each of those ends the
    // stream. The owner can be released on another thread, so the feeder ends the stream through the
    // signal alone and never touches the confined mailbox.
    private final class Feeder: Sendable {
        let signal: Signal

        init(_ signal: Signal) { self.signal = signal }
        deinit { signal.wake(finishing: true) }
    }

    private let mailbox: Mailbox
    // Ends the registration from `next()`, which runs on the owning actor, and runs its continuation
    // once the token's cancellation has returned; dropping it unread only closes the registration's
    // gate.
    private var end: (((any Actor)?, (() -> Void)?) -> Void)?

    /// Registers through `register` and projects each raw observation with `transform` on the owning actor.
    ///
    /// An observation that `transform` maps to `nil` is not offered. The callbacks share the mailbox
    /// with the stream, so while the host holds them, a stream dropped on another thread leaves the
    /// mailbox, and the element it holds, for the host to release on the owning actor. Nothing can move
    /// the mailbox to that actor from a destructor: the region checker rejects sending a value of the
    /// actor's region from a nonisolated context, and `isolated deinit` is unavailable at the
    /// deployment floor.
    package init<Raw, Owner: Actor>(
        _ transform: @escaping (Raw) -> Element?,
        register: (
            _ receive: @escaping (Raw) -> Void,
            _ finish: @escaping () -> Void
        ) throws(SubscriptionFailure) -> IsolatedSnapshotSubscription<Owner>
    ) throws(SubscriptionFailure) {
        let mailbox = Mailbox()
        let feeder = Feeder(mailbox.signal)
        // The callbacks run on the owning actor, so they reach the confined mailbox; the feeder they
        // retain only signals.
        let token = try register(
            { if let element = transform($0) { withExtendedLifetime(feeder) { mailbox.offer(element) } } },
            { withExtendedLifetime(feeder) { mailbox.finish() } }
        )
        end = { token.end(on: $0, then: $1) }
        self.mailbox = mailbox
    }

    /// Returns the latest unread snapshot, waiting for one when none is pending.
    ///
    /// Returns `nil` once the stream has ended, and removes the registration. The call runs on the
    /// caller's actor, which is the actor that owns the host.
    nonisolated(nonsending) public mutating func next() async -> Element? {
        guard end != nil else { return nil }
        if let element = await mailbox.next() { return element }
        // The caller's actor is the owning actor, which the registration checks before removing itself.
        finish(isolation: #isolation)
        return nil
    }

    /// Ends the stream and removes its registration before returning.
    ///
    /// Every later `next()` returns `nil`, and a snapshot still unread is released before this
    /// returns, unless the host is cancelling the registration's token at that moment, as a host of
    /// your own that ends the stream from its `onCancel` does: the snapshot is then released once that
    /// cancellation returns. `isolation` is the owning actor, which a call there passes by default,
    /// since the stream stays in that actor's region; it is not optional, so a call from a nonisolated
    /// context does not compile. Calling it again, or after the stream has ended, changes nothing.
    public mutating func cancel(isolation: isolated any Actor = #isolation) { finish(isolation: isolation) }

    // Takes the element no read can return any more and ends the registration, releasing that element
    // once the token's cancellation has returned, so a destructor that registers again finds the slot
    // free.
    private mutating func finish(isolation: (any Actor)?) {
        let discarded = mailbox.discard()
        let ended = end
        end = nil
        guard let ended else {
            withExtendedLifetime(discarded) {}
            return
        }
        ended(isolation) { withExtendedLifetime(discarded) {} }
    }
}
