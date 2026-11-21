// An input edge has no request, so a request: label is diagnosed.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    @Terminal case running(Running)
    enum Input: Sendable { case go(Swift::Int) }
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle, request value: Swift::Int) -> Running { Running() }
}
