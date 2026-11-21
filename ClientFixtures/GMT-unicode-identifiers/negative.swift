// The macro reads a backticked emoji alias of Never as Never, so a failure edge for its operation can never run.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Garden: Sendable {
    typealias 🌱 = Swift::Never
    struct Idle: Sendable {}
    struct Growing: Sendable {}
    @Initial case idle(Idle)
    case growing(Growing)
    enum Input: Sendable { case plant }
    @Operation(activeIn: [Growing.self])
    enum Sprout { typealias Failure = `🌱` }
    @Transition(on: Input.plant, starts: [Sprout.self])
    fileprivate static func plant(_ source: Idle) -> Change<Growing, Effect.Plant> { Change(Growing(), effects: [.sprout]) }
    @Transition(onSuccess: Sprout.self)
    fileprivate static func sprouted(_ source: Growing) -> Idle { Idle() }
    @Transition(onFailure: Sprout.self)
    fileprivate static func wilted(_ source: Growing, _ failure: Never) -> Idle { Idle() }
}
