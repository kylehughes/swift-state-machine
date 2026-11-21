// A schema named Outcome would be captured by PendingCompletion's nested Outcome.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Outcome: Sendable {

    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go, stop, restart }
    @Operation(activeIn: [Running.self])
    enum Outcome { typealias Output = Int }
    @Operation(activeIn: [Running.self])
    enum Rejection { typealias Output = Int }
    @Operation(activeIn: [Running.self])
    enum Load {}
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load]) }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Running) -> Idle { Idle() }
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
    @Transition(onSuccess: Outcome.self)
    fileprivate static func outcome(_ source: Running, _ value: Int) -> Idle { Idle() }
    @Transition(onSuccess: Rejection.self)
    fileprivate static func rejection(_ source: Running, _ value: Int) -> Idle { Idle() }
    @Transition(on: Input.restart, starts: [Outcome.self, Rejection.self])
    fileprivate static func restart(_ source: Idle) -> Change<Running, Effect.Restart> { Change(Running(), effects: [.outcome, .rejection]) }
}
