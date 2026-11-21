// A module selector names the module, so Swift::Never is the standard library's and the operation cannot fail.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Sync: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case start }
    @Operation(activeIn: [Running.self])
    enum Push {
        enum Swift { enum Never: Error { case broken } }
        typealias Failure = Swift::Never
    }
    @Transition(on: Input.start, starts: [Push.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.push])
    }
    @Transition(onSuccess: Push.self)
    fileprivate static func pushed(_ source: Running) -> Idle { Idle() }
    @Transition(onFailure: Push.self)
    fileprivate static func broke(_ source: Running, _ failure: Push.Failure) -> Idle { Idle() }
}
