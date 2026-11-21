import Dispatch
import StateMachine
import StateMachineExamples
import StateMachineTestSupport
import Testing
import os

// Every release of a registration follows one order: close its gate, remove the registration, clear
// the record of its token, and only then release the client values it held, outside every lock and on
// the actor that owns them. A destructor that registers again therefore finds the slot free, a
// concurrent canceller cannot return while the registration still begins callbacks, and nothing the
// token captured outlives its cancellation. Whether a `MainActor` owner's registration is removed before
// `cancel()` returns depends on the caller's isolation, never on the thread it runs on.

/// A one-shot event a test awaits instead of inferring progress from scheduling.
private struct Signal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
    func raise() { continuation.yield(()) }
    /// Returns once the event is raised, or at once when the waiting task is cancelled.
    ///
    /// - Returns: Whether the event was raised.
    @discardableResult func wait() async -> Bool {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() != nil
    }
}

/// A value whose destructor runs a hook on whichever thread releases it.
private final class Released: Sendable {
    let number: UInt64
    private let hook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

    init(_ number: UInt64) { self.number = number }
    func onRelease(_ hook: @escaping @Sendable () -> Void) { self.hook.withLock { $0 = hook } }
    deinit { hook.withLock { $0 }?() }
}

/// A value that is not `Sendable`, whose destructor runs a hook on the actor that releases it.
private final class Confined {
    var onRelease: (() -> Void)?
    deinit { onRelease?() }
}

/// An object a test watches through a weak reference.
private final class Sentinel: Sendable {}

/// A weak reference that any thread reads.
private final class WeakSentinel: Sendable {
    private let reference = OSAllocatedUnfairLock<Weak>(initialState: Weak())
    private struct Weak: @unchecked Sendable { weak var value: Sentinel? }
    init(_ value: Sentinel) { reference.withLock { $0.value = value } }
    var isAlive: Bool { reference.withLock { $0.value != nil } }
}

/// What a destructor's second registration did.
private enum Outcome: Sendable, Equatable {
    case none, registered, refused
}

/// Records one outcome from any thread.
private final class OutcomeRecord: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: Outcome.none)
    var result: Outcome { value.withLock { $0 } }
    func record(_ outcome: Outcome) { value.withLock { $0 = outcome } }
}

/// A `MainActor` host of the test's own with one subscriber slot.
///
/// It frees the slot when the subscription it returned is cancelled. Its sequences are the protocol's
/// default projection.
@MainActor private final class OneSlotHost: MainActorStateMachineHost {
    typealias Inner = GeneratedTransfers.MainActorHost
    private let inner: Inner
    private(set) var registrations = 0 {
        didSet {
            let current = registrations
            held.withLock { $0 = current }
        }
    }
    /// The registrations, readable from any thread.
    nonisolated let held = OSAllocatedUnfairLock(initialState: 0)
    /// Captured by the next subscription's cancellation, which runs `onCancel` after freeing the slot.
    var captured: Sentinel?
    var onCancel: (@MainActor () -> Void)?
    /// Finishes the next registration inside the registration call, as a host that closes then does.
    var finishWhileRegistering = false

    init() throws {
        inner = GeneratedTransfers.MainActorHost(
            downloadDriver: { _, _ in .success("") },
            onLogged: { _ in },
            configuration: try GeneratedTransfers.Configuration(subscribers: 8)
        )
    }

    func snapshot() -> Inner.Snapshot { inner.snapshot() }
    @discardableResult func send(_ input: Inner.Input) throws(Inner.SendRejection) -> Inner.Receipt {
        try inner.send(input)
    }
    func commit(_ prepared: consuming Inner.Prepared) -> Inner.CommitResult { inner.commit(prepared) }
    func subscribe(
        _ receive: @escaping @MainActor (Inner.Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        guard registrations == 0 else { throw .capacityExceeded }
        let token = try inner.subscribe(receive, onFinish: onFinish)
        registrations += 1
        let captured = captured
        self.captured = nil
        if finishWhileRegistering {
            finishWhileRegistering = false
            onFinish()
        }
        return MainActorSnapshotSubscription { [weak self] in
            withExtendedLifetime(captured) {}
            self?.registrations -= 1
            token.cancel()
            self?.onCancel?()
        }
    }
    func close() -> Inner.Receipt { inner.close() }

    /// Registers a sequence again and cancels it, recording whether the slot was free.
    func registerAgain(into outcome: OutcomeRecord) {
        do {
            try snapshots { $0.revision }.cancel()
            outcome.record(.registered)
        } catch {
            outcome.record(.refused)
        }
    }
}

/// A serial executor that runs its jobs on the main dispatch queue, as an executor of a framework's own
/// may, under its own identity rather than the main actor's.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
private final class MainQueueExecutor: SerialExecutor {
    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedSerialExecutor()
        DispatchQueue.main.async { job.runSynchronously(on: executor) }
    }
    func asUnownedSerialExecutor() -> UnownedSerialExecutor { UnownedSerialExecutor(ordinary: self) }
}

