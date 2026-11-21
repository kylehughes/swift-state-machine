import Dispatch
import StateMachine
import StateMachineExamples
import Testing
import os

// A sequence observes task cancellation only while a read waits. A consumer that keeps a sequence
// after leaving its loop, by `break`, `first(where:)`, or a cancelled task, ends it with `cancel()`.

private typealias Engine = RuntimeState<Int, Int>
private typealias MainHost = RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>
private typealias SharedHost = RuntimeSharedHost<Int, Int, RuntimeTicket, Never>

@MainActor private func makeMainHost(subscribers: Int = 128) throws -> MainHost {
    MainHost(
        0,
        scopes: [],
        configuration: try ManagedConfiguration(subscribers: subscribers),
        driver: { $0.ticket },
        ticket: { $0 },
        prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
    )
}

private func makeSharedHost(subscribers: Int = 128) throws -> SharedHost {
    SharedHost(
        manual: 0,
        scopes: [],
        limits: try Limits(),
        subscriberCapacity: subscribers,
        ticket: { $0 },
        prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
    )
}

extension RuntimeMainActorHost where Model == Int, Descriptor == Int {
    fileprivate func advance() throws { _ = commit(try Engine.prepare(on: snapshot(), next: snapshot().model + 1)) }
}

/// A one-shot event a test awaits instead of inferring progress from scheduling.
private struct Signal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
    func raise() { continuation.yield(()) }
    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

