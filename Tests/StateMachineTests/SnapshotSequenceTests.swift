import StateMachine
import Testing

private typealias Engine = RuntimeState<Int, Int>
private typealias MainHost = RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>
private typealias ActorHost = RuntimeActorHost<Int, Int, RuntimeTicket, Never>
private typealias SharedHost = RuntimeSharedHost<Int, Int, RuntimeTicket, Never>

private final class Box {
    var value: Int
    init(_ value: Int) { self.value = value }
}

@MainActor private func makeMainHost(subscribers: Int = 128) throws -> MainHost {
    MainHost(
        0,
        scopes: [],
        configuration: try RuntimeManagedConfiguration(subscribers: subscribers),
        driver: { $0.ticket },
        ticket: { $0 },
        prepare: { _ in .failure(.plan(.invalidPlan)) }
    )
}

private func makeActorHost(subscribers: Int = 128) throws -> ActorHost {
    ActorHost(
        0,
        scopes: [],
        configuration: try RuntimeManagedConfiguration(subscribers: subscribers),
        driver: { $0.ticket },
        ticket: { $0 },
        prepare: { _ in .failure(.plan(.invalidPlan)) }
    )
}

private func makeSharedHost(subscribers: Int = 128) throws -> SharedHost {
    SharedHost(
        manual: 0,
        scopes: [],
        limits: try RuntimeLimits(),
        subscriberCapacity: subscribers,
        ticket: { $0 },
        prepare: { _ in .failure(.plan(.invalidPlan)) }
    )
}

extension RuntimeMainActorHost where Model == Int, Descriptor == Int {
    fileprivate func advance() throws { _ = commit(try Engine.prepare(on: snapshot(), next: snapshot().model + 1)) }
}

extension RuntimeActorHost where Model == Int, Descriptor == Int {
    fileprivate func advance() throws { _ = commit(try Engine.prepare(on: snapshot(), next: snapshot().model + 1)) }
}

