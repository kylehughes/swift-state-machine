// With only Owned, no generated declaration uses the router failure, so it needs no alias.
import StateMachine

fileprivate enum Phase: Error { case refused }

@StateMachine(mode: .shared, owners: [.owned])
public nonisolated enum Gate: Sendable {
    public struct Shut: Sendable {}
    public struct Open: Sendable {}
    @Initial case shut(Shut)
    case open(Open)
    public enum Input: Sendable { case open, close }
    @Route(on: Input.close)
    fileprivate static func refuse(_ source: Open) throws(Phase) -> Never { throw .refused }
    @Transition(on: Input.open)
    public static func open(_ source: Shut) -> Open { Open() }
    @Transition(on: Input.open)
    public static func reopen(_ source: Open) -> Shut { Shut() }
}
