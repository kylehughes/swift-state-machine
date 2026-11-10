import StateMachine
import StateMachineSchema

@StateMachine(mode: .shared)
nonisolated enum Counter: Sendable {
    struct Idle: Sendable { let value: [String: [Int?]] }
    struct Done: Sendable { let value: Int }
    @Initial case idle(Idle)
    case done(Done)
    struct _StateMachineLedger {}
    enum Input: Sendable { case finish(Int) }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Idle, _ value: Int) -> Done {
        Done(value: value + source.value.count)
    }
}

