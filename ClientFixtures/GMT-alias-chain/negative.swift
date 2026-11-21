// An alias that names itself through another has no type, which the macro reports once a reading reaches it.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    typealias A = B
    typealias B = A
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go, stop }
    @Operation(activeIn: [Running.self])
    enum Load { typealias Output = A }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load]) }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Running) -> Idle { Idle() }
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running, _ value: Load.Output) -> Idle { Idle() }
}
