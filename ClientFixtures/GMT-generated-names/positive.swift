import StateMachine

// `pick` returns its candidates' common result, so it generates no Route.PickResult and `pickResult` is free.
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
    fileprivate static func pick(_ source: Idle) -> Route.Pick { .left }
    @Transition(on: Input.back)
    fileprivate static func up(_ source: Busy) -> Idle { Idle() }
    @Transition(on: Input.back)
    fileprivate static func down(_ source: Busy) -> Busy { source }
    @Route(on: Input.back)
    fileprivate static func pickResult(_ source: Busy) -> Route.PickResult { .up }
}
nonisolated func accepted() -> Picker.Owned<Picker.Busy> { Picker.owned(Picker.Idle()).pick() }
