// An edge that takes a nonescaping closure `consuming`, which Swift rejects; the macro repeats only
// what Swift allows, so the rejection is Swift's, at the authored function.
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned])
nonisolated enum Desk {
    typealias Work = @Sendable () -> Int
    nonisolated struct Idle {}
    nonisolated struct Quick { let value: Int }
    nonisolated struct Slow { let value: Int }
    @Initial case idle(Idle)
    @Terminal case quick(Quick)
    @Terminal case slow(Slow)
    enum Input: Sendable { case act(@Sendable () -> Int), hand(Work) }
    @Route(on: Input.act)
    fileprivate static func choose(_ source: Idle, _ work: sending @Sendable () -> Int) -> Route.Choose {
        work() < 10 ? .runQuickly : .runSlowly
    }
    @Transition(on: Input.act)
    fileprivate static func runQuickly(_ source: Idle, _ work: borrowing @Sendable () -> Int) -> Quick {
        Quick(value: work())
    }
    @Transition(on: Input.act)
    fileprivate static func runSlowly(_ source: Idle, _ work: @Sendable () -> Int) -> Slow { Slow(value: work()) }
    @Route(on: Input.hand)
    fileprivate static func weigh(_ source: Idle, _ work: __shared sending Work) -> Route.Weigh {
        work() < 10 ? .take : .pass
    }
    @Transition(on: Input.hand)
    fileprivate static func take(_ source: Idle, _ work: consuming Work) -> Quick { Quick(value: work()) }
    @Transition(on: Input.hand)
    fileprivate static func pass(_ source: Idle, _ work: borrowing Work) -> Slow { Slow(value: work()) }
}

func route() -> Int {
    switch Desk.owned(Desk.Idle()).choose({ 3 }) {
    case .runQuickly(let quick): quick.withValue { $0.value }
    case .runSlowly(let slow): slow.withValue { $0.value }
    }
}

func weigh() -> Int {
    switch Desk.owned(Desk.Idle()).weigh({ 30 }) {
    case .take(let quick): quick.withValue { $0.value }
    case .pass(let slow): slow.withValue { $0.value }
    }
}
