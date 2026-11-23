// A multi-source transition declaring more than one generic type parameter is rejected.
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum GenericArityRefused: Sendable {
    struct A: Sendable {}
    struct B: Sendable {}
    @Initial case a(A = A())
    case b(B)
    enum Input: Sendable { case flip, keep }

    @Transition(on: Input.flip)
    fileprivate static func flip(_ source: A) -> B { B() }

    @Transition(from: [A.self, B.self], on: Input.keep)
    fileprivate static func keep<Source, Extra>(_ source: Source) -> Source { source }
}
