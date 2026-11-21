import StateMachine
import StateMachineExamples
import Testing

/// A graph whose operations name no scope, no admission, and no failure, and whose one working phase
/// stays restorable.
@StateMachine(mode: .shared)
nonisolated private enum DefaultsFlow: Sendable {
    struct Idle: Sendable {}
    struct Ready: Sendable { var log: [String] = [] }
    @Initial case idle(Idle = Idle())
    case ready(Ready)
    enum Input: Sendable {
        case open
        case close
        case request(Int)
        case inspect(Int)
    }
    @Operation(activeIn: [Ready.self])
    enum Fetch {
        typealias Input = Int
        typealias Output = String
    }
    @Operation(activeIn: [Ready.self])
    enum Audit {
        typealias Input = Int
        typealias Output = String
    }
    @Restoration(allows: [Ready.self])
    fileprivate static func restore(_ saved: [String]) -> Restoration {
        saved.isEmpty ? .idle(Idle()) : .ready(Ready(log: saved))
    }
    @Transition(on: Input.open)
    fileprivate static func open(_ source: Idle) -> Ready { Ready() }
    @Transition(on: Input.close)
    fileprivate static func close(_ source: Ready) -> Idle { Idle() }
    @Transition(on: Input.request, starts: [Fetch.self])
    fileprivate static func request(_ source: Ready, _ value: Int) -> Change<Ready, Effect.Request> {
        Change(source, effects: [.fetch(value)])
    }
    @Transition(on: Input.inspect, starts: [Audit.self])
    fileprivate static func inspect(_ source: Ready, _ value: Int) -> Change<Ready, Effect.Inspect> {
        Change(source, effects: [.audit(value)])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func fetched(_ source: Ready, _ output: Fetch.Output) -> Ready {
        Ready(log: source.log + ["fetch=" + output])
    }
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: Ready, _ output: Audit.Output) -> Ready {
        Ready(log: source.log + ["audit=" + output])
    }
}

/// A graph whose completion router can decline an outcome, leaving it for reconciliation.
@StateMachine(mode: .shared)
nonisolated private enum ScreenedFlow: Sendable {
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
    fileprivate static func checked(_ source: Ready, _ value: Check.Output) -> Ready {
        Ready(accepted: source.accepted + [value])
    }
    @Route(onSuccess: Check.self)
    fileprivate static func screen(_ source: Ready, _ value: Check.Output) throws(Refusal) -> Route.Screen {
        guard value >= 0 else { throw .negative }
        return .checked
    }
}

