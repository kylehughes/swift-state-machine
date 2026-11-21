// A caller that is not deprecated gets Swift's deprecation of the generated method, with the authored message,
// whatever order the authored options take.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum Flow: Sendable {
    public struct Idle: Sendable { public init() {} }
    @Initial case idle(Idle)
    public enum Input: Sendable { case post, submit }
    @available(*, message: "Use submit.", deprecated)
    @Transition(on: Input.post)
    static func post(_ source: Idle) -> Idle { source }
    @Transition(on: Input.submit)
    static func submit(_ source: Idle) -> Idle { source }
}

func drive() {
    _ = Flow.Owned(Flow.Idle()).post()
}
