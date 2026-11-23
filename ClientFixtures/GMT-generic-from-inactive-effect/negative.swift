// Including middle phase B (where Work is inactive) in a same-phase generic from: starting Work is rejected.
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum InactiveEffectGenericRefused: Sendable {
    struct A: Sendable {}
    struct B: Sendable {}
    struct C: Sendable {}
    @Initial case a(A = A())
    case b(B)
    case c(C)
    enum Input: Sendable { case next, pulse }

    @Operation(activeIn: [A.self, C.self])
    enum Work {}

    @Transition(on: Input.next)
    fileprivate static func toB(_ source: A) -> B { B() }
    @Transition(on: Input.next)
    fileprivate static func toC(_ source: B) -> C { C() }
    @Transition(on: Input.next)
    fileprivate static func toA(_ source: C) -> A { A() }

    @Transition(from: [A.self, B.self, C.self], on: Input.pulse, starts: [Work.self])
    fileprivate static func pulse<Source>(_ source: Source) -> Change<Source, Effect.Pulse> {
        Change(source, effects: [.work])
    }

    @Transition(onSuccess: Work.self)
    fileprivate static func doneA(_ source: A) -> A { source }
    @Transition(onSuccess: Work.self)
    fileprivate static func doneC(_ source: C) -> C { source }
}
