// A generic multi-source transition with routed: is rejected when a middle phase in from: has no @Route.
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum PartialRouteRefused: Sendable {
    struct A: Sendable {}
    struct B: Sendable {}
    struct C: Sendable {}
    struct Done: Sendable { let tag: Int }
    @Initial case a(A = A())
    case b(B)
    case c(C)
    @Terminal case done(Done)
    enum Input: Sendable { case next, finish }

    @Transition(on: Input.next)
    fileprivate static func toB(_ source: A) -> B { B() }
    @Transition(on: Input.next)
    fileprivate static func toC(_ source: B) -> C { C() }

    @Transition(from: [A.self, B.self, C.self], on: Input.finish)
    fileprivate static func finish<Source>(_ source: Source, routed tag: Int) -> Done { Done(tag: tag) }
    @Transition(from: [A.self, B.self, C.self], on: Input.finish)
    fileprivate static func keep<Source>(_ source: Source) -> Source { source }

    @Route(on: Input.finish)
    fileprivate static func routeFinish(_ source: A) -> Route.RouteFinish { .finish(1) }
    @Route(on: Input.finish)
    fileprivate static func routeFinish(_ source: C) -> Route.RouteFinish { .finish(3) }
}
