// A name with a precomposed accent, `Café` spelled with U+00E9, is in Normalization Form C, so a router
// throwing the alias it declares throws a typed rejection.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    enum Problem: Error, Sendable { case bad }
    typealias Café = Problem
    struct Start: Sendable {}
    struct Done: Sendable {}
    @Initial case start(Start)
    @Terminal case done(Done)
    enum Input: Sendable { case go, stop }
    @Transition(on: Input.go)
    fileprivate static func finish(_ source: Start) -> Done { Done() }
    @Route(on: Input.stop)
    fileprivate static func refuse(_ source: Start) throws(Café) -> Swift::Never { throw .bad }
}
