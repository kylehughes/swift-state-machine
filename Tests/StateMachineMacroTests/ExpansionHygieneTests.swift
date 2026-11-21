import StateMachine
import Testing

/// An input payload whose tuple type spans lines.
@StateMachine(mode: .shared)
nonisolated private enum Pairs {
    struct Idle: Sendable { var sum = 0 }
    @Initial case idle(Idle = Idle())
    enum Input: Sendable {
        case pair(
            (
                Int,
                Int
            )
        )
    }
    @Transition(on: Input.pair)
    static func pair(
        _ source: Idle,
        _ value: (
            Int,
            Int
        )
    ) -> Idle { Idle(sum: source.sum + value.0 + value.1) }
}

/// An input payload spelled through `Self` inside `Input`, and edges whose payloads and requests are
/// spelled through `Self` inside the schema.
@StateMachine(mode: .isolated)
nonisolated private enum SelfSpelled {
    struct Idle { var queries: [String] = [] }
    struct Busy {}
    @Initial case idle(Idle = Idle())
    case busy(Busy)
    enum Input {
        final class Request {
            let query: String
            init(query: String) { self.query = query }
        }
        case lookup(Self.Request)
        case fetch(Int)
    }
    struct Problem: Error {}
    @Operation(activeIn: [Busy.self])
    enum Fetch {
        typealias Input = Int
        typealias Output = String
        typealias Failure = Problem
    }
    @Transition(on: Input.lookup)
    static func lookup(_ source: Idle, _ request: Self.Input.Request) -> Idle {
        Idle(queries: source.queries + [request.query])
    }
    @Transition(on: Input.fetch, starts: [Fetch.self])
    static func fetch(_ source: Idle, _ value: Int) -> Change<Busy, Effect.Fetch> {
        Change(Busy(), effects: [.fetch(value)])
    }
    @Transition(onSuccess: Fetch.self)
    static func fetched(
        _ source: Busy,
        _ output: Self.Fetch.Output,
        request: Self.FetchRequest
    ) throws(Self.Problem)
        -> Idle
    { Idle(queries: ["\(request.input): \(output)"]) }
    @Transition(onFailure: Fetch.self)
    static func failed(_ source: Busy, _ failure: Self.Problem) -> Idle { Idle() }
}

/// A routed completion candidate named `request` that takes the request, beside an input candidate
/// named `input`.
@StateMachine(mode: .shared)
nonisolated private enum Named {
    struct Idle: Sendable { var last = 0 }
    struct Busy: Sendable {}
    @Initial case idle(Idle = Idle())
    case busy(Busy)
    enum Input: Sendable {
        case go(Int)
        case pick(Int)
    }
    @Operation(activeIn: [Busy.self])
    enum Fetch { typealias Input = Int }
    @Transition(on: Input.go, starts: [Fetch.self])
    static func go(_ source: Idle, _ value: Int) -> Change<Busy, Effect.Go> { Change(Busy(), effects: [.fetch(value)]) }
    @Transition(on: Input.pick)
    static func input(_ source: Idle, _ value: Int) -> Idle { Idle(last: value) }
    @Transition(on: Input.pick)
    static func ignore(_ source: Idle, _ value: Int) -> Idle { source }
    @Route(on: Input.pick)
    static func choose(_ source: Idle, _ value: Int) -> Route.Choose { value > 0 ? .input : .ignore }
    @Transition(onSuccess: Fetch.self)
    static func request(_ source: Busy, request: FetchRequest) -> Idle { Idle(last: request.input) }
    @Transition(onSuccess: Fetch.self)
    static func stay(_ source: Busy, request: FetchRequest) -> Busy { source }
    @Route(onSuccess: Fetch.self)
    static func settle(_ source: Busy, request: FetchRequest) -> Route.Settle {
        request.input > 0 ? .request : .stay
    }
}

/// A schema whose own types take the names of the runtime types its expansion uses.
@StateMachine(mode: .isolated)
nonisolated private enum Shadowing {
    struct RuntimeIsolatedHost {}
    struct RuntimeMainActorHost {}
    struct RuntimeState {}
    struct RuntimeTicket {}
    struct RuntimeScopeID {}
    struct RuntimeOperation {}
    struct RuntimeKey {}
    struct RuntimeDeliveryClaim {}
    struct RuntimeDeliveryLedger {}
    struct RuntimeHostDelivery {}
    struct RuntimeCompletionPolicy {}
    struct RuntimePendingID {}
    struct PlanRejection {}
    struct MainActorStateMachineHost {}
    struct StateMachineSnapshot {}
    struct StateMachineReceipt {}
    struct Limits {}
    struct ManagedConfiguration {}
    struct Idle {}
    struct Busy {}
    @Initial case idle(Idle = Idle())
    case busy(Busy)
    enum Input { case go(Int) }
    @Operation(activeIn: [Busy.self])
    enum Fetch { typealias Key = Int }
    @Transition(on: Input.go, starts: [Fetch.self])
    static func go(_ source: Idle, _ key: Int) -> Change<Busy, Effect.Go> {
        Change(Busy(), effects: [.fetch(key: key)])
    }
    @Transition(onSuccess: Fetch.self)
    static func done(_ source: Busy) -> Idle { Idle() }
}

/// An `Owned`-only selection whose phase takes a name that only `Snapshot` would reserve.
@StateMachine(mode: .shared, owners: [.owned])
nonisolated private enum Modeled {
    struct Ready: Sendable {}
    @Initial @Terminal case model(Ready = Ready())
    enum Input: Sendable {}
}

