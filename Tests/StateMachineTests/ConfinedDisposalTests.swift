import Dispatch
import Foundation
import StateMachine
import StateMachineTestSupport
import Testing
import os

// A confined stream carries values that are not `Sendable`, so the value it still holds unread is
// released on the actor that owns the stream, whichever thread drops the stream's last reference.
// Each test drops a stream on another thread while the owning actor is held, then awaits the release.

private typealias MainHost = RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>
private typealias ConfinedHost = RuntimeIsolatedHost<MainActor, Int, Int, RuntimeTicket, Never>

@MainActor private func makeMainHost() throws -> MainHost {
    MainHost(
        0,
        scopes: [],
        configuration: try ManagedConfiguration(subscribers: 1),
        driver: { $0.ticket },
        ticket: { $0 },
        prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
    )
}

@MainActor private func makeConfinedHost() throws -> ConfinedHost {
    ConfinedHost(
        0,
        scopes: [],
        isolation: MainActor.shared,
        configuration: try ManagedConfiguration(subscribers: 1),
        driver: { _, work in work.ticket },
        ticket: { $0 },
        prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
    )
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

/// Where and how often the probes it watches were released.
private final class Releases: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (count: 0, offMain: 0))
    private let signal = Signal()

    var count: Int { state.withLock { $0.count } }
    var offMain: Int { state.withLock { $0.offMain } }
    func record() {
        let onMain = Thread.isMainThread
        state.withLock {
            $0.count += 1
            if !onMain { $0.offMain += 1 }
        }
        signal.raise()
    }
    func wait() async { await signal.wait() }
}

/// A projection that is not `Sendable`, whose release a test observes.
private final class Probe {
    private let releases: Releases?
    init(_ releases: Releases?) { self.releases = releases }
    deinit { releases?.record() }
}

/// Raises its signal when the callbacks that capture it are released.
private final class Detach: Sendable {
    private let signal: Signal
    init(_ signal: Signal) { self.signal = signal }
    deinit { signal.raise() }
}

private typealias ProbeHost = RuntimeMainActorHost<Probe, Int, RuntimeTicket, Never>

/// A projection that references the host it came from.
private final class BackReference {
    let host: ConfinedHost?
    init(_ host: ConfinedHost?) { self.host = host }
}

/// A main-actor object that keeps a stream of projections that reference their host.
@MainActor private final class BackReferenceKeeper {
    var stream: IsolatedSnapshotSequence<BackReference>
    init(_ stream: consuming IsolatedSnapshotSequence<BackReference>) { self.stream = stream }
}

/// A main-actor object that keeps a host confined to the main actor, as a view model stores one.
@MainActor private final class ConfinedHostKeeper {
    let host: ConfinedHost
    init(_ host: ConfinedHost) { self.host = host }
}

