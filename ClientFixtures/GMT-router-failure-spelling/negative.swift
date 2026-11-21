// Router candidates that throw one type, however they spell it, give the router's prepared method
// that type, and a router may return its choice through `Self.`, the schema's name, or with comments.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Door: Sendable {
    enum Problem: Swift.Error, Sendable { case jammed }
    enum Other: Swift.Error, Sendable { case unrelated }
    struct Closed: Sendable {}
    struct Open: Sendable {}
    struct Locked: Sendable {}
    @Initial case closed(Closed)
    case open(Open)
    case locked(Locked)
    enum Input: Sendable { case push, back, turn }
    @Route(on: Input.push)
    fileprivate static func choose(_ source: Closed) -> Self.Route.Choose { .open }
    @Transition(on: Input.push)
    fileprivate static func open(_ source: Closed) throws(Problem) -> Open { Open() }
    @Transition(on: Input.push)
    fileprivate static func lock(_ source: Closed) throws(Self.Problem) -> Locked { Locked() }
    @Route(on: Input.turn)
    fileprivate static func pick(_ source: Closed) -> Route /* the choice */ .Pick { .stay }
    @Transition(on: Input.turn)
    fileprivate static func stay(_ source: Closed) -> Closed { source }
    @Transition(on: Input.turn)
    fileprivate static func bolt(_ source: Closed) -> Locked { Locked() }
    @Transition(from: [Open.self, Locked.self], on: Input.back)
    fileprivate static func back() -> Closed { Closed() }
}

nonisolated func prepare(_ observed: Door.Observed<Door.Closed>) throws(Door.Other) -> Door.Prepared {
    try observed.choose()
}
