// The two failures are not one type, so the router's generated method does not throw the first.
import StateMachine

public struct Problem<T>: Swift::Error { public init() {} }

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    enum Left { enum Actors { @globalActor actor A { static let shared = A() } }; typealias F = @Actors.A () -> Swift::Void }
    enum Right { enum Actors { @globalActor actor A { static let shared = A() } }; typealias F = @Actors.A () -> Swift::Void }
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Sendable { case pick }
    @Route(on: Input.pick)
    fileprivate static func choose(_ source: Idle) -> Route.Choose { .first }
    @Transition(on: Input.pick)
    fileprivate static func first(_ source: Idle) throws(Problem<Left.F>) -> Idle { Idle() }
    @Transition(on: Input.pick)
    fileprivate static func second(_ source: Idle) throws(Problem<Right.F>) -> Idle { Idle() }
}
extension Flow {
    static func check(_ observed: Observed<Idle>) {
        do throws(Problem<Left.F>) { _ = try observed.choose() } catch { _ = error }
    }
}
