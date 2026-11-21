// A file-scope Error that names a type with values passes the probe the macro emits for a bare standard name.
import StateMachine

typealias Error = Swift::String

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
        Change(Running(), effects: [.push("payload"), .started])
    }
    @Transition(onSuccess: Push.self)
    fileprivate static func pushed(_ source: Running) -> Idle { Idle() }
}
func check() { _ = Sync.Local(Sync.Idle()) }