extension RuntimeSharedHost where Model == Int, Descriptor == Int {
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

@MainActor @Suite(.timeLimit(.minutes(1))) struct MainActorSnapshotSequenceTests {
    @Test func deliversInitialAcceptedAndTerminalSnapshotsThenEnds() async throws {
        let owner = try makeMainHost()
        var iterator = try owner.snapshots().makeAsyncIterator()
        #expect(await iterator.next()?.revision == 0)
        try owner.advance()
        #expect(await iterator.next()?.revision == 1)
        let closed = owner.close()
        let final = await iterator.next()
        #expect(final?.revision == closed.revision && final?.isClosed == true)
        #expect(await iterator.next() == nil)
        #expect(await iterator.next() == nil)
        #expect(owner.subscriberCount == 0)
        await owner.shutdown()
    }

    @Test func closedOwnerYieldsItsFinalSnapshotThenEnds() async throws {
        let owner = try makeMainHost(subscribers: 1)
        let closed = owner.close()
        #expect(await owner.flush(through: closed))
        var revisions: [UInt64] = []
        for await snapshot in try owner.snapshots() { revisions.append(snapshot.revision) }
        #expect(revisions == [closed.revision])
        #expect(owner.subscriberCount == 0)
        await owner.shutdown()
    }

    @Test func unreadSnapshotsCoalesceToTheFinalSnapshot() async throws {
        let owner = try makeMainHost()
        let snapshots = try owner.snapshots()
        try owner.advance()
        try owner.advance()
        let closed = owner.close()
        // Completion edge: the owner has delivered every batch through the close.
        #expect(await owner.flush(through: closed))
        var observed: [Engine.Snapshot] = []
        for await snapshot in snapshots { observed.append(snapshot) }
        #expect(observed.map(\.revision) == [closed.revision])
        #expect(observed.last?.isClosed == true)
        await owner.shutdown()
    }

    @Test func sendingFromInsideTheLoopObservesEveryRevisionInOrder() async throws {
        let owner = try makeMainHost()
        var revisions: [UInt64] = []
        for await snapshot in try owner.snapshots() {
            revisions.append(snapshot.revision)
            if snapshot.revision < 2 { try owner.advance() } else if !snapshot.isClosed { _ = owner.close() }
        }
        #expect(revisions == [0, 1, 2, 3])
        await owner.shutdown()
    }

    @Test func cancellingTheConsumerEndsTheSequenceAndFreesItsSlot() async throws {
        let owner = try makeMainHost(subscribers: 1)
        let snapshots = try owner.snapshots()
        let received = Signal()
        let consumer = Task {
            var revisions: [UInt64] = []
            for await snapshot in snapshots {
                revisions.append(snapshot.revision)
                received.raise()
            }
            return revisions
        }
        await received.wait()
        consumer.cancel()
        #expect(await consumer.value == [0])
        // The consumer removed its registration on the main actor before returning.
        #expect(owner.subscriberCount == 0)
        _ = try owner.snapshots()
        await owner.shutdown()
    }

    @Test func releasingTheSequenceFreesItsSlot() async throws {
        let owner = try makeMainHost(subscribers: 1)
        let detached = Signal()
        do {
            let snapshots = try owner.snapshots({ $0 }, onDetach: { detached.raise() })
            #expect(throws: RuntimeHostSubscriptionFailure.capacityExceeded) { try owner.snapshots() }
            _ = snapshots
        }
        // Cleanup edge: the owner has released this sequence's callbacks.
        await detached.wait()
        #expect(owner.subscriberCount == 0)
        await owner.shutdown()
    }

    @Test func releasingAnUnclosedOwnerEndsASuspendedConsumer() async throws {
        var owner: MainHost? = try makeMainHost()
        weak let released = owner
        let snapshots = try #require(owner).snapshots()
        let received = Signal()
        let consumer = Task {
            var observed: [Engine.Snapshot] = []
            for await snapshot in snapshots {
                observed.append(snapshot)
                received.raise()
            }
            return observed.map(\.isClosed)
        }
        await received.wait()
        owner = nil
        #expect(released == nil)
        #expect(await consumer.value == [false])
    }

    @Test func onlyTheFirstIteratorReceivesElements() async throws {
        let owner = try makeMainHost()
        let snapshots = try owner.snapshots()
        var first = snapshots.makeAsyncIterator()
        var second = snapshots.makeAsyncIterator()
        #expect(await second.next() == nil)
        #expect(await first.next()?.revision == 0)
        await owner.shutdown()
    }

    @Test func carriesSnapshotsThatAreNotSendable() async throws {
        let owner = RuntimeMainActorHost<Box, Int, RuntimeTicket, Never>(
            Box(1),
            scopes: [],
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.plan(.invalidPlan)) }
        )
        let shared = Box(2)
        var values: [Int] = []
        for await snapshot in try owner.snapshots() {
            values.append(snapshot.model.value)
            if snapshot.revision == 0 {
                _ = owner.commit(try RuntimeState<Box, Int>.prepare(on: owner.snapshot(), next: shared))
            } else if !snapshot.isClosed {
                shared.value = 3
                _ = owner.close()
            }
        }
        #expect(values == [1, 2, 3])
        await owner.shutdown()
    }
}

