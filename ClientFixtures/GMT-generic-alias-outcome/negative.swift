// A failure edge of an operation whose Failure is Identity<Swift::Never> can never run.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    typealias Identity<T> = T
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go, stop }
    @Operation(activeIn: [Running.self])
    enum Load { typealias Failure = Identity<Swift::Never>; typealias Output = Identity<Swift::Void> }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load]) }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Running) -> Idle { Idle() }
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
    @Transition(onFailure: Load.self)
    fileprivate static func broke(_ source: Running, _ failure: Never) -> Idle { Idle() }
}
