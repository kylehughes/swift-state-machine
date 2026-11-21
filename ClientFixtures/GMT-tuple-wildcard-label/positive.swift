// (_: Part, Part) and (Part, Part) are one type, so the router's method throws it; (_: ()) is Void, so the success takes no output.
import StateMachine

public struct Problem<T>: Swift::Error { public init() {} }
public struct Part {}

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    nonisolated struct Idle: Sendable {}
    nonisolated struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case pick, go }
    @Operation(activeIn: [Running.self])
    enum Load { typealias Output = (_: ()) }
    @Route(on: Input.pick)
    fileprivate static func choose(_ source: Idle) -> Route.Choose { .first }
    @Transition(on: Input.pick)
    fileprivate static func first(_ source: Idle) throws(Problem<(_: Part, Part)>) -> Idle { Idle() }
    @Transition(on: Input.pick)
    fileprivate static func second(_ source: Idle) throws(Problem<(Part, Part)>) -> Idle { Idle() }
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> { Change(Running(), effects: [.load]) }
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running) -> Idle { Idle() }
}

extension Flow {
    static func check(_ observed: Observed<Idle>) {
        do throws(Problem<(Part, Part)>) { _ = try observed.choose() } catch { _ = error }
    }
}
