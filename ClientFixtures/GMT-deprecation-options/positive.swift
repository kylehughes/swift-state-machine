// A deprecation's options after `*` may come in any order, as Swift reads them, and the generated methods repeat the
// attribute as written; generated code calls the function without a warning, and a deprecated caller may call them.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum Flow: Sendable {
    public struct Idle: Sendable { public init() {} }
    @Initial case idle(Idle)
    public enum Input: Sendable { case post, publish, submit }
    @available(*, message: "Use submit.", deprecated)
    @Transition(on: Input.post)
    static func post(_ source: Idle) -> Idle { source }
    @available(*, renamed: "submit", message: "Use submit.", deprecated)
    @Transition(on: Input.publish)
    static func publish(_ source: Idle) -> Idle { source }
    @Transition(on: Input.submit)
    static func submit(_ source: Idle) -> Idle { source }
}

func drive() throws {
    let flow = Flow.Shared(Flow.Idle())
    _ = try flow.send(.post)
    _ = try flow.send(.publish)
    _ = Flow.Owned(Flow.Idle()).submit()
}

@available(*, deprecated)
func driveDeprecated() {
    _ = Flow.Owned(Flow.Idle()).post()
    _ = Flow.Owned(Flow.Idle()).publish()
}
