import Combine
import Observation
import StateMachine
import Testing
import os

/// Events a test awaits in order, instead of inferring progress from scheduling.
private struct Events<Value: Sendable>: Sendable {
    private let stream: AsyncStream<Value>
    private let continuation: AsyncStream<Value>.Continuation

    init() { (stream, continuation) = AsyncStream<Value>.makeStream() }
    func record(_ value: Value) { continuation.yield(value) }
    func finish() { continuation.finish() }
    /// The next `count` recorded values, in order.
    func next(_ count: Int = 1) async -> [Value] {
        var values: [Value] = []
        for await value in stream {
            values.append(value)
            if values.count == count { break }
        }
        return values
    }
}

/// A counter whose `rename` input changes the snapshot without changing the count.
@StateMachine(mode: .shared)
nonisolated private enum Tally: Sendable {
    struct Counting: Sendable {
        var count = 0
        var label = ""
    }
    @Initial case counting(Counting = Counting())
    enum Input: Sendable {
        case increment
        case rename(String)
        case start
    }
    @Operation(activeIn: [Counting.self])
    enum Work { typealias Output = Int }
    @Transition(on: Input.increment)
    fileprivate static func increment(_ source: Counting) -> Counting {
        Counting(count: source.count + 1, label: source.label)
    }
    @Transition(on: Input.rename)
    fileprivate static func rename(_ source: Counting, _ label: String) -> Counting {
        Counting(count: source.count, label: label)
    }
    @Transition(on: Input.start, starts: [Work.self])
    fileprivate static func start(_ source: Counting) -> Change<Counting, Effect.Start> {
        Change(source, effects: [.work])
    }
    @Transition(onSuccess: Work.self)
    fileprivate static func worked(_ source: Counting, _ value: Work.Output) -> Counting {
        Counting(count: source.count + value, label: source.label)
    }
}

extension Tally.Snapshot {
    fileprivate var count: Int {
        switch self {
        case .counting(let counting): counting.value.count
        }
    }
}

/// Drivers that finish only when the test releases them.
private actor HeldWork {
    private var held: [CheckedContinuation<Int, Never>] = []
    let started = Events<Void>()

    func run() async -> Int {
        await withCheckedContinuation {
            held.append($0)
            started.record(())
        }
    }
    func release(_ value: Int) {
        let prior = held
        held = []
        for continuation in prior { continuation.resume(returning: value) }
    }
}

/// A lock-protected count of Observation change callbacks, which run synchronously.
private final class ChangeCount: Sendable {
    private let count = OSAllocatedUnfairLock(initialState: 0)
    var value: Int { count.withLock { $0 } }
    func raise() { count.withLock { $0 += 1 } }
}

/// The actor whose executor a shared-executor `ActorHost` runs on.
private actor Anchor {
    func mark() {}
}

