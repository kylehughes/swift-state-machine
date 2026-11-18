import StateMachine
import StateMachineExamples
import Testing

/// A completion has one admission path, so the first retained outcome is the only one that can commit.
@Suite struct CompletionAdmissionTests {
    private struct Unexpected: Error {}

    @Test func aSecondOutcomeForRetainedWorkCannotReplaceTheFirst() throws {
        let user = try UserID("taylor")
        let request = try ProfileRequest(userID: user)
        let first = Profile(userID: user, name: "A-first")
        let second = Profile(userID: user, name: "B-second")
        // A one-batch queue holds the audit start, so the first outcome waits for capacity.
        var machine = GeneratedProfile.Local(.init(userID: user), configuration: try .init(commits: 1))
        try machine.send(.load(request))
        guard case .fetch(let work)? = machine.drainCommands(limit: 1).first?.commands.first else { throw Unexpected() }
        try machine.send(.audit("trace"))
        guard case .pending(let id, .waitingForCapacity) = machine.deliver(work.succeeded(first)) else {
            throw Unexpected()
        }
        // Delivering another payload for the same work reports the retained outcome and replaces nothing.
        guard case .pending(let again, .waitingForCapacity) = machine.deliver(work.succeeded(second)) else {
            throw Unexpected()
        }
        #expect(again == id)
        let retained = machine.pendingCompletions()
        #expect(retained.map(\.id) == [id])
        guard case .fetch(.success(let value))? = retained.first?.outcome else { throw Unexpected() }
        #expect(value == first)
        _ = machine.drainCommands(limit: 1)
        guard case .committed = machine.retryAdmission(id: id), case .loaded(let loaded) = machine.snapshot() else {
            throw Unexpected()
        }
        #expect(loaded.value.profile == first)
        guard case .stale = machine.deliver(work.succeeded(second)) else { throw Unexpected() }
        guard case .loaded(let after) = machine.snapshot() else { throw Unexpected() }
        #expect(after.value.profile == first)
        #expect(machine.pendingCompletions().isEmpty)
    }

    @Test func pendingIdentitiesAreHashableValuesOfTheirSchema() throws {
        let user = try UserID("taylor")
        var machine = GeneratedProfile.Local(.init(userID: user), configuration: try .init(commits: 1))
        try machine.send(.load(try ProfileRequest(userID: user)))
        guard case .fetch(let work)? = machine.drainCommands(limit: 1).first?.commands.first else { throw Unexpected() }
        try machine.send(.audit("trace"))
        guard case .pending(let id, _) = machine.deliver(work.failed(.unavailable)) else { throw Unexpected() }
        let identities: Set<GeneratedProfile.PendingCompletionID> = [id, id]
        #expect(identities.count == 1)
        guard case .fetch(.failure(.unavailable))? = machine.pendingCompletions().first?.outcome else {
            throw Unexpected()
        }
        // Discarding is an ordinary authority-only commit, so it needs the queue slot the audit batch holds.
        _ = machine.drainCommands(limit: 1)
        guard case .discarded = machine.discardPending(id: id), case .notPending = machine.discardPending(id: id) else {
            throw Unexpected()
        }
    }
}

@StateMachine(mode: .shared)
nonisolated private enum RoutedFlow: Sendable {
    struct Idle: Sendable {}
    struct Loaded: Sendable { let value: String }
    @Initial case loaded(Loaded)
    case idle(Idle)
    enum Problem: Error, Sendable { case offline }
    enum Input: Sendable { case tick(Bool) }
    @Transition(on: Input.tick)
    fileprivate static func restart(_ source: Loaded, _ again: Bool) -> Idle { Idle() }
    @Transition(on: Input.tick)
    fileprivate static func keep(_ source: Loaded, _ again: Bool) -> Loaded { source }
    @Route(on: Input.tick)
    fileprivate static func choose(_ source: Loaded, _ again: Bool) throws(Problem) -> Route.Choose {
        guard source.value != "offline" else { throw .offline }
        return again ? .restart : .keep
    }
}

