// The macro asks for the access of a member an alias's type declares, as it does through the type's own name.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum Flow: Sendable {
    public enum Box { struct Hidden: Error {} }
    public typealias N = Box
    public struct Idle: Sendable { public init() {} }
    @Initial case idle(Idle)
    public enum Input: Sendable { case run }
    @Transition(on: Input.run)
    static func run(_ source: Idle) throws(N.Hidden) -> Idle { source }
}
