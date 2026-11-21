import StateMachine
import Testing

/// A graph whose completion edge refuses negative values, so a delivered completion parks until settled.
@StateMachine(mode: .shared)
nonisolated private enum Screening: Sendable {
    struct Ready: Sendable { var accepted: [Int] = [] }
    @Initial case ready(Ready = Ready())
    enum Input: Sendable { case check(Int) }
    enum Refusal: Error, Sendable { case negative }
    @Operation(activeIn: [Ready.self], admission: .parallel(limit: 8))
    enum Check {
        typealias Input = Int
        typealias Output = Int
    }
    @Transition(on: Input.check, starts: [Check.self])
    static func check(_ source: Ready, _ value: Int) -> Change<Ready, Effect.Check> {
        Change(source, effects: [.check(value)])
    }
    @Transition(onSuccess: Check.self)
    static func checked(_ source: Ready, _ value: Check.Output) throws(Refusal) -> Ready {
        guard value >= 0 else { throw .negative }
        return Ready(accepted: source.accepted + [value])
    }
}

/// The whole collection of retained completions, observed as it changes.
@Suite(.timeLimit(.minutes(1))) struct PendingCompletionUpdatesTests {
    private struct Unexpected: Error {}

    /// The checked values of a collection, in its order.
    private func values(_ collection: [Screening.PendingCompletion]) -> [Int] {
        collection.compactMap { pending in
            guard case .check(let value, _) = pending.outcome else { return nil }
            return value
        }
    }

    /// Reads until a collection's retained values are all parked and equal `expected`.
    private func parked(
        _ iterator: inout Screening.PendingCompletionUpdates.AsyncIterator,
        _ expected: [Int]
    ) async throws -> [Screening.PendingCompletion] {
        while let collection = await iterator.next() {
            if values(collection) == expected, collection.allSatisfy({ $0.status == .reconciliationRequired }) {
                return collection
            }
        }
        throw Unexpected()
    }

    @Test func aSharedOwnerReportsTheWholeCollectionAndEndsWithAnEmptyOneOnClose() async throws {
        let owner = Screening.Shared(checkDriver: { $0 }, completionPolicy: .manual)
        let updates = try owner.pendingCompletionUpdates()
        var iterator = updates.makeAsyncIterator()
        // The first element is the collection at registration.
        #expect(await iterator.next().map(values) == [])
        try owner.send(.check(-1))
        let first = try await parked(&iterator, [-1])
        try owner.send(.check(-2))
        let both = try await parked(&iterator, [-1, -2])
        #expect(both.map(\.id) == first.map(\.id) + [both[1].id])
        guard case .discarded = owner.discardPending(id: first[0].id) else { throw Unexpected() }
        _ = try await parked(&iterator, [-2])
        owner.close()
        var last: [Screening.PendingCompletion]?
        while let collection = await iterator.next() { last = collection }
        // Closing ends the sequence after a final, empty collection.
        #expect(last.map(values) == [])
        #expect(await owner.shutdown() == .quiescent)
    }

    @Test func registrationCapturesWhatIsAlreadyRetained() async throws {
        let (reports, report) = AsyncStream<Screening.PendingCompletion>.makeStream()
        let owner = Screening.ActorHost(
            checkDriver: { $0 },
            completionPolicy: .manual(onReconciliationRequired: { report.yield($0) })
        )
        try await owner.send(.check(-3))
        var reported = reports.makeAsyncIterator()
        let refused = try #require(await reported.next())
        let updates = try await owner.pendingCompletionUpdates()
        var iterator = updates.makeAsyncIterator()
        let initial = try #require(await iterator.next())
        #expect(initial.map(\.id) == [refused.id])
        #expect(values(initial) == [-3])
        await owner.close()
        var last: [Screening.PendingCompletion]?
        while let collection = await iterator.next() { last = collection }
        #expect(last.map(values) == [])
        report.finish()
    }

    @MainActor @Test func anUnreadCollectionIsReplacedByTheLatestOne() async throws {
        let (reports, report) = AsyncStream<Screening.PendingCompletion>.makeStream()
        let owner = Screening.MainActorHost(
            checkDriver: { $0 },
            completionPolicy: .manual(onReconciliationRequired: { report.yield($0) })
        )
        let updates = try owner.pendingCompletionUpdates()
        try owner.send(.check(-1))
        try owner.send(.check(-2))
        var reported = reports.makeAsyncIterator()
        _ = await reported.next()
        _ = await reported.next()
        // Both refusals happened before the first read, so it skips the initial, empty collection and
        // every collection in between.
        var iterator = updates.makeAsyncIterator()
        let latest = try #require(await iterator.next())
        #expect(values(latest) == [-1, -2])
        #expect(latest.allSatisfy { $0.status == .reconciliationRequired })
        owner.close()
        #expect(await iterator.next().map(values) == [])
        #expect(await iterator.next() == nil)
        report.finish()
    }

    @Test func aClosedOwnerDeliversOneEmptyCollectionAndEnds() async throws {
        let owner = Screening.Shared(checkDriver: { $0 }, completionPolicy: .retry)
        owner.close()
        let updates = try owner.pendingCompletionUpdates()
        var iterator = updates.makeAsyncIterator()
        #expect(await iterator.next().map(values) == [])
        #expect(await iterator.next() == nil)
        #expect(owner.subscriberCount == 0)
    }

    @Test func eachRegistrationTakesASubscriberSlot() async throws {
        let owner = Screening.Shared(
            checkDriver: { $0 },
            configuration: try .init(subscribers: 2),
            completionPolicy: .retry
        )
        let snapshots = try owner.snapshots()
        let updates = try owner.pendingCompletionUpdates()
        #expect(owner.subscriberCount == 2)
        #expect(throws: Screening.SubscriptionFailure.self) { try owner.pendingCompletionUpdates() }
        _ = snapshots
        _ = updates
        await owner.shutdown()
    }
}

