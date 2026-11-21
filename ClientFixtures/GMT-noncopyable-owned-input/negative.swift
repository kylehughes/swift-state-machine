// Local keeps the inputs it routes, which a noncopyable Input cannot give it.
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned, .local])
nonisolated enum Dock {
    nonisolated struct Cable: ~Copyable { let port: Int }
    nonisolated struct Empty {}
    nonisolated struct Plugged { let port: Int }
    @Initial case empty(Empty)
    @Terminal case plugged(Plugged)
    enum Input: ~Copyable { case plug(Cable), probe(Cable) }
    @Transition(on: Input.plug)
    fileprivate static func plug(_ source: Empty, _ cable: consuming Cable) -> Plugged { Plugged(port: cable.port) }
    @Transition(on: Input.probe)
    fileprivate static func probe(_ source: Empty, _ cable: borrowing Cable) -> Plugged { Plugged(port: cable.port) }
}

func connect() -> Int {
    let plugged = Dock.owned(Dock.Empty()).plug(Dock.Cable(port: 2))
    return plugged.withValue { $0.port }
}
