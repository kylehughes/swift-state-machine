// Passing a bare phase payload to from: routes to a targeted macro diagnostic instead of overload ambiguity.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum BarePhaseMisuse: Sendable {
    struct Idle: Sendable {}
    struct Active: Sendable {}
    @Initial case idle(Idle = Idle())
    case active(Active)
    enum Input: Sendable { case activate, reset }
    @Transition(on: Input.activate)
    fileprivate static func activate(_ source: Idle) -> Active { Active() }
    @Transition(from: Idle.self, on: Input.reset)
    fileprivate static func reset() -> Idle { Idle() }
}
