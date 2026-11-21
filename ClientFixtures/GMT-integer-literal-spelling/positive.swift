// An admission limit is an integer literal, read as Swift reads one, with separators or in another base.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    struct Busy: Sendable {}
    @Initial case idle(Idle)
    case busy(Busy)
    enum Input: Sendable { case go, stop }
    @Operation(activeIn: [Busy.self], admission: .parallel(limit: 1_0))
    enum Work { typealias Key = Int }
    @Operation(activeIn: [Busy.self], admission: .parallel(limit: 0x2))
    enum Check { typealias Key = Int }
    @Transition(on: Input.go, starts: [Work.self, Check.self])
    fileprivate static func go(_ source: Idle) -> Change<Busy, Effect.Go> { Change(Busy(), effects: []) }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Busy) -> Idle { Idle() }
    @Transition(onSuccess: Work.self)
    fileprivate static func worked(_ source: Busy) -> Busy { source }
    @Transition(onSuccess: Check.self)
    fileprivate static func checked(_ source: Busy) -> Busy { source }
}

func limits() -> [String] {
    Flow.graph.operations.map { "\($0.admission)" }
}
