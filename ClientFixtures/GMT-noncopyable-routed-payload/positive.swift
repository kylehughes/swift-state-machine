// The router borrows the cable, and the edge it selects consumes or borrows it.
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned])
nonisolated enum Bay: ~Copyable {
    nonisolated struct Cable: ~Copyable { let port: Int }
    nonisolated struct Empty {}
    nonisolated struct Kept: ~Copyable { let cable: Cable }
    nonisolated struct Seen { let port: Int }
    @Initial case empty(Empty)
    @Terminal case kept(Kept)
    @Terminal case seen(Seen)
    enum Input: ~Copyable { case offer(Cable) }
    @Route(on: Input.offer)
    fileprivate static func choose(_ source: Empty, _ cable: borrowing Cable) -> Route.Choose { .keep }
    @Transition(on: Input.offer)
    fileprivate static func keep(_ source: Empty, _ cable: consuming Cable) -> Kept { Kept(cable: cable) }
    @Transition(on: Input.offer)
    fileprivate static func look(_ source: Empty, _ cable: borrowing Cable) -> Seen { Seen(port: cable.port) }
}
