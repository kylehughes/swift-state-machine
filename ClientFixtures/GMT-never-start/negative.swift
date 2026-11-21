// No value of Never exists, so no transition can construct this operation's start.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Sync: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case go }
    @Operation(activeIn: [Idle.self])
    enum Upload { typealias Key = Swift.Never }
    @Transition(on: Input.go, starts: [Upload.self])
    fileprivate static func go(_ source: Idle) -> Change<Idle, Effect.Go> { Change(source, effects: []) }
    @Transition(onSuccess: Upload.self)
    fileprivate static func uploaded(_ source: Idle) -> Idle { source }
}
