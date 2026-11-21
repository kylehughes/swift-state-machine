// The failure edge says the operation can fail, and the Failure names Never through an alias declared outside the
// schema, which a generated probe rejects.
import StateMachine

/// An alias the macro cannot see.
typealias Problem = Never

@StateMachine(mode: .shared)
nonisolated enum Sync: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case start }
    @Operation(activeIn: [Running.self])
    enum Push { typealias Failure = Problem }
    @Transition(on: Input.start, starts: [Push.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.push])
    }
    @Transition(onSuccess: Push.self)
    fileprivate static func pushed(_ source: Running) -> Idle { Idle() }
    @Transition(onFailure: Push.self)
    fileprivate static func broke(_ source: Running, _ failure: Problem) -> Idle { Idle() }
}
