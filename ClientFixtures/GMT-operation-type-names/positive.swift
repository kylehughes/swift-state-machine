// An operation whose completion type is free generates it.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Inbox: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case go }
    @Operation(activeIn: [Idle.self])
    enum Fetch {}
    @Transition(on: Input.go, starts: [Fetch.self])
    fileprivate static func go(_ source: Idle) -> Change<Idle, Effect.Go> { Change(source, effects: [.fetch]) }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func done(_ source: Idle) -> Idle { source }
}