@StateMachine(mode: .isolated)
nonisolated private enum PickFlow {
    struct Start {}
    struct Done { let value: Int }
    @Initial case start(Start)
    case done(Done)
    enum Problem: Error { case refused }
    enum Rejected: Error { case negative }
    enum Input {
        case go(Int)
        case pick(Int)
    }
    @Transition(on: Input.go)
    fileprivate static func low(_ source: Start, _ value: Int) -> Done { Done(value: value) }
    @Transition(on: Input.go)
    fileprivate static func high(_ source: Start, _ value: Int) -> Done { Done(value: value * 10) }
    @Route(on: Input.go)
    fileprivate static func size(_ source: Start, _ value: Int) -> Route.Size { value < 10 ? .low : .high }
    @Transition(on: Input.pick)
    fileprivate static func accept(_ source: Start, _ value: Int) throws(Rejected) -> Done {
        guard value >= 0 else { throw .negative }
        return Done(value: value)
    }
    @Transition(on: Input.pick)
    fileprivate static func stay(_ source: Start, _ value: Int) -> Start { source }
    @Route(on: Input.pick)
    fileprivate static func choice(_ source: Start, _ value: Int) throws(Problem) -> Route.Choice {
        guard value != 13 else { throw .refused }
        return value == 0 ? .stay : .accept
    }
}

/// A typed call on an observed or owned phase obeys the router exactly as `send` does.
@Suite struct RoutedEdgeTests {
    private struct Unexpected: Error {}

    @Test func anObservedPhaseRunsItsRouterBeforeTheSelectedEdge() throws {
        var local = RoutedFlow.Local(.init(value: "offline"))
        guard case .loaded(let loaded) = local.snapshot() else { throw Unexpected() }
        #expect(throws: RoutedFlow.Problem.offline) { _ = try loaded.choose(true) }
        do {
            try local.send(.tick(true))
            Issue.record("send bypassed the router")
        } catch {
            guard case .preparation(.choose(.offline)) = error else { throw Unexpected() }
        }
        #expect(local.snapshot().revision == 0)

        var online = RoutedFlow.Local(.init(value: "online"))
        guard case .loaded(let current) = online.snapshot() else { throw Unexpected() }
        guard case .committed(let kept) = online.commit(try current.choose(false)), case .loaded = kept.snapshot else {
            throw Unexpected()
        }
        guard case .loaded(let next) = online.snapshot(),
            case .committed(let restarted) = online.commit(try next.choose(true)), case .idle = restarted.snapshot
        else { throw Unexpected() }
    }

    @Test func anImportedRoutedGraphExposesOnlyItsRouter() throws {
        var locked = GeneratedRetry.Local(.init(attempts: 1, locked: true))
        guard case .waiting(let waiting) = locked.snapshot() else { throw Unexpected() }
        #expect(throws: GeneratedRetry.Refusal.locked) { _ = try waiting.decide() }
        #expect(throws: GeneratedRetry.SendRejection.self) { try locked.send(.retry) }
        var open = GeneratedRetry.Local(.init(attempts: GeneratedRetry.limit, locked: false))
        guard case .waiting(let last) = open.snapshot(),
            case .committed(let receipt) = open.commit(try last.decide()), case .gaveUp = receipt.snapshot
        else { throw Unexpected() }
        switch GeneratedRetry.owned(.init(attempts: 0, locked: false)).decide() {
        case .again(let trying): #expect(trying.withValue { $0.attempt } == 1)
        default: Issue.record("the router's choice was not taken")
        }
    }

    @Test func anOwnedPhaseRunsItsRouterAndReturnsTheSourceWhenItDeclines() throws {
        switch RoutedFlow.owned(.init(value: "offline")).choose(true) {
        case .rejected(let problem, let original):
            #expect(problem == .offline)
            #expect(original.withValue { $0.value } == "offline")
        default: Issue.record("an owned typed call bypassed the router")
        }
        switch RoutedFlow.owned(.init(value: "online")).choose(true) {
        case .restart: break
        default: Issue.record("the router's choice was not taken")
        }
    }

    @Test func aRouterWhoseEdgesShareAResultReturnsItDirectly() throws {
        #expect(PickFlow.owned(.init()).size(3).withValue { $0.value } == 3)
        #expect(PickFlow.owned(.init()).size(30).withValue { $0.value } == 300)
        var local = PickFlow.Local(.init())
        guard case .start(let start) = local.snapshot(),
            case .committed(let receipt) = local.commit(start.size(30)), case .done(let done) = receipt.snapshot
        else { throw Unexpected() }
        #expect(done.value.value == 300)
    }

