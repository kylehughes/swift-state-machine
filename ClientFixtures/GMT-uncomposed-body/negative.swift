// A name in a signature is one the macro interprets, so it must be in Normalization Form C.
import StateMachine

struct café: Sendable {}

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable {}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input: Sendable { case go(café) }
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle, _ value: café) -> Done { Done() }
}
