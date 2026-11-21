// The edge a schema named input generates still takes the payload its transition declares.
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
func check() { _ = input.owned(input.Idle()).go("one") }
