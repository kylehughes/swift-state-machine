// Middle phase B does not conform to SelectionCarrying, so Swift rejects the generated per-phase call.
import StateMachine

private nonisolated protocol SelectionCarrying {
    var selectedID: Int? { get set }
}

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum NonConformingPhaseRefused: Sendable {
    struct A: Sendable, SelectionCarrying { var selectedID: Int? = nil }
    struct B: Sendable { var other: String }
    struct C: Sendable, SelectionCarrying { var selectedID: Int? = nil }
    @Initial case a(A = A())
    case b(B)
    case c(C)
    enum Input: Sendable { case next, select(Int?) }

    @Transition(on: Input.next)
    fileprivate static func toB(_ source: A) -> B { B(other: "b") }
    @Transition(on: Input.next)
    fileprivate static func toC(_ source: B) -> C { C(selectedID: nil) }
    @Transition(on: Input.next)
    fileprivate static func toA(_ source: C) -> A { A(selectedID: source.selectedID) }

    @Transition(from: [A.self, B.self, C.self], on: Input.select)
    fileprivate static func select<Source: SelectionCarrying>(_ source: Source, _ id: Int?) -> Source {
        var next = source
        next.selectedID = id
        return next
    }
}