/// Operations that omit `scope:`, `admission:`, and `Failure` get the defaults those omissions name.
@Suite(.timeLimit(.minutes(1))) struct DeclarationDefaultsTests {
    private struct Unexpected: Error {}

    /// Opens a fresh local owner and returns it in its working phase.
    private func opened() throws -> DefaultsFlow.Local {
        var owner = DefaultsFlow.Local()
        try owner.send(.open)
        _ = owner.drainCommands(limit: 8)
        return owner
    }

    private func log(_ snapshot: DefaultsFlow.Snapshot) -> [String]? {
        guard case .ready(let ready) = snapshot else { return nil }
        return ready.value.log
    }

    @Test func anOperationWithoutAScopeIsRevokedWhenItsPhaseEndsAndItsLateResultIsStale() throws {
        var owner = try opened()
        try owner.send(.request(1))
        guard case .fetch(let work)? = owner.drainCommands(limit: 8).first?.commands.first else { throw Unexpected() }
        try owner.send(.close)
        let batch = try #require(owner.drainCommands(limit: 8).first)
        guard batch.commands.count == 1, case .cancel(let execution) = batch.commands[0] else { throw Unexpected() }
        #expect(execution == work.execution)
        guard case .stale = owner.deliver(work.succeeded("late")), case .idle = owner.snapshot() else {
            throw Unexpected()
        }
        #expect(owner.pendingCompletions().isEmpty)
        #expect(owner.acknowledgeExecution(work.execution, disposition: .terminated) == .recorded)
    }

    @Test func operationsWithoutScopesInTheSamePhaseDoNotRevokeEachOther() throws {
        var owner = try opened()
        try owner.send(.request(1))
        try owner.send(.inspect(2))
        let commands = owner.drainCommands(limit: 8).flatMap(\.commands)
        guard commands.count == 2, case .fetch(let fetch) = commands[0], case .audit(let audit) = commands[1] else {
            throw Unexpected()
        }
        guard case .committed = owner.deliver(audit.succeeded("A")),
            case .committed = owner.deliver(fetch.succeeded("F"))
        else { throw Unexpected() }
        #expect(log(owner.snapshot()) == ["audit=A", "fetch=F"])
    }

    @Test func theDefaultAdmissionReplacesTheEarlierWorkOfTheSameOperationOnly() throws {
        var owner = try opened()
        try owner.send(.request(1))
        guard case .fetch(let first)? = owner.drainCommands(limit: 8).first?.commands.first else { throw Unexpected() }
        try owner.send(.inspect(2))
        try owner.send(.request(3))
        let batches = owner.drainCommands(limit: 8)
        guard batches.count == 2, case .audit(let audit) = batches[0].commands.first else { throw Unexpected() }
        // The second request cancels the first fetch and starts its replacement; the audit keeps running.
        let replacement = batches[1].commands
        guard replacement.count == 2, case .cancel(let cancelled) = replacement[0],
            case .fetch(let second) = replacement[1]
        else { throw Unexpected() }
        #expect(cancelled == first.execution)
        #expect(second.input == 3)
        guard case .stale = owner.deliver(first.succeeded("first")),
            case .committed = owner.deliver(audit.succeeded("A")),
            case .committed = owner.deliver(second.succeeded("second"))
        else { throw Unexpected() }
        #expect(log(owner.snapshot()) == ["audit=A", "fetch=second"])
    }

    /// Waits for the log of the working phase to reach `count` entries.
    private func settled(_ snapshots: DefaultsFlow.Snapshots, count: Int) async -> [String]? {
        for await snapshot in snapshots {
            if let log = log(snapshot), log.count == count { return log }
        }
        return nil
    }

    @Test func aSharedOwnerRunsDriversThatReturnTheBareOutput() async throws {
        let owner = DefaultsFlow.Shared(fetchDriver: { "F\($0)" }, auditDriver: { "A\($0)" })
        var values = try owner.snapshots().makeAsyncIterator()
        try owner.send(.open)
        // A shared `send` makes one attempt, so each input waits for the previous completion to commit.
        try owner.send(.request(1))
        var log: [String]?
        while log?.count != 1, let snapshot = await values.next() { log = self.log(snapshot) }
        try owner.send(.inspect(2))
        while log?.count != 2, let snapshot = await values.next() { log = self.log(snapshot) }
        #expect(log == ["fetch=F1", "audit=A2"])
        await owner.shutdown()
    }

    @Test func anActorOwnerRunsDriversThatReturnTheBareOutput() async throws {
        let owner = DefaultsFlow.ActorHost(drivers: .init(fetch: { "F\($0)" }, audit: { "A\($0)" }))
        let snapshots = try await owner.snapshots()
        try await owner.send(.open)
        try await owner.send(.request(1))
        try await owner.send(.inspect(2))
        #expect(await settled(snapshots, count: 2)?.sorted() == ["audit=A2", "fetch=F1"])
        await owner.shutdown()
    }

    @MainActor @Test func aMainActorOwnerRunsDriversThatReturnTheBareOutput() async throws {
        let owner = DefaultsFlow.MainActorHost(
            fetchDriver: { input in
                MainActor.assertIsolated()
                return "F\(input)"
            },
            auditDriver: { "A\($0)" }
        )
        var values = try owner.snapshots().makeAsyncIterator()
        try owner.send(.open)
        try owner.send(.request(1))
        try owner.send(.inspect(2))
        var log: [String]?
        while let snapshot = await values.next() {
            guard case .ready(let ready) = snapshot, ready.value.log.count == 2 else { continue }
            log = ready.value.log.sorted()
            break
        }
        #expect(log == ["audit=A2", "fetch=F1"])
        await owner.shutdown()
    }

    @Test func restoringIntoAnAllowedPhaseStartsWithNoWorkAndItsEdgesStillStartWork() throws {
        var owner = DefaultsFlow.Local(restoring: ["saved"])
        #expect(owner.snapshot().revision == 0)
        #expect(log(owner.snapshot()) == ["saved"])
        #expect(owner.drainCommands(limit: 8).isEmpty)
        #expect(owner.pendingCompletions().isEmpty)
        try owner.send(.request(4))
        guard case .fetch(let work)? = owner.drainCommands(limit: 8).first?.commands.first else { throw Unexpected() }
        guard case .committed = owner.deliver(work.succeeded("restored")) else { throw Unexpected() }
        #expect(log(owner.snapshot()) == ["saved", "fetch=restored"])
        // The resting phase stays restorable without being listed.
        guard case .idle = DefaultsFlow.Local(restoring: []).snapshot() else { throw Unexpected() }
    }

    @Test func aManagedOwnerRestoredIntoAnAllowedPhaseRunsNothingUntilAnEdgeStartsWork() async throws {
        let owner = DefaultsFlow.Shared(restoring: ["saved"], fetchDriver: { "F\($0)" }, auditDriver: { "A\($0)" })
        #expect(owner.snapshot().revision == 0)
        #expect(owner.pendingCompletions().isEmpty)
        let snapshots = try owner.snapshots()
        try owner.send(.inspect(5))
        #expect(await settled(snapshots, count: 2) == ["saved", "audit=A5"])
        await owner.shutdown()
    }

    /// Awaits the first retained completion a manual handler reports.
    private func firstReported(
        _ reports: AsyncStream<ScreenedFlow.PendingCompletion>
    ) async throws
        -> ScreenedFlow.PendingCompletion
    {
        var iterator = reports.makeAsyncIterator()
        return try #require(await iterator.next())
    }

    private func expectDeclined(_ pending: ScreenedFlow.PendingCompletion) {
        #expect(pending.status == .reconciliationRequired)
        guard case .check(-1, _) = pending.outcome, case .preparation(.screen(.negative)) = pending.lastRejection
        else {
            Issue.record("The handler received a different completion")
            return
        }
    }

    @Test func aManualHandlerReceivesACompletionThatNeedsReconciliationOnSharedAndActorOwners() async throws {
        let (sharedReports, sharedReport) = AsyncStream<ScreenedFlow.PendingCompletion>.makeStream()
        let shared = ScreenedFlow.Shared(
            checkDriver: { $0 },
            completionPolicy: .manual(onReconciliationRequired: { sharedReport.yield($0) })
        )
        try shared.send(.check(-1))
        expectDeclined(try await firstReported(sharedReports))
        #expect(shared.pendingCompletions().count == 1)
        await shared.shutdown()

        let (actorReports, actorReport) = AsyncStream<ScreenedFlow.PendingCompletion>.makeStream()
        let actor = ScreenedFlow.ActorHost(
            checkDriver: { $0 },
            completionPolicy: .manual(onReconciliationRequired: { actorReport.yield($0) })
        )
        try await actor.send(.check(-1))
        expectDeclined(try await firstReported(actorReports))
        #expect(await actor.pendingCompletions().count == 1)
        await actor.shutdown()
    }

    @MainActor @Test func aManualHandlerRunsOnTheMainActorForAMainActorOwner() async throws {
        let (reports, report) = AsyncStream<ScreenedFlow.PendingCompletion>.makeStream()
        let owner = ScreenedFlow.MainActorHost(
            checkDriver: { $0 },
            completionPolicy: .manual(onReconciliationRequired: { pending in
                MainActor.assertIsolated()
                report.yield(pending)
            })
        )
        try owner.send(.check(-1))
        expectDeclined(try await firstReported(reports))
        #expect(owner.pendingCompletions().count == 1)
        await owner.shutdown()
    }
}

/// `Owned` runs a completion's router exactly as delivery does.
@Suite struct OwnedCompletionRouterTests {
    private struct Unexpected: Error {}
    private func requireSendable<Value: Sendable & ~Copyable>(_: Value.Type) {}

    @Test func anOwnedPhaseRunsTheCompletionRouterInsteadOfItsCandidate() throws {
        // Delivering -1 runs `screen`, which declines it; the owned method does the same.
        switch ScreenedFlow.owned().screen(-1) {
        case .rejected(.negative, let original):
            #expect(original.withValue { $0.accepted }.isEmpty)
        case .checked: throw Unexpected()
        }
        switch ScreenedFlow.owned().screen(2) {
        case .checked(let next): #expect(next.withValue { $0.accepted } == [2])
        case .rejected: throw Unexpected()
        }
    }

    @Test func aSharedModeRouteResultIsSendable() {
        requireSendable(ScreenedFlow.Route.ScreenResult.self)
        requireSendable(GeneratedRetry.Route.DecideResult.self)
        requireSendable(GeneratedScreen.Route.ScreenResult.self)
    }
}