    @Test func aRoutedGroupWithSeveralThrowingFunctionsNamesEachFailure() throws {
        var local = PickFlow.Local(.init())
        guard case .start(let start) = local.snapshot() else { throw Unexpected() }
        do {
            _ = try start.choice(13)
            Issue.record("the router did not decline")
        } catch { guard case .choice(.refused) = error else { throw Unexpected() } }
        do {
            _ = try start.choice(-1)
            Issue.record("the selected edge did not reject")
        } catch { guard case .accept(.negative) = error else { throw Unexpected() } }
        do {
            try local.send(.pick(-1))
            Issue.record("send admitted a rejected edge")
        } catch { guard case .preparation(.accept(.negative)) = error else { throw Unexpected() } }

        switch PickFlow.owned(.init()).choice(13) {
        case .rejected(.refused, _): break
        default: Issue.record("an owned typed call bypassed the router")
        }
        switch PickFlow.owned(.init()).choice(-1) {
        case .accept(.rejected(.negative, _)): break
        default: Issue.record("the selected owned edge did not return its source")
        }
        switch PickFlow.owned(.init()).choice(0) {
        case .stay: break
        default: Issue.record("the router's choice was not taken")
        }
        switch PickFlow.owned(.init()).choice(5) {
        case .accept(.advanced(let done, let effects)):
            #expect(done.withValue { $0.value } == 5)
            #expect(effects.isEmpty)
        default: Issue.record("the selected owned edge did not advance")
        }
    }
}

@StateMachine(mode: .shared)
nonisolated private enum Tally: Sendable {
    struct Counting: Sendable { let total: Int }
    @Initial case counting(Counting = makeCounting())
    enum Input: Sendable { case append(Int) }
    static func makeCounting() -> Counting { Counting(total: 0) }
    @Transition(on: Input.append)
    fileprivate static func append(_ source: Counting, _ value: Int) -> Counting {
        Counting(total: source.total + value)
    }
}

/// A graph without operations has no commands to drain, so its owners admit without limit.
@Suite(.timeLimit(.minutes(1))) struct OperationFreeOwnerTests {
    private struct Unexpected: Error {}
    private static let sends = 1_000

    @Test func aLocalOwnerAdmitsAnUnboundedRunOfSendsWithoutDraining() throws {
        var local = Tally.Local()
        var receipts: [UInt64] = []
        for value in 1 ... Self.sends { receipts.append(try local.send(.append(value)).revision) }
        #expect(receipts == Array(1 ... UInt64(Self.sends)))
        guard case .counting(let counting) = local.snapshot() else { throw Unexpected() }
        #expect(counting.value.total == Self.sends * (Self.sends + 1) / 2)
        #expect(local.close().revision == UInt64(Self.sends) + 1)
    }

    /// Plain edits start and cancel nothing, so a graph that declares an operation still admits any
    /// number of them; the first batch the owner queues carries the start.
    @Test func aLocalOwnerQueuesOnlyBatchesThatCarryACommand() throws {
        var note = GeneratedNote.Local()
        for value in 1 ... Self.sends { try note.send(.edit("draft \(value)")) }
        let started = try note.send(.save)
        let batches = note.drainCommands(limit: 8)
        #expect(batches.map(\.receipt.revision) == [started.revision])
        guard batches.first?.commands.count == 1, case .save(let work)? = batches.first?.commands.first else {
            throw Unexpected()
        }
        #expect(work.input.text == "draft \(Self.sends)")
        // Editing the saving draft cancels the save, so that batch is queued too.
        let cancelled = try note.send(.edit("again"))
        let cancellation = note.drainCommands(limit: 8)
        #expect(cancellation.map(\.receipt.revision) == [cancelled.revision])
        guard cancellation.first?.commands.count == 1, case .cancel(let execution)? = cancellation.first?.commands.first
        else { throw Unexpected() }
        #expect(execution == work.execution)
        #expect(note.acknowledgeExecution(work.execution, disposition: .skippedBeforeStart) == .recorded)
        let closed = note.close()
        let terminal = note.drainCommands(limit: 8)
        #expect(terminal.map(\.receipt.revision) == [closed.revision])
        #expect(terminal.first?.terminal == true)
        let quiescent = note.isQuiescent
        #expect(quiescent)
    }

    /// A managed owner drains its own batches to publish snapshots, so its queue still bounds a burst.
    @Test func managedOwnersTakeNoDriversOrDeliveryPolicy() async throws {
        let shared = Tally.Shared()
        for value in 1 ... 10 { try shared.send(.append(value)) }
        #expect(shared.snapshot().revision == 10)
        await shared.shutdown()
        #expect(shared.isQuiescent)
        let actor = Tally.ActorHost()
        for value in 1 ... 10 { try await actor.send(.append(value)) }
        #expect(await actor.snapshot().revision == 10)
        await actor.shutdown()
        #expect(await actor.isQuiescent)
    }
}