/// An actor whose jobs run on the main thread without being main-actor jobs.
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
private actor MainThreadActor {
    private static let executor = MainQueueExecutor()
    nonisolated var unownedExecutor: UnownedSerialExecutor { Self.executor.asUnownedSerialExecutor() }
    private let cancelling = OSAllocatedUnfairLock(initialState: false)

    /// Whether this actor is inside `cancel(_:)`.
    nonisolated var isCancelling: Bool { cancelling.withLock { $0 } }

    func cancel(_ snapshots: SnapshotSequence<UInt64>) {
        cancelling.withLock { $0 = true }
        snapshots.cancel()
        cancelling.withLock { $0 = false }
    }
}

@Suite(.timeLimit(.minutes(1))) struct CancellationIsolationTests {
    // A job of an actor whose executor runs on the main thread is not a main-actor job. Its `cancel()`
    // leaves the main-actor removal to the main actor, which runs it after the job, instead of running
    // main-actor code from it.
    @MainActor @Test func aCancellationOnTheMainThreadOutsideTheMainActorLeavesTheRemovalToIt() async throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let host = try OneSlotHost()
        let snapshots = try host.snapshots { $0.revision }
        let actor = MainThreadActor()
        let removed = Signal()
        var removedInsideTheJob: Bool?
        host.onCancel = {
            removedInsideTheJob = actor.isCancelling
            removed.raise()
        }
        await actor.cancel(snapshots)
        await removed.wait()
        #expect(removedInsideTheJob == false)
        #expect(host.registrations == 0)
    }

    // A call isolated to the main actor removes the registration before it returns.
    @MainActor @Test func aCancellationIsolatedToTheMainActorRemovesTheRegistrationAtOnce() throws {
        let host = try OneSlotHost()
        let snapshots = try host.snapshots { $0.revision }
        snapshots.cancel(isolation: MainActor.shared)
        #expect(host.registrations == 0)
    }
}