@Suite(.timeLimit(.minutes(1))) struct SnapshotSequenceCancellationTests {
    // The task reads one element and is cancelled before its next read. Nothing observes that
    // cancellation, so the registration stays until the sequence is cancelled.
    @Test func aTaskCancelledBetweenReadsKeepsTheRegistrationUntilTheSequenceIsCancelled() async throws {
        let host = try makeSharedHost(subscribers: 1)
        let snapshots = try host.snapshots()
        let read = Signal()
        let resume = Signal()
        let consumer = Task {
            var iterator = snapshots.makeAsyncIterator()
            _ = await iterator.next()
            read.raise()
            await resume.wait()
        }
        await read.wait()
        consumer.cancel()
        resume.raise()
        await consumer.value
        #expect(host.subscriberCount == 1)
        snapshots.cancel()
        #expect(host.subscriberCount == 0)
        try host.snapshots().cancel()
    }

    // `defer` releases the slot once `first(where:)` returns.
    @Test func aDeferredCancelReleasesTheSlotAfterFirstWhere() async throws {
        let host = try makeSharedHost(subscribers: 1)
        func firstOpenRevision() async throws -> UInt64? {
            let snapshots = try host.snapshots()
            defer { snapshots.cancel() }
            return await snapshots.first { !$0.isClosed }?.revision
        }
        #expect(try await firstOpenRevision() == 0)
        #expect(host.subscriberCount == 0)
        #expect(try await firstOpenRevision() == 0)
    }

    // Cancelling from another task resumes a read that is waiting with the end.
    @Test func cancellingFromAnotherTaskEndsAWaitingRead() async throws {
        let host = try makeSharedHost()
        let snapshots = try host.snapshots()
        let first = Signal()
        let consumer = Task { () -> [UInt64] in
            var revisions: [UInt64] = []
            for await snapshot in snapshots {
                revisions.append(snapshot.revision)
                first.raise()
            }
            return revisions
        }
        await first.wait()
        snapshots.cancel()
        #expect(await consumer.value == [0])
        #expect(host.subscriberCount == 0)
    }

    // A cancelled sequence reads nothing, even an element it had not read, and cancelling again
    // changes nothing.
    @Test func aCancelledSequenceReadsNothingAndCancellingAgainChangesNothing() async throws {
        let cancels = OSAllocatedUnfairLock(initialState: 0)
        let snapshots = try SnapshotSequence<Int> { receive, _ in
            receive(1)
            return SnapshotSubscription { cancels.withLock { $0 += 1 } }
        }
        snapshots.cancel()
        snapshots.cancel()
        var iterator = snapshots.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(cancels.withLock { $0 } == 1)
    }

    // A sequence of a main-actor owner, cancelled from another isolation domain, frees its slot at once.
    @MainActor @Test func cancellingAMainActorOwnersSequenceElsewhereFreesItsSlot() async throws {
        let host = try makeMainHost(subscribers: 1)
        let snapshots = try host.sendableSnapshots { $0.revision }
        await Task.detached { snapshots.cancel() }.value
        #expect(host.subscriberCount == 0)
        try host.sendableSnapshots { $0.revision }.cancel()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct MainActorStreamCancellationTests {
    // Cancelling a stored stream removes its registration before it returns; later reads end.
    @Test func cancellingRemovesTheRegistrationAndEndsLaterReads() async throws {
        let host = try makeMainHost(subscribers: 1)
        var snapshots = try host.snapshots()
        #expect(await snapshots.next()?.revision == 0)
        snapshots.cancel()
        #expect(host.subscriberCount == 0)
        try host.advance()
        #expect(await snapshots.next() == nil)
        snapshots.cancel()
        #expect(host.subscriberCount == 0)
    }
}

/// An actor that owns a confined note host and a stream it keeps between reads.
private actor NoteShelf {
    private var host: GeneratedNote.IsolatedHost<NoteShelf>!

    init() async throws {
        host = GeneratedNote.IsolatedHost(
            isolation: self,
            drivers: .init(save: { _, draft in GeneratedNote.Saved(text: draft.text) }),
            configuration: try .init(subscribers: 1)
        )
    }

    /// Reads one element, cancels the stream, and reports the subscriber count then and whether the
    /// next read ended.
    func cancelAfterFirstRead() async throws -> (count: Int, ended: Bool) {
        var snapshots = try host.snapshots()
        _ = await snapshots.next()
        snapshots.cancel()
        let count = host.subscriberCount()
        let ended = await snapshots.next() == nil
        snapshots.cancel()
        return (count, ended)
    }
}

@Suite(.timeLimit(.minutes(1))) struct IsolatedStreamCancellationTests {
    @Test func cancellingOnTheOwningActorRemovesTheRegistration() async throws {
        let shelf = try await NoteShelf()
        let (count, ended) = try await shelf.cancelAfterFirstRead()
        #expect(count == 0)
        #expect(ended)
    }
}

// MARK: The slot and the unread element after cancellation

/// A `MainActor` host of a test's own with one subscriber slot.
///
/// It frees the slot when the subscription it returned is cancelled. Its snapshot sequences are the
/// protocol's default projection.
@MainActor private final class OneSlotMainHost: MainActorStateMachineHost {
    typealias Inner = GeneratedTransfers.MainActorHost
    private let inner: Inner
    private(set) var registrations = 0

    init() throws {
        inner = GeneratedTransfers.MainActorHost(
            downloadDriver: { _, _ in .success("") },
            onLogged: { _ in },
            configuration: try GeneratedTransfers.Configuration(subscribers: 8)
        )
    }

    func snapshot() -> Inner.Snapshot { inner.snapshot() }
    func send(_ input: Inner.Input) throws(Inner.SendRejection) -> Inner.Receipt { try inner.send(input) }
    func commit(_ prepared: consuming Inner.Prepared) -> Inner.CommitResult { inner.commit(prepared) }
    func subscribe(
        _ receive: @escaping @MainActor (Inner.Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        guard registrations == 0 else { throw .capacityExceeded }
        let token = try inner.subscribe(receive, onFinish: onFinish)
        registrations += 1
        return MainActorSnapshotSubscription { [weak self] in
            self?.registrations -= 1
            token.cancel()
        }
    }
    func close() -> Inner.Receipt { inner.close() }
}

/// A reference whose release a test observes.
private final class Tracked: Sendable {}

/// Holds a weak reference to the last tracked value a projection made.
private final class LastTracked: Sendable {
    private let last = OSAllocatedUnfairLock<WeakTracked>(initialState: WeakTracked())
    private struct WeakTracked: Sendable { weak var value: Tracked? }
    func make() -> Tracked {
        let made = Tracked()
        last.withLock { $0.value = made }
        return made
    }
    var isAlive: Bool { last.withLock { $0.value != nil } }
}

/// The registration callbacks a test's own host keeps, as a host's registry would.
private final class Registry<Element: Sendable>: Sendable {
    private let callbacks = OSAllocatedUnfairLock<(@Sendable (Element) -> Void, @Sendable () -> Void)?>(
        initialState: nil
    )
    func keep(_ receive: @escaping @Sendable (Element) -> Void, _ finish: @escaping @Sendable () -> Void) {
        callbacks.withLock { $0 = (receive, finish) }
    }
    func offer(_ element: Element) { callbacks.withLock { $0 }?.0(element) }
    func finish() { callbacks.withLock { $0 }?.1() }
}

/// A one-shot event that a thread outside the cooperative pool raises and a test awaits.
private final class Raised: Sendable {
    private let signal = Signal()
    func raise() { signal.raise() }
    func wait() async { await signal.wait() }
}

@Suite(.timeLimit(.minutes(1))) struct CancellationCapacityTests {
    // A `MainActor` host of the test's own frees its slot when its subscription is cancelled.
    // Cancelling the default projection's sequence on the main actor cancels that subscription before
    // it returns, so a replacement registers in the same turn.
    @MainActor @Test func cancellingTheDefaultProjectionOnTheMainActorFreesTheSlotBeforeReturning() throws {
        let host = try OneSlotMainHost()
        let first = try host.snapshots { $0.revision }
        first.cancel()
        #expect(host.registrations == 0)
        let replacement = try host.snapshots { $0.revision }
        #expect(host.registrations == 1)
        replacement.cancel()
        #expect(host.registrations == 0)
    }

    // Another thread's cancellation of the same sequence queued the removal on the main actor; a
    // cancellation on the main actor carries it out before it returns.
    @MainActor @Test func aMainActorCancellationCompletesARemovalAnotherThreadQueued() throws {
        let host = try OneSlotMainHost()
        let snapshots = try host.snapshots { $0.revision }
        // The main actor waits while another thread cancels, so the removal that cancellation queues
        // on it has not run when the main actor cancels.
        let cancelled = DispatchSemaphore(value: 0)
        DispatchQueue.global()
            .async {
                snapshots.cancel()
                cancelled.signal()
            }
        cancelled.wait()
        #expect(host.registrations == 1)
        snapshots.cancel()
        #expect(host.registrations == 0)
        try host.snapshots { $0.revision }.cancel()
    }

    // The first cancellation is still inside the token's cancellation when a second one finds the
    // sequence released and returns. The registration's gate, which a managed owner's admission
    // reads, closed before the first recorded the release, so it is closed when the second returns.
    @Test func aCancellationThatFindsTheSequenceReleasedReturnsAfterItsGateClosed() async throws {
        let gate = RuntimeRegistrationGate()
        let registry = Registry<Int>()
        let entered = Raised()
        let proceed = DispatchSemaphore(value: 0)
        let finished = Raised()
        let snapshots = try SnapshotSequence<Int>({ $0 }) { receive, finish in
            registry.keep(receive, finish)
            return SnapshotSubscription(gate: gate) {
                entered.raise()
                proceed.wait()
            }
        }
        DispatchQueue.global()
            .async {
                snapshots.cancel()
                finished.raise()
            }
        await entered.wait()
        snapshots.cancel()
        #expect(!gate.isOpen)
        proceed.signal()
        await finished.wait()
    }

    // A shared owner's admission no longer counts a registration whose gate has closed, though its
    // token has not removed it yet.
    @Test func aSharedOwnerAdmitsAReplacementOnceTheGateOfItsOnlyRegistrationClosed() throws {
        let host = try makeSharedHost(subscribers: 1)
        let token = try host.subscribe { _ in }
        #expect(host.subscriberCount == 1)
        token.gate?.close()
        #expect(host.subscriberCount == 0)
        let replacement = try host.snapshots()
        #expect(host.subscriberCount == 1)
        replacement.cancel()
        token.cancel()
        #expect(host.subscriberCount == 0)
    }
}

@Suite(.timeLimit(.minutes(1))) struct CancellationRetentionTests {
    // An element the owner offered and no read took is released when the sequence is cancelled, even
    // while the sequence itself is kept.
    @Test func cancellingASequenceReleasesItsUnreadElement() throws {
        let registry = Registry<Tracked>()
        let tracked = LastTracked()
        let snapshots = try SnapshotSequence<Tracked> { receive, finish in
            registry.keep(receive, finish)
            return SnapshotSubscription(onCancel: {})
        }
        registry.offer(tracked.make())
        #expect(tracked.isAlive)
        snapshots.cancel()
        #expect(!tracked.isAlive)
        // A later offer is ignored.
        registry.offer(tracked.make())
        #expect(!tracked.isAlive)
        withExtendedLifetime(snapshots) {}
    }

    // A main-actor owner's confined stream releases the projection it holds unread when it is cancelled.
    @MainActor @Test func cancellingAMainActorStreamReleasesItsUnreadElement() throws {
        let host = try makeMainHost(subscribers: 1)
        let tracked = LastTracked()
        var snapshots = try host.snapshots { _ in tracked.make() }
        #expect(tracked.isAlive)
        snapshots.cancel()
        #expect(!tracked.isAlive)
        #expect(host.subscriberCount == 0)
    }

    // An owner confined to another actor: its stream releases the projection it holds unread when it
    // is cancelled there.
    @Test func cancellingAnIsolatedStreamReleasesItsUnreadElement() async throws {
        let bench = RetentionBench()
        #expect(try await bench.cancelUnread())
    }
}

/// An actor that owns a raw confined host and cancels a stream it has not read.
private actor RetentionBench {
    private typealias Host = RuntimeIsolatedHost<RetentionBench, Int, Int, RuntimeTicket, Never>
    private var host: Host?

    /// Returns whether the unread projection was released by the cancellation.
    func cancelUnread() throws -> Bool {
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
        let tracked = LastTracked()
        var snapshots = try host.snapshots({ _ in tracked.make() }, isolation: self)
        let heldBefore = tracked.isAlive
        snapshots.cancel()
        return heldBefore && !tracked.isAlive
    }
}
