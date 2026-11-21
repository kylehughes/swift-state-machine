// An Input that names Never through an alias declared outside the schema fails the generated probe.
import StateMachine
/// An alias the macro cannot see.
typealias Outside = Swift::Never
@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {

    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go, stop }
    @Operation(activeIn: [Running.self])
    enum Load { typealias Input = Outside }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: []) }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Running) -> Idle { Idle() }
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
}
