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
    enum Effect: Sendable {}
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: borrowing Idle, _ value: Int) -> Change<Done, Effect> {
        Change(Done(value: value + source.value.count))
    }
}

