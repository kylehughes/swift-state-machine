import StateMachine
import Testing

/// An isolated graph whose input payload is a class nested in `Input`.
@StateMachine(mode: .isolated)
nonisolated private enum Lookup {
    struct Idle { var queries: [String] = [] }
    @Initial case idle(Idle = Idle())
    enum Input {
        /// An immutable request object.
        final class Request {
            let query: String
            init(query: String) { self.query = query }
        }
        case lookup(Request)
    }
    @Transition(on: Input.lookup)
    fileprivate static func lookup(_ source: Idle, _ request: Input.Request) -> Idle {
        Idle(queries: source.queries + [request.query])
    }
}

@Suite struct NestedInputTypeTests {
    private struct Unexpected: Error {}

    @Test func aClassNestedInInputIsAnInputPayload() throws {
        var owner = Lookup.Local()
        try owner.send(.lookup(Lookup.Input.Request(query: "swift")))
        guard case .idle(let idle) = owner.snapshot() else { throw Unexpected() }
        #expect(idle.value.queries == ["swift"])
    }
}
