// A fallible operation's failure edge can enter the terminal phase.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    enum Problem: Swift.Error, Sendable { case offline }
    struct Idle: Sendable {}
    struct Running: Sendable {}
    struct Failed: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    @Terminal case failed(Failed)
    enum Input: Sendable { case start }
    @Operation(activeIn: [Running.self])
    enum Fetch { typealias Failure = Problem }
    @Transition(on: Input.start, starts: [Fetch.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.fetch])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
    @Transition(onFailure: Fetch.self)
    fileprivate static func failed(_ source: Running, _ failure: Fetch.Failure) -> Failed { Failed() }
}
