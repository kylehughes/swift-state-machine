import StateMachine
import StateMachineSchema

@StateMachine(mode: .ownedOnly)
nonisolated enum UniqueCounter: ~Copyable {
    struct Idle: ~Copyable { let value: Int }
    struct Done: ~Copyable { let value: Int }
    @Initial case idle(Idle)
    case done(Done)
    enum Input { case finish(Bool) }
    enum Effect {}
    enum Rejection: Error { case declined }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: consuming Idle, _ accept: Bool) -> Advance<Idle, Done, Effect, Rejection> {
        if accept { return .advanced(Done(value: source.value), effects: []) }
        return .rejected(.declined, source)
    }
}

