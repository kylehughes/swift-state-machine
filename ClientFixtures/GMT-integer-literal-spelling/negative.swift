// A limit of zero, in any base, admits no execution.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    struct Busy: Sendable {}
    @Initial case idle(Idle)
    case busy(Busy)
    enum Input: Sendable { case go, stop }
    @Operation(activeIn: [Busy.self], admission: .parallel(limit: 0x0))
    enum Work { typealias Key = Int }
    @Transition(on: Input.go, starts: [Work.self])
    fileprivate static func go(_ source: Idle) -> Change<Busy, Effect.Go> { Change(Busy(), effects: []) }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Busy) -> Idle { Idle() }
    @Transition(onSuccess: Work.self)
    fileprivate static func worked(_ source: Busy) -> Busy { source }
}