/// Payload spellings whose names an extension of `Input`, or a namespace's own member, binds to another type
/// than the schema's declaration of that name does.
@StateMachine(mode: .shared)
nonisolated private enum Bound {
    typealias Detail = Swift::String
    struct Idle: Sendable { var total = 0 }
    @Initial case idle(Idle = Idle())
    enum Input: Sendable { case add(Detail) }
    @Event
    enum Logged {
        struct Detail: Sendable { let count: Int }
        typealias Payload = Detail
    }
    @Transition(on: Input.add, emits: [Logged.self])
    static func add(_ source: Idle, _ value: Swift::Int) -> Change<Idle, Effect.Add> {
        Change(Idle(total: source.total + value), effects: [.logged(Logged.Detail(count: value))])
    }
}

extension Bound.Input {
    typealias Detail = Swift::Int
}

/// Throwing functions of one name from two phases with different failures, so their rejection cases are
/// told apart by phase, and a throwing router without candidates.
@StateMachine(mode: .shared)
nonisolated private enum Refusing {
    struct Low: Error {}
    struct High: Error {}
    struct Draft: Sendable {}
    struct Review: Sendable {}
    @Initial case draft(Draft = Draft())
    case review(Review)
    enum Input: Sendable {
        case edit(Int)
        case hold
    }
    @Transition(on: Input.edit)
    static func edit(_ source: Draft, _ value: Int) throws(Low) -> Review {
        guard value > 0 else { throw Low() }
        return Review()
    }
    @Transition(on: Input.edit)
    static func edit(_ source: Review, _ value: Int) throws(High) -> Review { throw High() }
    @Route(on: Input.hold)
    static func hold(_ source: Draft) throws(Low) -> Never { throw Low() }
}

@Suite struct ExpansionHygieneTests {
    /// `Local` names the router or edge whose authored function refused an input, as the graph identifies it.
    @Test func localNamesTheRouteThatRefusedAnInput() throws {
        var owner = Refusing.Local()
        let ids = Set(Refusing.graph.edges.map(\.id) + Refusing.graph.routers.map(\.id))
        func refusal(_ input: Refusing.Input) -> String?? {
            let phase = Refusing.Local.phase(of: owner.snapshot())
            do throws(Refusing.SendRejection) {
                try owner.send(input)
                return .none
            } catch {
                return .some(Refusing.Local.rejectingRoute(of: error, in: phase))
            }
        }
        #expect(refusal(.edit(0)) == .some("draft.edit"))
        #expect(refusal(.hold) == .some("draft.hold"))
        #expect(refusal(.edit(1)) == .none)
        #expect(refusal(.hold) == .some(nil))
        #expect(refusal(.edit(1)) == .some("review.edit"))
        #expect(ids.isSuperset(of: ["draft.edit", "draft.hold", "review.edit"]))
    }

    /// The graph shows each payload as the author spelled it, which means what it means where it is written:
    /// inside `Input`, where an extension of `Input` declares `Detail`, and inside the event's namespace.
    @Test func graphSpellingsMeanWhatTheyMeanWhereTheyAreWritten() throws {
        var owner = Bound.Local()
        try owner.send(.add(3))
        guard case .logged(let detail)? = owner.drainCommands().first?.commands.first else { throw Unexpected() }
        #expect(detail.count == 3)
        #expect(Bound.graph.inputs.map(\.payload) == ["Detail"])
        #expect(Bound.graph.events.map(\.payload) == ["Detail"])
    }

    private struct Unexpected: Error {}

    @Test func aTypeSpanningLinesIsOneGraphLiteral() throws {
        #expect(Pairs.graph.inputs.map(\.payload) == ["(Int, Int)"])
        var owner = Pairs.Local()
        try owner.send(.pair((1, 2)))
        guard case .idle(let idle) = owner.snapshot() else { throw Unexpected() }
        #expect(idle.value.sum == 3)
    }

    @Test func selfKeepsItsLexicalMeaningInGeneratedMembers() throws {
        var owner = SelfSpelled.Local()
        try owner.send(.lookup(SelfSpelled.Input.Request(query: "swift")))
        guard case .idle(let idle) = owner.snapshot() else { throw Unexpected() }
        #expect(idle.value.queries == ["swift"])
        // The graph shows the payload as the author spelled it, which means what it means inside `Input`.
        #expect(SelfSpelled.graph.inputs.first?.payload == "Self.Request")
    }

    @Test func routedCandidatesAreCalledOnTheirPhase() throws {
        let positive = Named.owned().go(3)
        guard case .request(let idle) = positive.next.settle(request: Named.FetchRequest(input: 4)) else {
            throw Unexpected()
        }
        #expect(idle.takeValue().last == 4)
        let zero = Named.owned().go(3)
        guard case .stay = zero.next.settle(request: Named.FetchRequest(input: 0)) else { throw Unexpected() }
        #expect(Named.owned().choose(5).takeValue().last == 5)
    }

    @Test func authoredTypesDoNotShadowTheRuntime() throws {
        var owner = Shadowing.Local()
        try owner.send(.go(1))
        #expect(Shadowing.graph.phases.map(\.id) == ["idle", "busy"])
    }

    @Test func anOwnedOnlySelectionMayNameAPhaseModel() {
        _ = Modeled.owned()
        #expect(Modeled.graph.phases.map(\.id) == ["model"])
    }
}
