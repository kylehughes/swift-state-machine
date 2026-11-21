// A schema named like a parameter of generated code still names itself in every generated call.
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local, .shared])
nonisolated enum input: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable { let value: Int }
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input: Sendable { case go(Int) }
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle, _ value: Int) -> Done { Done(value: value) }
}
func check() throws {
    _ = input.owned(input.Idle()).go(1)
    var local = input.Local(input.Idle())
    try local.send(.go(2))
    try input.Shared(input.Idle()).send(.go(3))
}
