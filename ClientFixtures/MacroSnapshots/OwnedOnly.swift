import StateMachine

@StateMachine(mode: .ownedOnly)
nonisolated enum UniqueCounter: ~Copyable {
    struct Idle: ~Copyable { var value: Int = 0 }
    struct Done: ~Copyable { let value: Int }
    @Initial case idle(Idle = .init())
    case done(Done)
    enum Input { case finish(Bool) }
    enum Rejection: Error { case declined }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: consuming Idle, _ accept: Bool) -> Advance<Idle, Done, Never, Rejection> {
        if accept { return .advanced(Done(value: source.value), effects: []) }
        return .rejected(.declined, source)
    }
}

