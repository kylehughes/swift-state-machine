// Swift reads a built-in attribute's name and an argument's label the same with backticks, and so does the macro.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    struct Busy: Sendable {}
    @Initial case idle(Idle)
    case busy(Busy)
    enum Input: Sendable { case go, run(@Sendable () -> Int) }
    @Operation(activeIn: [Busy.self], admission: .`parallel`(limit: 2))
    enum Load {}
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Busy, Effect.Go> { Change(Busy(), effects: [.load]) }
    @`discardableResult`
    @Transition(on: Input.run)
    fileprivate static func run(_ source: Idle, _ value: @`escaping` @Sendable () -> Int) -> Idle { source }
    @Transition(onSuccess: Load.self)
    fileprivate static func loaded(_ source: Busy) -> Idle { Idle() }
}
