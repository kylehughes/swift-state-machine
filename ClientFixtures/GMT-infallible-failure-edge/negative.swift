// An operation whose Failure is Never never fails, so its failure edge is the only, impossible, entrance to Failed.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    struct Failed: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    @Terminal case failed(Failed)
    enum Input: Sendable { case start }
    @Operation(activeIn: [Running.self])
    enum Fetch { typealias Failure = Swift::Never }
    @Transition(on: Input.start, starts: [Fetch.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.fetch])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
    @Transition(onFailure: Fetch.self)
    fileprivate static func failed(_ source: Running, _ failure: Swift::Never) -> Failed { Failed() }
}
