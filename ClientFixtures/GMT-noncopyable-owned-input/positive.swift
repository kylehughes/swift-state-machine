// Owned alone passes a noncopyable cable on, consumed or borrowed as each transition takes it.
import StateMachine

@StateMachine(mode: .ownedOnly)
nonisolated enum Dock: ~Copyable {
    nonisolated struct Cable: ~Copyable { let port: Int }
    nonisolated struct Empty {}
    nonisolated struct Plugged: ~Copyable { let port: Int }
    @Initial case empty(Empty)
    @Terminal case plugged(Plugged)
    enum Input: ~Copyable { case plug(Cable), probe(Cable) }
    @Transition(on: Input.plug)
    fileprivate static func plug(_ source: consuming Empty, _ cable: consuming Cable) -> Plugged { Plugged(port: cable.port) }
    @Transition(on: Input.probe)
    fileprivate static func probe(_ source: consuming Empty, _ cable: borrowing Cable) -> Plugged { Plugged(port: cable.port) }
}

func connect() -> Int {
    let plugged = Dock.owned(Dock.Empty()).plug(Dock.Cable(port: 2))
    return plugged.withValue { $0.port }
}
