import StateMachine
import Testing

/// A search whose completion router and one of its edges read the query the work was started with.
@StateMachine(mode: .shared)
nonisolated private enum Lookup: Sendable {
    struct Searching: Sendable { let attempts: Int }
    struct Found: Sendable {
        let query: String
        let hits: Int
    }
    struct Missed: Sendable { let attempts: Int }
    @Initial case searching(Searching)
    @Terminal case found(Found)
    @Terminal case missed(Missed)
    enum Input: Sendable { case search(String) }
    @Operation(activeIn: [Searching.self], admission: .parallel(limit: 2))
    enum Query {
        typealias Input = String
        typealias Output = Int
    }
    @Transition(on: Input.search, starts: [Query.self])
    static func search(_ source: Searching, _ query: String) -> Change<Searching, Effect.Search> {
        Change(Searching(attempts: source.attempts + 1), effects: [.query(query)])
    }
    @Transition(onSuccess: Query.self)
    static func found(_ source: Searching, _ hits: Int, request: QueryRequest) -> Found {
        Found(query: request.input, hits: hits)
    }
    @Transition(onSuccess: Query.self)
    static func missed(_ source: Searching, _ hits: Int) -> Missed { Missed(attempts: source.attempts) }
    /// Accepts a result only for a nonempty query that found something.
    @Route(onSuccess: Query.self)
    static func judge(_ source: Searching, _ hits: Int, request: QueryRequest) -> Route.Judge {
        hits > 0 && !request.input.isEmpty ? .found : .missed
    }
}

@Suite struct CompletionRequestTests {
    private struct Unexpected: Error {}

    @Test func eachParallelResultIsJudgedAgainstItsOwnRequest() throws {
        var local = Lookup.Local(Lookup.Searching(attempts: 0))
        try local.send(.search(""))
        try local.send(.search("swift"))
        let works = local.drainCommands().flatMap(\.commands)
            .compactMap { command -> Lookup.QueryWork? in
                if case .query(let work) = command { work } else { nil }
            }
        #expect(works.map(\.request.input) == ["", "swift"])
        // Results return in reverse order, and each is judged with the query its own work started with.
        guard case .committed = local.deliver(works[1].succeeded(3)) else { throw Unexpected() }
        guard case .found(let found) = local.snapshot() else { throw Unexpected() }
        #expect(found.value.query == "swift")
        #expect(found.value.hits == 3)
        guard case .stale = local.deliver(works[0].succeeded(3)) else { throw Unexpected() }
    }

    @Test func theRouterReadsTheRequestWhenTheSameOutputWouldBeAccepted() throws {
        var local = Lookup.Local(Lookup.Searching(attempts: 0))
        try local.send(.search(""))
        guard case .query(let work)? = local.drainCommands().first?.commands.first else { throw Unexpected() }
        guard case .committed = local.deliver(work.succeeded(3)), case .missed(let missed) = local.snapshot() else {
            throw Unexpected()
        }
        #expect(missed.value.attempts == 1)
    }

    @Test func anOwnedPhasePassesAPlainRequestToTheRouterAndEdge() throws {
        let owned = Lookup.owned(Lookup.Searching(attempts: 0))
        switch owned.judge(2, request: Lookup.QueryRequest(input: "owned")) {
        case .found(let found): #expect(found.withValue { $0.query } == "owned")
        case .missed: Issue.record("The router ignored the request")
        }
    }
}