@Suite(.timeLimit(.minutes(1))) struct ActorSnapshotSequenceTests {
    @Test func deliversInitialAcceptedAndTerminalSnapshotsThenEnds() async throws {
        let owner = try makeActorHost()
        var iterator = try await owner.snapshots().makeAsyncIterator()
        #expect(await iterator.next()?.revision == 0)
        try await owner.advance()
        #expect(await iterator.next()?.revision == 1)
        let closed = await owner.close()
        let final = await iterator.next()
        #expect(final?.revision == closed.revision && final?.isClosed == true)
        #expect(await iterator.next() == nil)
        await owner.shutdown()
    }

    @Test func closedOwnerYieldsItsFinalSnapshotThenEnds() async throws {
        let owner = try makeActorHost(subscribers: 1)
        let closed = await owner.close()
        #expect(await owner.flush(through: closed))
        var revisions: [UInt64] = []
        for await snapshot in try await owner.snapshots() { revisions.append(snapshot.revision) }
        #expect(revisions == [closed.revision])
        #expect(await owner.subscriberCount == 0)
        await owner.shutdown()
    }

    @Test func unreadSnapshotsCoalesceToTheFinalSnapshot() async throws {
        let owner = try makeActorHost()
        let snapshots = try await owner.snapshots()
        try await owner.advance()
        try await owner.advance()
        let closed = await owner.close()
        // Completion edge: the owner has delivered every batch through the close.
        #expect(await owner.flush(through: closed))
        var observed: [Engine.Snapshot] = []
        for await snapshot in snapshots { observed.append(snapshot) }
        #expect(observed.map(\.revision) == [closed.revision])
        #expect(observed.last?.isClosed == true)
        await owner.shutdown()
    }

    @Test func sendingFromInsideTheLoopObservesEveryRevisionInOrder() async throws {
        let owner = try makeActorHost()
        var revisions: [UInt64] = []
        for await snapshot in try await owner.snapshots() {
            revisions.append(snapshot.revision)
            if snapshot.revision < 2 {
                try await owner.advance()
            } else if !snapshot.isClosed {
                _ = await owner.close()
            }
        }
        #expect(revisions == [0, 1, 2, 3])
        await owner.shutdown()
    }

    @Test func cancellingTheConsumerEndsTheSequenceAndFreesItsSlot() async throws {
        let owner = try makeActorHost(subscribers: 1)
        let detached = Signal()
        let snapshots = try await owner.snapshots({ $0 }, onDetach: { detached.raise() })
        let received = Signal()
        let consumer = Task {
            var revisions: [UInt64] = []
            for await snapshot in snapshots {
                revisions.append(snapshot.revision)
                received.raise()
            }
            return revisions
        }
        await received.wait()
        consumer.cancel()
        #expect(await consumer.value == [0])
        // Cleanup edge: this owner removes a registration on a later actor turn.
        await detached.wait()
        #expect(await owner.subscriberCount == 0)
        await owner.shutdown()
    }

    @Test func releasingTheSequenceFreesItsSlot() async throws {
        let owner = try makeActorHost(subscribers: 1)
        let detached = Signal()
        do {
            let snapshots = try await owner.snapshots({ $0 }, onDetach: { detached.raise() })
            await #expect(throws: RuntimeHostSubscriptionFailure.capacityExceeded) { try await owner.snapshots() }
            _ = snapshots
        }
        await detached.wait()
        #expect(await owner.subscriberCount == 0)
        await owner.shutdown()
    }

    @Test func releasingAnUnclosedOwnerEndsASuspendedConsumer() async throws {
        var owner: ActorHost? = try makeActorHost()
        weak let released = owner
        let snapshots = try await #require(owner).snapshots()
        let received = Signal()
        let consumer = Task {
            var observed: [Engine.Snapshot] = []
            for await snapshot in snapshots {
                observed.append(snapshot)
                received.raise()
            }
            return observed.map(\.isClosed)
        }
        await received.wait()
        owner = nil
        #expect(released == nil)
        #expect(await consumer.value == [false])
    }

    @Test func onlyTheFirstIteratorReceivesElements() async throws {
        let owner = try makeActorHost()
        let snapshots = try await owner.snapshots()
        var first = snapshots.makeAsyncIterator()
        var second = snapshots.makeAsyncIterator()
        #expect(await second.next() == nil)
        #expect(await first.next()?.revision == 0)
        await owner.shutdown()
    }
}