/// A one-shot event a test awaits instead of inferring progress from scheduling.
private struct Arrival: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
    func raise() { continuation.yield(()) }
    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

/// The actor that owns a screening and discards from inside a projection.
private actor ScreeningDesk {
    private var host: Screening.IsolatedHost<ScreeningDesk>!

    init() async {
        host = Screening.IsolatedHost(isolation: self, checkDriver: { _, value in value }, completionPolicy: .manual)
    }

    func latestCountsAfterAProjectionDiscards() async throws -> (Int?, Int?, Int) {
        let discarded = Arrival()
        var once = false
        let first = try host.pendingCompletionUpdates { pending -> Int in
            if !once, let refused = pending.first, refused.status == .reconciliationRequired {
                once = true
                _ = self.host.discardPending(id: refused.id)
                discarded.raise()
            }
            return pending.count
        }
        let second = try host.pendingCompletionUpdates { $0.count }
        try host.send(.check(-1))
        await discarded.wait()
        var firstLatest = first.makeAsyncIterator()
        var secondLatest = second.makeAsyncIterator()
        return (await firstLatest.next(), await secondLatest.next(), host.pendingCompletions().count)
    }

    func close() async { await host.shutdown() }
}

/// A callback that changes the retained completions never leaves a registration with an older collection.
@Suite(.timeLimit(.minutes(1))) struct ReentrantPendingPublicationTests {
    @MainActor @Test
    func aMainActorProjectionThatDiscardsLeavesEveryRegistrationWithTheNewestCollection() async throws {
        var host: Screening.MainActorHost!
        host = Screening.MainActorHost(checkDriver: { $0 }, completionPolicy: .manual)
        let discarded = Arrival()
        var once = false
        let first = try host.pendingCompletionUpdates { pending -> Int in
            if !once, let refused = pending.first, refused.status == .reconciliationRequired {
                once = true
                _ = host.discardPending(id: refused.id)
                discarded.raise()
            }
            return pending.count
        }
        let second = try host.pendingCompletionUpdates { $0.count }
        try host.send(.check(-1))
        await discarded.wait()
        var firstLatest = first.makeAsyncIterator()
        var secondLatest = second.makeAsyncIterator()
        // Each latest-value sequence holds the collection published last, which is the empty one.
        #expect(await firstLatest.next() == 0)
        #expect(await secondLatest.next() == 0)
        #expect(host.pendingCompletions().isEmpty)
        await host.shutdown()
    }

    @Test func anIsolatedProjectionThatDiscardsLeavesEveryRegistrationWithTheNewestCollection() async throws {
        let desk = await ScreeningDesk()
        let (first, second, retained) = try await desk.latestCountsAfterAProjectionDiscards()
        #expect(first == 0)
        #expect(second == 0)
        #expect(retained == 0)
        await desk.close()
    }
}
