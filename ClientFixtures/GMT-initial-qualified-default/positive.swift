// Qualified initial payloads construct their default through the schema's alias.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Form: Sendable {
    nonisolated struct Idle: Sendable {}
    nonisolated struct Done: Sendable {}
    @Initial case idle(Form.Idle = Form.Idle())
    @Terminal case done(Done)
    enum Input: Sendable { case go }
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle) -> Done { Done() }
}

@StateMachine(mode: .shared)
nonisolated enum Sheet: Sendable {
    nonisolated struct Idle: Sendable {}
    nonisolated struct Done: Sendable {}
    @Initial case idle(Self.Idle = Self.Idle())
    @Terminal case done(Done)
    enum Input: Sendable { case go }
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle) -> Done { Done() }
}

func start() {
    _ = Form.Local()
    _ = Form.owned()
    _ = Sheet.Local()
}
