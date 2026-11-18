import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Counter: Sendable {
    struct Idle<Element: Sendable>: Sendable { let value: [String: [Int?]] }
    struct Done: Sendable { let value: Int }
    @Initial case idle(Idle<Int>)
    case done(Done)
    enum Input: Sendable { case finish(Int) }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Idle<Int>, _ value: Int) -> Done {
        Done(value: value + source.value.count)
    }
}

