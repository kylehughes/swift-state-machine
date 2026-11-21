// A caller that is not deprecated gets Swift's deprecation of the generated method named for a deprecated edge,
// with the authored rename.
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
    let owned = Flow.Owned(Flow.Idle())
    _ = owned.start(1)
}
