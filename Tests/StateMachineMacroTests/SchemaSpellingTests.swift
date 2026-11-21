import StateMachine
import Testing

@StateMachine(mode: .shared)
nonisolated private enum QualifiedMarkers: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable {}
    @StateMachine.Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input: Sendable { case finish }
    @StateMachine.Transition(on: Input.finish)
    fileprivate static func finish(_ source: Idle) -> Done { Done() }
}

@StateMachine(mode: .shared)
nonisolated private enum NestedPayload: Sendable {
    struct Value: Sendable { let total: Int }
    @Initial case value(Value)
    enum Input: Sendable {
        typealias Amount = Int
        struct Label: Sendable { let text: String }
        case add(Amount)
        case addAll([Amount])
        case rename(Label)
    }
    @Transition(on: Input.add)
    fileprivate static func add(_ source: Value, _ amount: Input.Amount) -> Value {
        Value(total: source.total + amount)
    }
    @Transition(on: Input.addAll)
    fileprivate static func addAll(_ source: Value, _ amounts: [Input.Amount]) -> Value {
        Value(total: source.total + amounts.reduce(0, +))
    }
    @Transition(on: Input.rename)
    fileprivate static func rename(_ source: Value, _ label: Input.Label) -> Value { source }
}

@StateMachine(mode: .shared)
nonisolated private enum QualifiedNever: Sendable {
    struct Idle: Sendable {}
    struct Busy: Sendable {}
    @Initial case idle(Idle)
    case busy(Busy)
    enum Scope {
        @Active(in: [Busy.self])
        case work
    }
    enum Input: Sendable { case go }
    @Operation(scope: Scope.work, admission: .latest)
    enum Work {
        typealias Input = Int
        typealias Output = Int
        typealias Failure = Swift.Never
    }
    @Transition(on: Input.go, starts: [Work.self])
    fileprivate static func go(_ source: Idle) -> Change<Busy, Effect.Go> { Change(Busy(), effects: [.work(1)]) }
    @Transition(onSuccess: Work.self)
    fileprivate static func done(_ source: Busy, _ output: Work.Output) -> Idle { Idle() }
}

/// Every marker, including the schema macro itself, may be qualified by the one module a graph imports.
@StateMachine.StateMachine(mode: .shared)
nonisolated private enum FullyQualified: Sendable {
    struct Idle: Sendable {}
    struct Busy: Sendable {}
    struct Done: Sendable { let value: Int }
    @StateMachine.Initial case idle(Idle = Idle())
    case busy(Busy)
    @Terminal case done(Done)
    enum Input: Sendable { case go(Int) }
    enum Refusal: Error, Sendable { case negative }
    @StateMachine.Operation(activeIn: [Busy.self])
    enum Work {
        typealias Input = Int
        typealias Output = Int
    }
    @StateMachine.Transition(on: Input.go, starts: [Work.self])
    fileprivate static func go(_ source: Idle, _ value: Int) -> StateMachine.Change<Busy, Effect.Go> {
        Change(Busy(), effects: [.work(value)])
    }
    @StateMachine.Transition(onSuccess: Work.self)
    fileprivate static func done(_ source: Busy, _ value: Work.Output) -> Done { Done(value: value) }
    @StateMachine.Transition(onSuccess: Work.self)
    fileprivate static func reset(_ source: Busy, _ value: Work.Output) -> Idle { Idle() }
    @StateMachine.Route(onSuccess: Work.self)
    fileprivate static func settle(_ source: Busy, _ value: Work.Output) -> Route.Settle {
        value > 0 ? .done : .reset
    }
}

/// Equivalent Swift spellings declare the same graph.
@Suite struct SchemaSpellingTests {
    @Test func moduleQualifiedMarkersDeclareTheEdge() throws {
        var machine = QualifiedMarkers.Local(.init())
        try machine.send(.finish)
        guard case .done = machine.snapshot() else {
            Issue.record("the qualified transition was not routed")
            return
        }
    }

    @Test func aFullyQualifiedGraphRoutesItsCompletion() throws {
        var machine = FullyQualified.Local()
        try machine.send(.go(2))
        guard case .work(let work)? = machine.drainCommands(limit: 1).first?.commands.first,
            case .committed = machine.deliver(work.succeeded(2)),
            case .done(let done) = machine.snapshot()
        else {
            Issue.record("the qualified graph did not route its completion")
            return
        }
        #expect(done.value.value == 2)
    }

    @MainActor @Test func aGraphWithoutOperationsNeedsNoDrivers() async throws {
        let main = QualifiedMarkers.MainActorHost(.init())
        try main.send(.finish)
        let shared = QualifiedMarkers.Shared(.init())
        try shared.send(.finish)
        let actor = QualifiedMarkers.ActorHost(.init())
        try await actor.send(.finish)
        if case .timedOut = await shared.shutdown() {
            Issue.record("A graph without operations has nothing to join")
        }
        await main.shutdown()
        await actor.shutdown()
    }

    @Test func inputPayloadsMayNameTypesNestedInInput() throws {
        var machine = NestedPayload.Local(.init(total: 1))
        try machine.send(.add(2))
        try machine.send(.addAll([3, 4]))
        try machine.send(.rename(.init(text: "sum")))
        guard case .value(let value) = machine.snapshot() else { return }
        #expect(value.value.total == 10)
    }

    @Test func anOwnedEdgeKeepsItsOwnEffectType() throws {
        let change: Change<QualifiedNever.Owned<QualifiedNever.Busy>, QualifiedNever.Effect.Go> =
            QualifiedNever.owned(.init()).go()
        for effect in change.effects {
            // The switch is exhaustive over what `go` can start, and widens explicitly.
            switch effect {
            case .work(let input): #expect(input == 1)
            }
            guard case .work = effect.effect else {
                Issue.record("the schema-wide effect did not match")
                return
            }
        }
        #expect(change.effects.count == 1)
    }

    @Test func moduleQualifiedNeverNeedsNoFailureEdge() throws {
        var machine = QualifiedNever.Local(.init())
        try machine.send(.go)
        guard case .work(let work)? = machine.drainCommands(limit: 1).first?.commands.first,
            case .committed = machine.deliver(work.succeeded(1))
        else {
            Issue.record("the infallible operation did not complete")
            return
        }
    }
}
