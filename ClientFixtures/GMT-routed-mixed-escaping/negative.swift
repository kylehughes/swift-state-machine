// An edge that keeps a closure payload makes the routed method take it escaping, so a caller cannot pass
// a nonescaping closure.
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned])
nonisolated enum Bench {
    typealias Work = @Sendable () -> Int
    nonisolated struct Idle {}
    nonisolated struct Kept { let work: Work }
    nonisolated struct Ran { let value: Int }
    @Initial case idle(Idle)
    @Terminal case kept(Kept)
    @Terminal case ran(Ran)
    enum Input: Sendable { case offer(Work), hand(Work) }
    @Route(on: Input.offer)
    fileprivate static func choose(_ source: Idle, _ work: borrowing Work) -> Route.Choose {
        work() < 10 ? .run : .keep
    }
    @Transition(on: Input.offer)
    fileprivate static func run(_ source: Idle, _ work: borrowing Work) -> Ran { Ran(value: work()) }
    @Transition(on: Input.offer)
    fileprivate static func keep(_ source: Idle, _ work: borrowing @escaping Work) -> Kept { Kept(work: copy work) }
    @Route(on: Input.hand)
    fileprivate static func weigh(_ source: Idle, _ work: __shared Work) -> Route.Weigh {
        work() < 10 ? .use : .store
    }
    @Transition(on: Input.hand)
    fileprivate static func use(_ source: Idle, _ work: Work) -> Ran { Ran(value: work()) }
    @Transition(on: Input.hand)
    fileprivate static func store(_ source: Idle, _ work: consuming sending @escaping Work) -> Kept { Kept(work: work) }
}

func offer(_ work: borrowing Bench.Work) -> Int {
    switch Bench.owned(Bench.Idle()).choose(work) {
    case .run(let ran): ran.withValue { $0.value }
    case .keep(let kept): kept.withValue { $0.work() }
    }
}

func hand(_ work: borrowing @escaping Bench.Work) -> Int {
    switch Bench.owned(Bench.Idle()).weigh(work) {
    case .use(let ran): ran.withValue { $0.value }
    case .store(let kept): kept.withValue { $0.work() }
    }
}

func owned() -> Int { offer { 3 } + hand { 30 } }
