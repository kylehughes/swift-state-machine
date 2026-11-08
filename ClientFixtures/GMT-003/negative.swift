import StateMachine
import StateMachineSchema

@StateMachine(mode: .shared, initial: "idle", scopes: [])
nonisolated enum Counter: Sendable {
    struct Idle: Sendable { let value: [String: [Int?]] }
    struct Done: Sendable { let value: Int }
    case idle(Idle)
    case done(Done)
    enum Input: Sendable { case finish(Int) }
    enum Effect: Sendable {}
    @Transition(from: "idle", to: "done", on: .input("finish"))
    fileprivate static func finish(_ source: borrowing Any, _ value: Int) -> Change<Done, Effect> {
        Change(Done(value: value))
    }
}

