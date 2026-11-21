// A rename is the bare name of another edge with a generated method wherever the deprecated edge has one, so the
// call Swift's fix-it makes of the deprecated generated method, which keeps the arguments, compiles.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum Flow: Sendable {
    public struct Idle: Sendable { public init() {} }
    @Initial case idle(Idle)
    public enum Input: Sendable { case old(Int), next(Int) }
    @available(*, deprecated, renamed: "next")
    @Transition(on: Input.old)
    static func old(_ source: Idle, _ n: Int) -> Idle { source }
    @Transition(on: Input.next)
    static func next(_ source: Idle, _ n: Int) -> Idle { source }
}

func drive() throws {
    // `owned.old(7)` with the fix-it applied.
    let owned = Flow.Owned(Flow.Idle())
    _ = owned.next(7)
    let flow = Flow.Shared(Flow.Idle())
    _ = try flow.send(.old(7))
}
