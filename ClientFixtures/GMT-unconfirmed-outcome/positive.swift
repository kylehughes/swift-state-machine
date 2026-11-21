// The namespace reads the schema's alias of Never as its Failure, which its own extension takes, and the failure edge
// says the operation can fail, so the macro treats it as fallible and checks that its Failure is no Never.
import StateMachine

enum LoadError: Error, Sendable { case offline }

@StateMachine(mode: .shared)
nonisolated enum Pull: Sendable {
    typealias Problem = Swift::Never
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
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> { Change(Running(), effects: [.fetch]) }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
    @Transition(onFailure: Fetch.self)
    fileprivate static func failed(_ source: Running, _ failure: LoadError) -> Failed { Failed() }
}
extension Pull.Fetch { typealias Problem = LoadError }
