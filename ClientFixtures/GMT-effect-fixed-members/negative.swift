// With an operation, Local's Command cancels work through its own cancel case.
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
    @Operation(activeIn: [Idle.self])
    enum Play {}
    @Transition(on: Input.play, starts: [Play.self])
    fileprivate static func play(_ source: Idle) -> Change<Idle, Effect.Play> { Change(source, effects: [.play]) }
    @Transition(onSuccess: Play.self)
    fileprivate static func played(_ source: Idle) -> Idle { source }
}
