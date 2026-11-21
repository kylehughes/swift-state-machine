// A Failure spelled through an alias of Never the schema declares cannot fail and needs no failure edge.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Sync: Sendable {
    typealias Problem = Swift.Never
    struct Idle: Sendable {}
    struct Running: Sendable {}
    struct Failed: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    @Terminal case failed(Failed)
    enum Input: Sendable { case start, abandon }
    @Operation(activeIn: [Running.self])
    enum Push { typealias Failure = Problem }
    @Transition(on: Input.start, starts: [Push.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(), effects: [.push])
    }
    @Transition(onSuccess: Push.self)
    fileprivate static func pushed(_ source: Running) -> Idle { Idle() }
    @Transition(on: Input.abandon)
    fileprivate static func abandon(_ source: Running) -> Failed { Failed() }
}
