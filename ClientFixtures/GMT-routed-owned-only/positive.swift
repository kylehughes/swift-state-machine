// Move-only (~Copyable) routed values with explicit consuming/borrowing work in a route-capable mode (.isolated).
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned, .local])
nonisolated enum MoveOnlyRoutedControl {
    struct Handle: ~Copyable { let fd: Int }
    struct Open {}
    struct Taken { let fd: Int }
    struct Inspected { let fd: Int }
    @Initial case open(Open = Open())
    @Terminal case taken(Taken)
    @Terminal case inspected(Inspected)
    enum Input { case go(Bool) }

    @Transition(on: Input.go)
    fileprivate static func take(_ source: Open, _ consumeIt: Bool, routed handle: consuming Handle) -> Taken {
        Taken(fd: handle.fd)
    }

    @Transition(on: Input.go)
    fileprivate static func inspect(_ source: Open, _ consumeIt: Bool, routed handle: borrowing Handle) -> Inspected {
        Inspected(fd: handle.fd)
    }

    @Route(on: Input.go)
    fileprivate static func choose(_ source: Open, _ consumeIt: Bool) -> Route.Choose {
        consumeIt ? .take(Handle(fd: 1)) : .inspect(Handle(fd: 2))
    }
}
