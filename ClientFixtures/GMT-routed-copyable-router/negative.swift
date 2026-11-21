// An edge that consumes the cable while every function declares an ownership: the routed method consumes
// it, which a caller that only borrows the cable cannot give.
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned])
nonisolated enum Bay {
    nonisolated struct Cable { let port: Int }
    nonisolated struct Empty {}
    nonisolated struct Kept { let port: Int }
    nonisolated struct Seen { let port: Int }
    @Initial case empty(Empty)
    @Terminal case kept(Kept)
    @Terminal case seen(Seen)
    enum Input { case offer(Cable) }
    @Route(on: Input.offer)
    fileprivate static func choose(_ source: Empty, _ cable: borrowing Cable) -> Route.Choose { cable.port > 0 ? .keep : .look }
    @Transition(on: Input.offer)
    fileprivate static func keep(_ source: Empty, _ cable: consuming Cable) -> Kept { Kept(port: cable.port) }
    @Transition(on: Input.offer)
    fileprivate static func look(_ source: Empty, _ cable: borrowing Cable) -> Seen { Seen(port: cable.port) }
}

func lend(_ cable: borrowing Bay.Cable) -> Bay.Route.ChooseResult {
    Bay.owned(Bay.Empty()).choose(cable)
}
