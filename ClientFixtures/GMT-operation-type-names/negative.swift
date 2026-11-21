// `Pending`'s completion would be `PendingCompletion`, the type of a retained outcome.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Inbox: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case go }
    @Operation(activeIn: [Idle.self])
    enum Pending {}
    @Transition(on: Input.go, starts: [Pending.self])
    fileprivate static func go(_ source: Idle) -> Change<Idle, Effect.Go> { Change(source, effects: [.pending]) }
    @Transition(onSuccess: Pending.self)
    fileprivate static func done(_ source: Idle) -> Idle { source }
}
