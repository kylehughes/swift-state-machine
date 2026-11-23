// A generic multi-source transition's trigger payload cannot reference the generic source parameter.
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum GenericPayloadRefused: Sendable {
    struct A: Sendable {}
    struct B: Sendable {}
    @Initial case a(A = A())
    case b(B)
    enum Input: Sendable { case flip, touch(Int) }

    @Transition(on: Input.flip)
    fileprivate static func flip(_ source: A) -> B { B() }

    @Transition(from: [A.self, B.self], on: Input.touch)
    fileprivate static func touch<Source>(_ source: Source, _ value: Source) -> Source { source }
}
