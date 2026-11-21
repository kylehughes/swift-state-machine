import StateMachine
import Testing

/// A graph whose edges, router, and restoration function are deprecated.
///
/// It compiles with warnings as errors, because generated code calls each deprecated function through a
/// requirement it witnesses.
@StateMachine(mode: .shared)
nonisolated private enum Retired: Sendable {
    struct Idle: Sendable { var count = 0 }
    struct Done: Sendable {}
    enum Problem: Error, Equatable { case negative }
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input: Sendable {
        case add(Int)
        case pick
        case finish
    }
    @available(*, deprecated, renamed: "finish")
    @Transition(on: Input.add)
    static func add(_ source: Idle, _ value: Int) throws(Problem) -> Idle {
        guard value >= 0 else { throw .negative }
        return Idle(count: source.count + value)
    }
    @Transition(on: Input.finish)
    static func finish(_ source: Idle) -> Done { Done() }
    @available(*, deprecated, message: "Send finish instead.")
    @Route(on: Input.pick)
    static func pick(_ source: Idle) -> Route.Pick { source.count > 0 ? .close : .keep }
    @Transition(on: Input.pick)
    static func keep(_ source: Idle) -> Idle { source }
    @available(*, deprecated)
    @Transition(on: Input.pick)
    static func close(_ source: Idle) -> Done { Done() }
    @available(*, deprecated, message: "Restore the current archive.")
    @Restoration
    static func restore(_ saved: Int) throws(Problem) -> Restoration {
        guard saved >= 0 else { throw .negative }
        return .idle(Idle(count: saved))
    }
}

private struct Unexpected: Error {}

struct DeprecatedFunctionTests {
    /// Inputs reach deprecated edges and routers through the owner's own entry points, which name nothing
    /// deprecated, and a refusal keeps its typed failure.
    @Test func inputsReachDeprecatedFunctions() throws {
        let flow = Retired.Shared(Retired.Idle())
        _ = try flow.send(.add(2))
        guard case .idle(let idle) = flow.snapshot(), idle.value.count == 2 else { throw Unexpected() }
        #expect(throws: Retired.SendRejection.self) { try flow.send(.add(-1)) }
        _ = try flow.send(.pick)
        guard case .done = flow.snapshot() else { throw Unexpected() }
    }

    /// A deprecated caller may use the generated members that repeat the deprecations.
    @available(*, deprecated)
    @Test func deprecatedMembersStillWork() throws {
        guard case .advanced(let next, _) = Retired.Owned(Retired.Idle()).add(3) else { throw Unexpected() }
        _ = next.pick()
        guard case .idle(let idle) = try Retired.Shared(restoring: 4).snapshot(), idle.value.count == 4 else {
            throw Unexpected()
        }
        #expect(throws: Retired.Problem.negative) { try Retired.Shared(restoring: -1) }
    }
}
