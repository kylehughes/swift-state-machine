// A key with values lets a transition start the work.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Sync: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case go }
    @Operation(activeIn: [Idle.self])
    enum Upload { typealias Key = Swift.Int }
    @Transition(on: Input.go, starts: [Upload.self])
    fileprivate static func go(_ source: Idle) -> Change<Idle, Effect.Go> { Change(source, effects: []) }
    @Transition(onSuccess: Upload.self)
    fileprivate static func uploaded(_ source: Idle) -> Idle { source }
}
