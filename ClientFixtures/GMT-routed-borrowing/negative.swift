// An edge that consumes the payload makes the routed method consume it, which a borrowing caller cannot give.
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned])
nonisolated enum Bay: ~Copyable {
    nonisolated struct Cable: ~Copyable { let port: Int }
    nonisolated struct Empty {}
    nonisolated struct Kept { let port: Int }
    nonisolated struct Seen { let port: Int }
    @Initial case empty(Empty)
    @Terminal case kept(Kept)
    @Terminal case seen(Seen)
    enum Input: ~Copyable { case offer(Cable) }
    @Route(on: Input.offer)
    fileprivate static func choose(_ source: Empty, _ cable: borrowing Cable) -> Route.Choose { cable.port > 0 ? .keep : .look }
    @Transition(on: Input.offer)
    fileprivate static func keep(_ source: Empty, _ cable: consuming Cable) -> Kept { Kept(port: cable.port) }
    @Transition(on: Input.offer)
    fileprivate static func look(_ source: Empty, _ cable: borrowing Cable) -> Seen { Seen(port: cable.port) }
}

/// A caller that only borrows the cable can run the router.
func lend(_ cable: borrowing Bay.Cable) -> Bay.Route.ChooseResult {
    Bay.owned(Bay.Empty()).choose(cable)
}