@Suite(.timeLimit(.minutes(1))) struct SharedSnapshotSequenceTests {
    @Test func deliversInitialAcceptedAndTerminalSnapshotsThenEnds() async throws {
        let owner = try makeSharedHost()
        var iterator = try owner.snapshots().makeAsyncIterator()
        #expect(await iterator.next()?.revision == 0)
        try owner.advance()
        #expect(await iterator.next()?.revision == 1)
        let closed = owner.close()
        let final = await iterator.next()
        #expect(final?.revision == closed.revision && final?.isClosed == true)
        #expect(await iterator.next() == nil)
    }

    @Test func closedOwnerYieldsItsFinalSnapshotThenEnds() async throws {
        let owner = try makeSharedHost(subscribers: 1)
        let closed = owner.close()
        var revisions: [UInt64] = []
        for await snapshot in try owner.snapshots() { revisions.append(snapshot.revision) }
        #expect(revisions == [closed.revision])
        // A closed owner creates no live registration.
        _ = try owner.snapshots()
    }

    @Test func unreadSnapshotsNeverRegressAndEndWithTheFinalSnapshot() async throws {
        let owner = try makeSharedHost()
        let snapshots = try owner.snapshots()
        for _ in 0 ..< 64 { try owner.advance() }
        let closed = owner.close()
        var observed: [Engine.Snapshot] = []
        for await snapshot in snapshots { observed.append(snapshot) }
        let revisions = observed.map(\.revision)
        #expect(zip(revisions, revisions.dropFirst()).allSatisfy { $0 < $1 })
        #expect(observed.last?.revision == closed.revision && observed.last?.isClosed == true)
        #expect(observed.dropLast().allSatisfy { !$0.isClosed })
    }

    @Test func sendingFromInsideTheLoopObservesEveryRevisionInOrder() async throws {
        let owner = try makeSharedHost()
        var revisions: [UInt64] = []
        for await snapshot in try owner.snapshots() {
            revisions.append(snapshot.revision)
            if snapshot.revision < 2 { try owner.advance() } else if !snapshot.isClosed { _ = owner.close() }
        }
        #expect(revisions == [0, 1, 2, 3])
    }

    @Test func cancellingTheConsumerEndsTheSequenceAndFreesItsSlot() async throws {
        let owner = try makeSharedHost(subscribers: 1)
        let snapshots = try owner.snapshots()
        let received = Signal()
        let consumer = Task {
            var revisions: [UInt64] = []
            for await snapshot in snapshots {
                revisions.append(snapshot.revision)
                received.raise()
            }
            return revisions
        }
        await received.wait()
        consumer.cancel()
        #expect(await consumer.value == [0])
        // The consumer removed its registration before returning.
        _ = try owner.snapshots()
    }

    @Test func releasingTheSequenceFreesItsSlot() throws {
        let owner = try makeSharedHost(subscribers: 1)
        do {
            let snapshots = try owner.snapshots()
            #expect(throws: RuntimeHostSubscriptionFailure.capacityExceeded) { try owner.snapshots() }
            _ = snapshots
        }
        _ = try owner.snapshots()
    }

    @Test func releasingAnUnclosedOwnerEndsASuspendedConsumer() async throws {
        var owner: SharedHost? = try makeSharedHost()
        let snapshots = try #require(owner).snapshots()
        let received = Signal()
        let consumer = Task {
            var observed: [Engine.Snapshot] = []
            for await snapshot in snapshots {
                observed.append(snapshot)
                received.raise()
            }
            return observed.map(\.isClosed)
        }
        await received.wait()
        owner = nil
        #expect(await consumer.value == [false])
    }

    @Test func onlyTheFirstIteratorReceivesElements() async throws {
        let owner = try makeSharedHost()
        let snapshots = try owner.snapshots()
        var first = snapshots.makeAsyncIterator()
        var second = snapshots.makeAsyncIterator()
        #expect(await second.next() == nil)
        #expect(await first.next()?.revision == 0)
    }
}
