// A generated case name is reserved only by the owners whose expansion declares it.
import StateMachine

// Only `Owned` has a throwing router's `rejected` result case.
@StateMachine(mode: .shared, owners: [.local])
nonisolated enum Review: Sendable {
    enum Problem: Error { case unreadable }
    struct Pending: Sendable {}
    struct Settled: Sendable {}
    @Initial case pending(Pending)
    @Terminal case settled(Settled)
    enum Input: Sendable { case decide(Bool) }
    @Transition(on: Input.decide)
    fileprivate static func accepted(_ source: Pending, _ approve: Bool) -> Settled { Settled() }
    @Transition(on: Input.decide)
    fileprivate static func rejected(_ source: Pending, _ approve: Bool) -> Settled { Settled() }
    @Route(on: Input.decide)
    fileprivate static func choose(_ source: Pending, _ approve: Bool) throws(Problem) -> Route.Choose {
        approve ? .accepted : .rejected
    }
}

// Only an observing owner has `PreparationRejection.invalidPhase`.
@StateMachine(mode: .shared, owners: [.owned])
nonisolated enum Gate: Sendable {
    enum Problem: Error { case closed }
    struct Open: Sendable {}
    struct Passed: Sendable {}
    @Initial case open(Open)
    @Terminal case passed(Passed)
    enum Input: Sendable { case pass }
    @Transition(on: Input.pass)
    fileprivate static func invalidPhase(_ source: Open) throws(Problem) -> Passed { Passed() }
}

// A keyed operation has cancellation cases only when an edge lists it in `cancels:`.
@StateMachine(mode: .shared)
nonisolated enum Feed: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable {}
    @Initial case idle(Idle)
    case loading(Loading)
    enum Input: Sendable { case load(Int), stop }
    @Operation(activeIn: [Loading.self])
    enum Fetch { typealias Key = Int }
    @Event enum CancelFetch {}
    @Transition(on: Input.load, starts: [Fetch.self])
    fileprivate static func load(_ source: Idle, _ key: Int) -> Change<Loading, Effect.Load> {
        Change(Loading(), effects: [.fetch(key: key)])
    }
    @Transition(on: Input.stop, emits: [CancelFetch.self])
    fileprivate static func stop(_ source: Loading) -> Change<Idle, Effect.Stop> {
        Change(Idle(), effects: [.cancelFetch])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func fetched(_ source: Loading) -> Idle { Idle() }
}
