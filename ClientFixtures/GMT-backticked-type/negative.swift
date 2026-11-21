// The escaped alias `Type` names a type with values, but without a failure edge the operation reads as one that cannot
// fail, which the expansion checks on its Failure.
import StateMachine

public struct Problem: Error, Sendable {}

@StateMachine(mode: .shared)
nonisolated enum Probe: Sendable {
    typealias `Type` = Problem
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go }
    @Operation(activeIn: [Running.self])
    enum Push { typealias Failure = Type }
    @Transition(on: Input.go, starts: [Push.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.push]) }
    @Transition(onSuccess: Push.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
}
