// An event payload with values compiles.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case go }
    @Event enum Tracked { typealias Payload = Int }
    @Transition(on: Input.go, emits: [Tracked.self])
    fileprivate static func go(_ source: Idle) -> Change<Idle, Effect.Go> { Change(source, effects: []) }
}
