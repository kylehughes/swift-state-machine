import StateMachine
import Testing

/// A graph whose completion edge refuses some outcomes, so a delivered completion can park.
@StateMachine(mode: .shared)
nonisolated private enum RefusingFlow: Sendable {
    struct Ready: Sendable { var accepted: [Int] = [] }
    @Initial case ready(Ready = Ready())
    enum Input: Sendable { case check(Int) }
    enum Refusal: Error, Sendable { case negative }
    @Operation(activeIn: [Ready.self])
    enum Check {
        typealias Input = Int
        typealias Output = Int
    }
    @Transition(on: Input.check, starts: [Check.self])
    fileprivate static func check(_ source: Ready, _ value: Int) -> Change<Ready, Effect.Check> {
        Change(source, effects: [.check(value)])
    }
    @Transition(onSuccess: Check.self)
    fileprivate static func checked(_ source: Ready, _ value: Check.Output) throws(Refusal) -> Ready {
        guard value >= 0 else { throw .negative }
        return Ready(accepted: source.accepted + [value])
    }
}

/// The pure-retry policy can still tell its caller about a completion that only the caller can settle.
@Suite(.timeLimit(.minutes(1))) struct CompletionPolicyTests {
    private struct Unexpected: Error {}

    /// Awaits the next retained completion a handler reports.
    private func nextReported(
        _ reports: inout AsyncStream<RefusingFlow.PendingCompletion>.Iterator
    ) async throws -> RefusingFlow.PendingCompletion {
        try #require(await reports.next())
    }

    private func expectRefused(_ pending: RefusingFlow.PendingCompletion) {
        #expect(pending.status == .reconciliationRequired)
        #expect(pending.attempts == 1)
        guard case .check(-1) = pending.outcome,
            case .preparation(.checked(.negative)) = pending.lastRejection
        else {
            Issue.record("The handler received a different completion")
            return
        }
    }

    /// Accepted values, read once the owner has committed `count` of them.
    private func accepted(_ snapshots: RefusingFlow.Snapshots, count: Int) async -> [Int] {
        for await snapshot in snapshots {
            guard case .ready(let ready) = snapshot, ready.value.accepted.count == count else { continue }
            return ready.value.accepted
        }
        return []
    }

    @Test func aPureRetryHandlerReportsACompletionItsEdgeRefusesOnSharedAndActorOwners() async throws {
        let (sharedStream, sharedReport) = AsyncStream<RefusingFlow.PendingCompletion>.makeStream()
        let shared = RefusingFlow.Shared(
            checkDriver: { $0 },
            completionPolicy: .retryPure(onReconciliationRequired: { sharedReport.yield($0) })
        )
        let sharedSnapshots = try shared.snapshots()
        try shared.send(.check(1))
        #expect(await accepted(sharedSnapshots, count: 1) == [1])
        try shared.send(.check(-1))
        var sharedReports = sharedStream.makeAsyncIterator()
        let sharedRefused = try await nextReported(&sharedReports)
        expectRefused(sharedRefused)
        #expect(shared.pendingCompletions().map(\.id) == [sharedRefused.id])
        await shared.shutdown()
        sharedReport.finish()
        // The committed completion was never reported.
        #expect(await sharedReports.next() == nil)

        let (actorStream, actorReport) = AsyncStream<RefusingFlow.PendingCompletion>.makeStream()
        let actor = RefusingFlow.ActorHost(
            checkDriver: { $0 },
            completionPolicy: .retryPure(onReconciliationRequired: { actorReport.yield($0) })
        )
        let actorSnapshots = try await actor.snapshots()
        try await actor.send(.check(2))
        #expect(await accepted(actorSnapshots, count: 1) == [2])
        try await actor.send(.check(-1))
        var actorReports = actorStream.makeAsyncIterator()
        let actorRefused = try await nextReported(&actorReports)
        expectRefused(actorRefused)
        #expect(await actor.pendingCompletions().map(\.id) == [actorRefused.id])
        await actor.shutdown()
        actorReport.finish()
        #expect(await actorReports.next() == nil)
    }

    @MainActor @Test func aPureRetryHandlerRunsOnTheMainActorForAMainActorOwner() async throws {
        let (stream, report) = AsyncStream<RefusingFlow.PendingCompletion>.makeStream()
        let owner = RefusingFlow.MainActorHost(
            checkDriver: { $0 },
            completionPolicy: .retryPure(onReconciliationRequired: { pending in
                MainActor.assertIsolated()
                report.yield(pending)
            })
        )
        try owner.send(.check(-1))
        var reports = stream.makeAsyncIterator()
        let refused = try await nextReported(&reports)
        expectRefused(refused)
        // The refused completion stays retained until the caller settles it.
        guard case .discarded = owner.discardPending(id: refused.id) else { throw Unexpected() }
        #expect(owner.pendingCompletions().isEmpty)
        #expect(await owner.shutdown() == .quiescent)
    }
}
