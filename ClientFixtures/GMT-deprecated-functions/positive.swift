// Deprecating an authored edge, router, completion edge, or restoration function deprecates only the generated
// public members named for it: `Owned`'s and `Observed`'s methods for an edge or router, and the restoring
// initializers and resets for a restoration function. Generated code calls the functions without a warning, so
// this module compiles with warnings as errors; inputs, deliveries, and fresh owners name nothing deprecated; and
// a deprecated caller may use the deprecated members.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum Flow: Sendable {
    public struct Idle: Sendable { public init() {} }
    public struct Busy: Sendable {}
    public struct Done: Sendable {}
    public enum Problem: Error { case refused }
    @Initial case idle(Idle)
    case busy(Busy)
    @Terminal case done(Done)
    public enum Input: Sendable { case start(Int), begin, pick, stop }
    @Operation(activeIn: [Busy.self])
    public enum Load { public typealias Output = Int }
    @available(*, deprecated, renamed: "begin")
    @Transition(on: Input.start)
    static func start(_ source: Idle, _ count: Int) throws(Problem) -> Idle {
        guard count > 0 else { throw .refused }
        return source
    }
    @Transition(on: Input.begin, starts: [Load.self])
    static func begin(_ source: Idle) -> Change<Busy, Effect.Begin> { Change(Busy(), effects: [.load]) }
    @available(*, deprecated, message: "Deliver through the router.")
    @Transition(onSuccess: Load.self)
    static func loaded(_ source: Busy, _ output: Int) -> Idle { Idle() }
    @Transition(on: Input.stop)
    static func stop(_ source: Busy) -> Done { Done() }
    @available(*, deprecated)
    @Route(on: Input.pick)
    static func pick(_ source: Idle) -> Route.Pick { .left }
    @Transition(on: Input.pick)
    static func left(_ source: Idle) -> Idle { source }
    @available(*, deprecated, renamed: "stop")
    @Transition(on: Input.pick)
    static func right(_ source: Idle) -> Done { Done() }
    @available(*, deprecated, message: "Restore from the current archive.")
    @Restoration
    static func restore(_ saved: Int) throws(Problem) -> Restoration {
        guard saved >= 0 else { throw .refused }
        return .idle(Idle())
    }
}

func drive() throws {
    let flow = Flow.Shared(Flow.Idle(), drivers: .init(load: { 1 }))
    _ = try flow.send(.start(1))
    _ = try flow.send(.pick)
    _ = try flow.send(.begin)
    let owned = Flow.Owned(Flow.Idle())
    _ = owned.begin()
}

@available(*, deprecated)
func driveDeprecated() throws {
    let owned = Flow.Owned(Flow.Idle())
    _ = owned.start(1)
    _ = Flow.Owned(Flow.Idle()).pick()
    _ = try Flow.Shared(restoring: 1, drivers: .init(load: { 1 }))
    var local = Flow.Local(Flow.Idle())
    _ = try local.reset(restoring: 1)
}
