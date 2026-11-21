// A bare Type where no period precedes it names the escaped alias `Type`, as Swift reads it.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Probe: Sendable {
    typealias `Type` = Swift::Never
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go, stop }
    @Operation(activeIn: [Running.self])
    enum Push { typealias Failure = Type }
    @Transition(on: Input.go, starts: [Push.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.push]) }
    @Transition(onSuccess: Push.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Running) throws(Type) -> Idle { Idle() }
}
func drive() { _ = Probe.Shared(Probe.Idle(), pushDriver: {}) }