/// A value that is not `Sendable`, held by a main-actor object that is.
@MainActor private final class MainActorBox<Value> {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A main-actor object that keeps a confined stream, as a view model stores one.
@MainActor private final class MainStreamKeeper {
    var stream: MainActorSnapshotSequence<Probe>
    init(_ stream: consuming MainActorSnapshotSequence<Probe>) { self.stream = stream }
}

/// A main-actor object that keeps a stream confined to the main actor through an isolated host.
@MainActor private final class IsolatedStreamKeeper {
    var stream: IsolatedSnapshotSequence<Probe>
    init(_ stream: consuming IsolatedSnapshotSequence<Probe>) { self.stream = stream }
}

/// Hands one reference to another thread, which drops it while the main actor waits.
private func drop<Kept: Sendable>(_ kept: consuming Kept, after: @escaping @Sendable () -> Void = {}) {
    let slot = OSAllocatedUnfairLock<Kept?>(initialState: kept)
    let dropped = DispatchSemaphore(value: 0)
    runOnOwnThread {
        slot.withLock { $0 = nil }
        after()
        dropped.signal()
    }
    dropped.wait()
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct ConfinedDisposalTests {
    // The owner closes, so the stream's final projection waits unread and the owner releases the
    // callbacks. The keeper that holds the stream is released on another thread while the main actor
    // waits; the projection is released on the main actor afterward.
    @Test func droppingAFinishedMainActorStreamElsewhereReleasesItsUnreadElementOnTheMainActor() async throws {
        let host = try makeMainHost()
        let releases = Releases()
        let detached = Signal()
        let stream = try host.snapshots({ Probe($0.isClosed ? releases : nil) }, onDetach: { detached.raise() })
        _ = host.close()
        await detached.wait()
        #expect(host.subscriberCount == 0)
        let releasedWhileDropping = OSAllocatedUnfairLock(initialState: -1)
        drop(MainStreamKeeper(stream)) { releasedWhileDropping.withLock { $0 = releases.count } }
        #expect(releasedWhileDropping.withLock { $0 } == 0)
        await releases.wait()
        #expect(releases.count == 1)
        #expect(releases.offMain == 0)
    }

    // A stream dropped unread before the owner finished stops delivery and frees its slot at once, and
    // releases its unread projection on the main actor once the registration is removed there.
    @Test func droppingAnOpenMainActorStreamElsewhereFreesItsSlotAndReleasesOnTheMainActor() async throws {
        let host = try makeMainHost()
        let releases = Releases()
        let stream = try host.snapshots { _ in Probe(releases) }
        drop(MainStreamKeeper(stream))
        #expect(releases.count == 0)
        #expect(host.subscriberCount == 0)
        await releases.wait()
        #expect(releases.offMain == 0)
        var replacement = try host.snapshots { _ in Probe(nil) }
        replacement.cancel()
    }

    // A host confined to the main actor as its owning actor closes and releases the stream's
    // callbacks, so the stream holds its final projection alone. Dropping the stream on the owning
    // actor releases the projection there at once; the host keeps nothing of it, so releasing the host
    // on another thread afterward releases nothing more.
    @Test func droppingAFinishedIsolatedStreamOnTheOwningActorReleasesItsUnreadElementThere() async throws {
        var host: ConfinedHost? = try makeConfinedHost()
        let releases = Releases()
        let detached = Signal()
        var keeper: IsolatedStreamKeeper? = IsolatedStreamKeeper(
            try #require(host)
                .snapshots(
                    { [marker = Detach(detached)] snapshot in
                        withExtendedLifetime(marker) { Probe(snapshot.isClosed ? releases : nil) }
                    },
                    isolation: MainActor.shared
                )
        )
        _ = host?.close(isolation: MainActor.shared)
        await detached.wait()
        #expect(host?.subscriberCount(isolation: MainActor.shared) == 0)
        keeper = nil
        #expect(releases.count == 1)
        #expect(releases.offMain == 0)
        guard let held = host.take() else { return }
        drop(ConfinedHostKeeper(consume held))
        #expect(releases.count == 1)
        withExtendedLifetime(keeper) {}
    }

    // Once the host has finished the registration, the stream holds its unread projection alone, so a
    // stream dropped on another thread releases it there: nothing on the owning actor holds it any
    // more, and no destructor can reach a generic actor at the deployment floor.
    @Test func aFinishedIsolatedStreamDroppedElsewhereReleasesItsUnreadElementWhereItIsDropped() async throws {
        let host = try makeConfinedHost()
        let releases = Releases()
        let detached = Signal()
        let stream = try host.snapshots(
            { [marker = Detach(detached)] snapshot in
                withExtendedLifetime(marker) { Probe(snapshot.isClosed ? releases : nil) }
            },
            isolation: MainActor.shared
        )
        _ = host.close(isolation: MainActor.shared)
        await detached.wait()
        let releasedWhileDropping = OSAllocatedUnfairLock(initialState: -1)
        drop(IsolatedStreamKeeper(stream)) { releasedWhileDropping.withLock { $0 = releases.count } }
        #expect(releasedWhileDropping.withLock { $0 } == 1)
        #expect(releases.offMain == 1)
    }

    // A projection that references its host does not keep the host alive once the host has finished
    // the registration and the stream is dropped: nothing else holds the projection.
    @Test func aProjectionThatReferencesItsHostDoesNotKeepAFinishedHostAlive() async throws {
        var host: ConfinedHost? = try makeConfinedHost()
        let detached = Signal()
        var keeper: BackReferenceKeeper? = BackReferenceKeeper(
            try #require(host)
                .snapshots(
                    { [weak host, marker = Detach(detached)] _ in withExtendedLifetime(marker) { BackReference(host) }
                    },
                    isolation: MainActor.shared
                )
        )
        _ = host?.close(isolation: MainActor.shared)
        await detached.wait()
        keeper = nil
        weak let released = host
        host = nil
        #expect(released == nil)
        withExtendedLifetime(keeper) {}
    }

    // An isolated stream dropped unread elsewhere frees its slot at once; the host's next sweep, on the
    // owning actor, releases its callbacks and its unread projection.
    @Test func droppingAnOpenIsolatedStreamElsewhereFreesItsSlotAndReleasesOnTheOwningActor() throws {
        let host = try makeConfinedHost()
        let releases = Releases()
        let stream = try host.snapshots({ _ in Probe(releases) }, isolation: MainActor.shared)
        drop(IsolatedStreamKeeper(stream))
        #expect(releases.count == 0)
        #expect(host.subscriberCount(isolation: MainActor.shared) == 0)
        var replacement = try host.snapshots({ _ in Probe(nil) }, isolation: MainActor.shared)
        #expect(releases.count == 1)
        #expect(releases.offMain == 0)
        replacement.cancel()
    }

    // A stream dropped unread on the main actor itself frees its slot before the drop returns, and its
    // projection is released on a later turn, once the registration is removed.
    @Test func droppingAMainActorStreamOnTheMainActorFreesItsSlotAtOnce() async throws {
        let host = try makeMainHost()
        let releases = Releases()
        var keeper: MainStreamKeeper? = MainStreamKeeper(try host.snapshots { _ in Probe(releases) })
        keeper = nil
        #expect(host.subscriberCount == 0)
        #expect(releases.count == 0)
        await releases.wait()
        #expect(releases.offMain == 0)
        var replacement = try host.snapshots { _ in Probe(nil) }
        replacement.cancel()
        withExtendedLifetime(keeper) {}
    }

    // The owner closes and is released before the stream, which then holds its mailbox alone. Dropping
    // the stream on another thread still releases the final projection on the main actor.
    @Test func aMainActorStreamThatOutlivesItsOwnerReleasesItsUnreadElementOnTheMainActor() async throws {
        var host: MainHost? = try makeMainHost()
        let releases = Releases()
        let detached = Signal()
        let stream = try host?.snapshots({ Probe($0.isClosed ? releases : nil) }, onDetach: { detached.raise() })
        _ = host?.close()
        await detached.wait()
        host = nil
        let releasedWhileDropping = OSAllocatedUnfairLock(initialState: -1)
        drop(MainStreamKeeper(stream!)) { releasedWhileDropping.withLock { $0 = releases.count } }
        #expect(releasedWhileDropping.withLock { $0 } == 0)
        await releases.wait()
        #expect(releases.offMain == 0)
    }

    // An isolated stream dropped on the owning actor leaves its unread projection with the host, which
    // releases it in its next sweep there.
    @Test func droppingAnIsolatedStreamOnTheOwningActorReleasesItsElementInTheNextSweep() throws {
        let host = try makeConfinedHost()
        let releases = Releases()
        var keeper: IsolatedStreamKeeper? = IsolatedStreamKeeper(
            try host.snapshots({ _ in Probe(releases) }, isolation: MainActor.shared)
        )
        keeper = nil
        #expect(host.subscriberCount(isolation: MainActor.shared) == 0)
        #expect(releases.count == 0)
        _ = host.snapshot(isolation: MainActor.shared)
        #expect(releases.count == 1)
        withExtendedLifetime(keeper) {}
    }

    // A confined stream of the retained completions follows the same path: once the host has closed
    // and released its callbacks, dropping the stream on the owning actor releases the final, empty
    // collection's projection there at once.
    @Test func droppingAFinishedIsolatedCompletionStreamOnTheOwningActorReleasesItThere() async throws {
        let host = try makeConfinedHost()
        let releases = Releases()
        let detached = Signal()
        var keeper: IsolatedStreamKeeper? = IsolatedStreamKeeper(
            try host.pendingCompletionUpdates(
                { [marker = Detach(detached)] pending in
                    withExtendedLifetime(marker) { Probe(pending.isEmpty ? releases : nil) }
                },
                isolation: MainActor.shared
            )
        )
        _ = host.close(isolation: MainActor.shared)
        await detached.wait()
        let before = releases.count
        keeper = nil
        #expect(releases.count == before + 1)
        #expect(releases.offMain == 0)
        withExtendedLifetime(keeper) {}
    }

    // A main-actor host released on another thread releases nothing it holds there: its root model,
    // the callbacks of an open stream, and the values a projection closure captures are released on a
    // later main-actor turn, which also ends the stream.
    @Test func aMainActorHostReleasedElsewhereReleasesItsConfinedStateOnTheMainActor() async throws {
        let releases = Releases()
        var host: ProbeHost? = ProbeHost(
            Probe(releases),
            scopes: [],
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        var stream = try #require(host)
            .snapshots { [captured = Probe(releases)] _ in
                withExtendedLifetime(captured) { 0 }
            }
        _ = await stream.next()
        guard let held = host.take() else { return }
        drop(consume held)
        #expect(releases.count == 0)
        #expect(await stream.next() == nil)
        await releases.wait()
        await releases.wait()
        #expect(releases.count == 2)
        #expect(releases.offMain == 0)
    }

    // The schedule the destructor must survive: the main-actor job that empties the host's confined
    // storage runs, and returns, before the releasing thread destroys the host's stored properties.
    // The storage holds the model and the callbacks alone, so they are still released on the main
    // actor.
    @Test func aMainActorHostWhoseDisposalRunsFirstReleasesItsConfinedStateOnTheMainActor() async throws {
        let releases = Releases()
        var host: ProbeHost? = ProbeHost(
            Probe(releases),
            scopes: [],
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        var stream = try #require(host)
            .snapshots { [captured = Probe(releases)] _ in
                withExtendedLifetime(captured) { 0 }
            }
        _ = await stream.next()
        guard let held = host.take() else { return }
        await dropAfterItsJob(consume held)
        #expect(await stream.next() == nil)
        while releases.count < 2 { await releases.wait() }
        #expect(releases.offMain == 0)
    }

    // A main-actor token of your own released on another thread runs its action on a later main-actor
    // turn, which then releases the action and everything it captures there.
    @Test func aMainActorTokenReleasedElsewhereReleasesItsActionOnTheMainActor() async throws {
        let releases = Releases()
        let ran = Signal()
        drop(
            MainActorSnapshotSubscription { [probe = MainActorBox(Probe(releases))] in
                withExtendedLifetime(probe) { ran.raise() }
            }
        )
        await ran.wait()
        await releases.wait()
        #expect(releases.offMain == 0)
    }

    // A stream that ends on the owning actor, by reading its end or by cancelling, has its mailbox
    // released by the host at once, so nothing it held outlives it.
    @Test func endingAnIsolatedStreamOnTheOwningActorReleasesWhatTheHostKept() async throws {
        let host = try makeConfinedHost()
        let releases = Releases()
        var stream = try host.snapshots(
            { snapshot in Probe(snapshot.isClosed ? releases : nil) },
            isolation: MainActor.shared
        )
        _ = host.close(isolation: MainActor.shared)
        var read = 0
        while await stream.next() != nil { read += 1 }
        #expect(read > 0)
        #expect(releases.count == 1)
        #expect(releases.offMain == 0)
        stream.cancel()
    }
}