/// The actor that owns a confined host in these tests.
private actor Owner {
    private(set) var host: Tally.IsolatedHost<Owner>!
    init() async { host = Tally.IsolatedHost(isolation: self, workDriver: { _ in 1 }) }

    func counts(after inputs: [Tally.Input], closing: Bool) async throws -> [Int] {
        let snapshots = try host.distinctSnapshots { $0.count }
        var iterator = snapshots.makeAsyncIterator()
        var counts: [Int] = []
        if let first = await iterator.next() { counts.append(first) }
        for input in inputs { try host.send(input) }
        if closing { host.close() }
        while let count = await iterator.next() { counts.append(count) }
        return counts
    }

    /// Reads a constant projection across a rename and the closure, through the concrete host or
    /// through generic code over the hosting protocol.
    ///
    /// Each read finishes before the next change, so every value read was offered, not coalesced away.
    func constantProjections(generic: Bool) async throws -> [Int?] {
        let snapshots = generic ? try Self.constant(of: host, isolation: self) : try host.snapshots { _ in 0 }
        var iterator = snapshots.makeAsyncIterator()
        var values = [await iterator.next()]
        try host.send(.rename("renamed"))
        values.append(await iterator.next())
        host.close()
        values.append(await iterator.next())
        values.append(await iterator.next())
        return values
    }

    private static func constant<Host: IsolatedStateMachineHost>(
        of host: Host,
        isolation: isolated Host.Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Int> {
        try host.snapshots({ _ in 0 }, isolation: isolation)
    }
}

@Suite struct HostObservationTests {
    private static func shared() -> Tally.Shared { Tally.Shared(workDriver: { 1 }) }
    @MainActor private static func mainActor(_ work: HeldWork? = nil) -> Tally.MainActorHost {
        Tally.MainActorHost(workDriver: { await work?.run() ?? 1 })
    }

    // MARK: Deduplicated projections

    /// Reads a projection of the count across an unchanged rename, a change, and an unchanged closure.
    ///
    /// Each read finishes before the next input, so a projection that were offered again after a rename
    /// or the closure would be read, not coalesced away.
    nonisolated(nonsending) private static func distinctCounts(
        _ snapshots: SnapshotSequence<Int>,
        send: (Tally.Input) async throws -> Void,
        close: () async -> Void
    ) async throws -> [Int?] {
        var iterator = snapshots.makeAsyncIterator()
        var counts: [Int?] = [await iterator.next()]
        try await send(.increment)
        counts.append(await iterator.next())
        try await send(.rename("unchanged count"))
        await close()
        counts.append(await iterator.next())
        return counts
    }

    @Test func aSharedProjectionOmitsUnchangedValuesThroughClosure() async throws {
        let host = Self.shared()
        let counts = try await Self.distinctCounts(
            try host.distinctSnapshots { $0.count },
            send: { try host.send($0) },
            close: { host.close() }
        )
        #expect(counts == [0, 1, nil])
    }

    @Test func anActorProjectionOmitsUnchangedValuesThroughClosure() async throws {
        let host = Tally.ActorHost(workDriver: { 1 })
        let counts = try await Self.distinctCounts(
            try await host.distinctSnapshots { $0.count },
            send: { try await host.send($0) },
            close: { await host.close() }
        )
        #expect(counts == [0, 1, nil])
    }

    @MainActor @Test func aMainActorProjectionOmitsUnchangedValuesThroughClosure() async throws {
        let host = Self.mainActor()
        let counts = try await Self.distinctCounts(
            try host.distinctSnapshots { $0.count },
            send: { try host.send($0) },
            close: { host.close() }
        )
        #expect(counts == [0, 1, nil])
    }

    @Test func aConfinedProjectionOmitsUnchangedValuesThroughClosure() async throws {
        let owner = await Owner()
        // Without a change after the first value, the next value is the closure's, which is omitted.
        #expect(try await owner.counts(after: [.increment, .rename("unchanged count")], closing: true) == [0, 1])
        #expect(try await Owner().counts(after: [.rename("same"), .rename("still same")], closing: true) == [0])
    }

    // `snapshots(_:)` never omits a projection, even an `Equatable` one equal to the one before it.
    @MainActor @Test func anEquatableProjectionKeepsEveryValue() async throws {
        let host = Self.mainActor()
        var iterator = try host.snapshots { $0.count }.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        try host.send(.rename("unchanged count"))
        #expect(await iterator.next() == 0)
        host.close()
        #expect(await iterator.next() == 0)
        #expect(await iterator.next() == nil)
    }

    @Test func aSharedEquatableProjectionKeepsEveryValue() async throws {
        let host = Self.shared()
        var iterator = try host.snapshots { $0.count }.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        try host.send(.rename("unchanged count"))
        #expect(await iterator.next() == 0)
        host.close()
        #expect(await iterator.next() == 0)
        #expect(await iterator.next() == nil)
    }

    // Moving a projection into generic code over the hosting protocol keeps what it delivers.
    @Test func aConfinedProjectionDeliversTheSameValuesThroughTheProtocol() async throws {
        let concrete = try await Owner().constantProjections(generic: false)
        let generic = try await Owner().constantProjections(generic: true)
        #expect(concrete == [0, 0, 0, nil])
        #expect(generic == concrete)
    }

    // MARK: Observation

    @MainActor @Test func aTrackedReadIsInvalidatedOnlyByAChangeToItsOwnValue() async throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let work = HeldWork()
        let host = Self.mainActor(work)
        let running = ChangeCount()
        let subscribers = ChangeCount()
        let pending = ChangeCount()
        let snapshot = ChangeCount()
        withObservationTracking {
            _ = host.runningCount
        } onChange: {
            running.raise()
        }
        withObservationTracking {
            _ = host.subscriberCount
        } onChange: {
            subscribers.raise()
        }
        withObservationTracking {
            _ = host.pendingCompletions()
        } onChange: {
            pending.raise()
        }
        withObservationTracking {
            _ = host.currentSnapshot
        } onChange: {
            snapshot.raise()
        }
        let receipt = try host.send(.increment)
        // The snapshot's reader is told during the commit; the others are not told at all.
        #expect(snapshot.value == 1)
        #expect(await host.flush(through: receipt) == .processed)
        #expect([running.value, subscribers.value, pending.value] == [0, 0, 0])
        #expect(host.subscriberCount == 0)

        // Each tracking below is new, so it counts only its own invalidation.
        let started = ChangeCount()
        let read = ChangeCount()
        withObservationTracking {
            _ = host.snapshot()
        } onChange: {
            read.raise()
        }
        withObservationTracking {
            _ = host.runningCount
        } onChange: {
            started.raise()
        }
        try host.send(.start)
        #expect(read.value == 1)
        _ = await work.started.next()
        #expect(started.value == 1)
        #expect(running.value == 1)
        #expect(host.runningCount == 1)

        let subscribed = ChangeCount()
        withObservationTracking {
            _ = host.subscriberCount
        } onChange: {
            subscribed.raise()
        }
        let subscription = try host.subscribe { _ in }
        #expect(subscribed.value == 1)
        #expect(subscribers.value == 1)
        subscription.cancel()

        let committed = Events<Void>()
        withObservationTracking {
            _ = host.currentSnapshot.count
        } onChange: {
            committed.record(())
        }
        await work.release(5)
        _ = await committed.next()
        #expect(host.currentSnapshot.count == 6)
        #expect(await host.shutdown() == .quiescent)
        #expect(pending.value == 1)
    }

    @MainActor @Test func theGeneratedMainActorHostIsObservable() {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        func observable(_ value: some Observable) -> Bool { true }
        #expect(observable(Self.mainActor()))
    }

    // MARK: Combine

    @MainActor @Test func aMainActorPublisherDeliversTheCurrentSnapshotUpdatesAndCompletion() async throws {
        let host = Self.mainActor()
        let publisher = try host.snapshotPublisher()
        #expect(host.subscriberCount == 1)
        let values = Events<Int>()
        let completions = Events<Void>()
        let cancellable = publisher.sink(
            receiveCompletion: { _ in completions.record(()) },
            receiveValue: { values.record($0.count) }
        )
        #expect(await values.next() == [0])
        try host.send(.increment)
        #expect(await values.next() == [1])
        host.close()
        #expect(await values.next() == [1])
        _ = await completions.next()
        #expect(host.subscriberCount == 0)
        cancellable.cancel()
    }

    @MainActor @Test func cancellingOrReleasingAPublisherFreesItsSlot() async throws {
        let host = Self.mainActor()
        let publisher = try host.snapshotPublisher()
        let cancellable = publisher.sink { _ in }
        #expect(host.subscriberCount == 1)
        cancellable.cancel()
        #expect(host.subscriberCount == 0)
        do { _ = try host.snapshotPublisher() }
        #expect(host.subscriberCount == 0)
        let shared = Self.shared()
        let sharedCancellable = try shared.snapshotPublisher().sink { _ in }
        #expect(shared.subscriberCount == 1)
        sharedCancellable.cancel()
        #expect(shared.subscriberCount == 0)
    }

    @MainActor @Test func aSecondSubscriberFinishesAtOnce() throws {
        let host = Self.mainActor()
        let publisher = try host.snapshotPublisher()
        var first: [Int] = []
        let kept = publisher.sink { first.append($0.count) }
        var finished = false
        var second: [Int] = []
        let later = publisher.sink(
            receiveCompletion: { _ in finished = true },
            receiveValue: { second.append($0.count) }
        )
        #expect(first == [0])
        #expect(second.isEmpty)
        #expect(finished)
        kept.cancel()
        later.cancel()
    }

    @MainActor @Test func aSlowSubscriberReceivesTheLatestSnapshotWhenItRequests() async throws {
        let host = Self.mainActor()
        let received = Events<Int>()
        final class Demanding: Subscriber {
            typealias Input = Tally.Snapshot
            typealias Failure = Never
            var subscription: (any Subscription)?
            let received: Events<Int>
            init(_ received: Events<Int>) { self.received = received }
            func receive(subscription: any Subscription) { self.subscription = subscription }
            func receive(_ input: Tally.Snapshot) -> Subscribers.Demand {
                received.record(input.count)
                return .none
            }
            func receive(completion: Subscribers.Completion<Never>) {}
        }
        let subscriber = Demanding(received)
        try host.snapshotPublisher().receive(subscriber: subscriber)
        let receipt = try host.send(.increment)
        try host.send(.increment)
        #expect(await host.flush(through: receipt) == .processed)
        let latest = try host.send(.increment)
        #expect(await host.flush(through: latest) == .processed)
        subscriber.subscription?.request(.max(1))
        #expect(await received.next() == [3])
        subscriber.subscription?.cancel()
        #expect(host.subscriberCount == 0)
    }

    @MainActor @Test func anActorPublisherDeliversOnTheMainActorAndFinishesOnClose() async throws {
        let host = Tally.ActorHost(workDriver: { 1 })
        let publisher = try await host.snapshotPublisher()
        #expect(await host.subscriberCount == 1)
        let values = Events<Int>()
        let completions = Events<Void>()
        let cancellable = publisher.sink(
            receiveCompletion: { _ in completions.record(()) },
            receiveValue: { values.record($0.count) }
        )
        #expect(await values.next() == [0])
        try await host.send(.increment)
        #expect(await values.next() == [1])
        await host.close()
        #expect(await values.next() == [1])
        _ = await completions.next()
        cancellable.cancel()
    }

    // MARK: Shared executor

    @Test func anActorHostCanShareAnotherActorsExecutor() async throws {
        let anchor = Anchor()
        let host = Tally.ActorHost(workDriver: { 1 }, isolatedTo: anchor)
        let marked = Events<Void>()
        // The registration's first callback runs in the host's turn, which is a turn of the anchor's executor.
        let subscription = try await host.subscribe { _ in
            anchor.assumeIsolated { $0.mark() }
            marked.record(())
        }
        _ = await marked.next()
        subscription.cancel()
        #expect(try await host.send(.increment).revision == 1)
    }
}
