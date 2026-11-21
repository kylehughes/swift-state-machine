// The second `Café` is spelled with U+0065 U+0301, not in Normalization Form C: a name Swift tells apart from
// `Café` by its bytes, which the macro would compare with it as text, so the macro refuses it.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    enum Problem: Error, Sendable { case bad }
    typealias Café = Problem
    typealias Café = Swift::Never
    struct Start: Sendable {}
    struct Done: Sendable {}
    @Initial case start(Start)
    @Terminal case done(Done)
    enum Input: Sendable { case go, stop }
    @Transition(on: Input.go)
    fileprivate static func finish(_ source: Start) -> Done { Done() }
    @Route(on: Input.stop)
    fileprivate static func refuse(_ source: Start) throws(Café) -> Swift::Never { fatalError() }
}
