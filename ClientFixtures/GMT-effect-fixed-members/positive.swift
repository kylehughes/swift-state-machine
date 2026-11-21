// Without operations, Local's Command has no cancel case and no Completion exists, so events named Cancel and Authority are free.
import StateMachine

@StateMachine(mode: .shared, owners: [.local])
nonisolated enum Recorder: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case stop, play }
    @Event enum Cancel {}
    @Event enum Authority {}
    @Transition(on: Input.stop, emits: [Cancel.self, Authority.self])
    fileprivate static func stop(_ source: Idle) -> Change<Idle, Effect.Stop> {
        Change(source, effects: [.cancel, .authority])
    }
}
