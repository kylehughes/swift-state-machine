// Without a failure edge the operation reads as one that cannot fail, which the expansion checks: its Failure has values.
import StateMachine

public struct Offline: Swift::Error, Swift::Sendable {}

@StateMachine(mode: .shared)
nonisolated enum Pull: Sendable {
    typealias Problem = Offline
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go }
    @Operation(activeIn: [Running.self])
    enum Fetch { typealias Failure = Problem }
    @Transition(on: Input.go, starts: [Fetch.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.fetch]) }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
}

