import StateMachine

// `choose` and `Choose` would both generate Route.Choose.
@StateMachine(mode: .shared)
nonisolated enum Picker: Sendable {
    struct Idle: Sendable {}
    struct Busy: Sendable {}
    @Initial case idle(Idle)
    case busy(Busy)
    enum Input: Sendable { case go, back }
    @Transition(on: Input.go)
    fileprivate static func left(_ source: Idle) -> Busy { Busy() }
    @Transition(on: Input.go)
    fileprivate static func right(_ source: Idle) -> Busy { Busy() }
    @Route(on: Input.go)
    fileprivate static func choose(_ source: Idle) -> Route.Choose { .left }
    @Transition(on: Input.back)
    fileprivate static func up(_ source: Busy) -> Idle { Idle() }
    @Transition(on: Input.back)
    fileprivate static func down(_ source: Busy) -> Busy { source }
    @Route(on: Input.back)
    fileprivate static func Choose(_ source: Busy) -> Route.Choose { .up }
}
