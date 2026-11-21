import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Relay: Sendable {
    struct Start: Sendable {}
    struct First: Sendable {}
    struct Second: Sendable {}
    struct Third: Sendable {}
    struct Done: Sendable {}
    @Initial case start(Start)
    case first(First)
    case second(Second)
    case third(Third)
    @Terminal case done(Done)
    enum Input: Sendable { case go }
    @Operation(activeIn: [First.self, Second.self, Third.self], admission: .parallel(limit: 3))
    enum Leg {}
    @Transition(on: Input.go, starts: [Leg.self])
    fileprivate static func go(_ source: Start) -> Change<First, Effect.Go> {
        Change(First(), effects: [.leg, .leg, .leg])
    }
    @Transition(onSuccess: Leg.self)
    fileprivate static func one(_ source: First) -> Second { Second() }
    @Transition(onSuccess: Leg.self)
    fileprivate static func two(_ source: Second) -> Third { Third() }
    @Transition(onSuccess: Leg.self)
    fileprivate static func three(_ source: Third) -> Done { Done() }
}
