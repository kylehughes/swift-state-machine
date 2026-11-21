// A bare Error is read as a type with values; a file-scope alias of Never under that name fails the probe.
import StateMachine

typealias Error = Swift::Never

@StateMachine(mode: .shared)
nonisolated enum Sync: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case start }
    @Operation(activeIn: [Running.self])
    enum Push { typealias Input = Error }
    @Event enum Started {}
    @Transition(on: Input.start, starts: [Push.self], emits: [Started.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.started])
    }
    @Transition(onSuccess: Push.self)
    fileprivate static func pushed(_ source: Running) -> Idle { Idle() }
}