@Suite(.timeLimit(.minutes(1))) struct CancellationOrderingTests {
    // The first canceller of a token is still inside its cancellation, which closes the registration's
    // gate only at its end. A second canceller that finds the cancellation taken returns after the gate
    // closed, because every call closes the gate before it reads the cancellation.
    //
    // A cancelled test lets the first canceller go on its way out: its wait for the first to enter ends
    // at once, and it does not cancel the token itself, which would make it the first canceller.
    @Test func aSecondTokenCancellerReturnsAfterTheGateClosed() async {
        let gate = RuntimeRegistrationGate()
        let entered = Signal()
        let proceed = ThreadGate()
        defer { proceed.open() }
        let token = SnapshotSubscription(gate: gate) {
            entered.raise()
            proceed.waitUnlessCancelled()
            gate.close()
        }
        let finished = Signal()
        runOnOwnThread {
            token.cancel()
            finished.raise()
        }
        guard await entered.wait() else { return }
        token.cancel()
        #expect(!gate.isOpen)
        proceed.open()
        await finished.wait()
    }

    // A shared owner's delivery claims the next envelope after a canceller closed the registration's gate
    // and before it cancelled the mailbox. The callback does not begin, and the envelope's value is
    // released without it.
    @Test func aDeliveryClaimedAfterTheGateClosedDoesNotBegin() async {
        let calls = OSAllocatedUnfairLock(initialState: [UInt64]())
        let released = Signal()
        let holder = OSAllocatedUnfairLock<LatestMailbox<Released>?>(initialState: nil)
        let mailbox = LatestMailbox<Released>(
            initial: Released(0),
            revision: 0,
            terminal: false,
            receive: { value in
                calls.withLock { $0.append(value.number) }
                guard value.number == 0, let mailbox = holder.withLock({ $0 }) else { return }
                // A canceller closes the gate and pauses; the owner offers the next snapshot.
                mailbox.gate.close()
                let next = Released(1)
                next.onRelease { released.raise() }
                mailbox.offer(next, revision: 1, terminal: false)
            },
            finish: {}
        )
        holder.withLock { $0 = mailbox }
        mailbox.activate()
        await released.wait()
        #expect(calls.withLock { $0 } == [0])
        mailbox.cancel()
        holder.withLock { $0 = nil }
    }

    // A `MainActor` host's subscription is cancelled off the main actor, so the main actor removes it on a
    // later turn. Once it has, the sequence keeps nothing the subscription captured, though the sequence
    // itself is kept.
    @MainActor @Test func aQueuedRemovalKeepsNothingTheTokenCaptured() async throws {
        let host = try OneSlotHost()
        var sentinel: Sentinel? = Sentinel()
        let watched = WeakSentinel(sentinel!)
        host.captured = sentinel
        sentinel = nil
        let removed = Signal()
        host.onCancel = { removed.raise() }
        let snapshots = try host.snapshots { $0.revision }
        await Task.detached { snapshots.cancel() }.value
        await removed.wait()
        #expect(!watched.isAlive)
        #expect(host.registrations == 0)
        withExtendedLifetime(snapshots) {}
    }

    // The host finishes the registration inside its registration call, before it returns the token. The
    // token is cancelled before the sequence is returned, and the sequence keeps nothing it captured.
    @MainActor @Test func aRegistrationFinishedBeforeItsTokenArrivesKeepsNothingTheTokenCaptured() async throws {
        let host = try OneSlotHost()
        var sentinel: Sentinel? = Sentinel()
        let watched = WeakSentinel(sentinel!)
        host.captured = sentinel
        sentinel = nil
        host.finishWhileRegistering = true
        let removed = Signal()
        host.onCancel = { removed.raise() }
        let snapshots = try host.snapshots { $0.revision }
        await removed.wait()
        #expect(!watched.isAlive)
        #expect(host.registrations == 0)
        withExtendedLifetime(snapshots) {}
    }

    // Cancelled off the main actor, the sequence leaves the subscription's cancellation to the main
    // actor. The unread projection is released only after that cancellation has freed the slot.
    @MainActor @Test func aQueuedRemovalReleasesTheUnreadElementAfterIt() async throws {
        let host = try OneSlotHost()
        let heldAtRelease = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let released = Signal()
        let held = host.held
        let snapshots = try host.snapshots { snapshot in
            let projection = Released(snapshot.revision)
            projection.onRelease {
                heldAtRelease.withLock { $0 = held.withLock { $0 } }
                released.raise()
            }
            return projection
        }
        await Task.detached { snapshots.cancel() }.value
        await released.wait()
        #expect(heldAtRelease.withLock { $0 } == 0)
        #expect(host.registrations == 0)
    }

    // A one-slot `MainActor` host of the test's own holds an unread projection when the sequence is
    // cancelled on the main actor. The projection is released only after the subscription is cancelled,
    // so its destructor registers again.
    @MainActor @Test func cancellingReleasesAnUnreadElementOnceTheSlotIsFree() throws {
        let host = try OneSlotHost()
        let outcome = OutcomeRecord()
        let snapshots = try host.snapshots { snapshot in
            let projection = Released(snapshot.revision)
            projection.onRelease { MainActor.assumeIsolated { host.registerAgain(into: outcome) } }
            return projection
        }
        snapshots.cancel()
        #expect(outcome.result == .registered)
        #expect(host.registrations == 0)
    }

    // A main-actor owner's confined stream is read by a task that is already cancelled. The read ends the
    // stream, which removes the registration before it releases the unread projection, so the
    // projection's destructor registers again with the owner's only slot.
    @MainActor @Test func aCancelledReadOfAMainActorStreamReleasesItsUnreadElementOnceTheSlotIsFree() async throws {
        let host = RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>(
            0,
            scopes: [],
            configuration: try ManagedConfiguration(subscribers: 1),
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let reader = Task { @MainActor () -> (ended: Bool, outcome: Outcome) in
            var outcome = Outcome.none
            var snapshots = try host.snapshots { _ in
                let projection = Confined()
                projection.onRelease = {
                    do {
                        var again = try host.snapshots()
                        again.cancel()
                        outcome = .registered
                    } catch {
                        outcome = .refused
                    }
                }
                return projection
            }
            withUnsafeCurrentTask { $0?.cancel() }
            let ended = await snapshots.next() == nil
            return (ended, outcome)
        }
        let (ended, outcome) = try await reader.value
        #expect(ended)
        #expect(outcome == .registered)
        #expect(host.subscriberCount == 0)
    }

    // The same, for an owner confined to another actor, whose stream is read on that actor.
    @Test func aCancelledReadOfAnIsolatedStreamReleasesItsUnreadElementOnceTheSlotIsFree() async throws {
        let bench = ReadBench()
        let (ended, outcome) = try await bench.readUnreadInACancelledTask()
        #expect(ended)
        #expect(outcome == .registered)
    }
}

/// An actor that owns a one-slot confined host and reads its stream in a cancelled task.
private actor ReadBench {
    private typealias Host = RuntimeIsolatedHost<ReadBench, Int, Int, RuntimeTicket, Never>
    private var host: Host?

    func readUnreadInACancelledTask() async throws -> (Bool, Outcome) {
        let host = Host(
            0,
            scopes: [],
            isolation: self,
            configuration: try ManagedConfiguration(subscribers: 1),
            driver: { _, work in work.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        self.host = host
        let outcome = OutcomeRecord()
        var snapshots = try host.snapshots(
            { _ in
                let projection = Confined()
                projection.onRelease = {
                    do {
                        var again = try host.snapshots(isolation: self)
                        again.cancel()
                        outcome.record(.registered)
                    } catch {
                        outcome.record(.refused)
                    }
                }
                return projection
            },
            isolation: self
        )
        withUnsafeCurrentTask { $0?.cancel() }
        let ended = await snapshots.next() == nil
        return (ended, outcome.result)
    }
}
