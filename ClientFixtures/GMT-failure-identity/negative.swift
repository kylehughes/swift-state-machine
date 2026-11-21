// A protocol's bare P.Type is the existential of its conforming types' metatypes, another type than the metatype
// (any P).Type, so the router's candidates have two failures and its generated method throws PreparationRejection.
import StateMachine

public struct Wrap<T>: Error { public init() {} }

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    protocol P {}
    protocol Q {}
    struct Bad: Error {}
    typealias Same = Bad
    typealias BareP = P
    typealias AnyP = any P
    typealias Id<T> = T
    typealias Constant<T> = P
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case bareMetatype }
    @Route(on: Input.bareMetatype)
    fileprivate static func pickBareMetatype(_ source: Idle) -> Route.PickBareMetatype { .bareMetatypeFirst }
    @Transition(on: Input.bareMetatype)
    fileprivate static func bareMetatypeFirst(_ source: Idle) throws(Wrap<P.Type>) -> Idle { Idle() }
    @Transition(on: Input.bareMetatype)
    fileprivate static func bareMetatypeSecond(_ source: Idle) throws(Wrap<(any P).Type>) -> Idle { Idle() }
}
extension Flow {
    static func check(_ observed: Observed<Idle>) {
        do throws(Wrap<P.Type>) { _ = try observed.pickBareMetatype() } catch { _ = error }
    }
}
