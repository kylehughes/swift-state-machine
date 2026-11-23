// Passing a @PhaseSet enum to from: selects the single-metatype overload and compiles cleanly.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum BarePhaseControl: Sendable {
    struct Idle: Sendable {}
    struct Active: Sendable {}
    @Initial case idle(Idle = Idle())
    case active(Active)
    enum Input: Sendable { case activate, reset }
    @PhaseSet([Idle.self, Active.self])
    fileprivate enum Resettable {}
    @Transition(on: Input.activate)
    fileprivate static func activate(_ source: Idle) -> Active { Active() }
    @Transition(from: Resettable.self, on: Input.reset)
    fileprivate static func reset() -> Idle { Idle() }
}
