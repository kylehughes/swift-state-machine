// A member of a generic type named through a specialized alias keeps its own access, which the public schema's
// generated members cannot name.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum Flow: Sendable {
    public enum Box<T> { struct Hidden: Error {} }
    public typealias N = Box<Int>
    public struct Idle: Sendable { public init() {} }
    @Initial case idle(Idle)
    public enum Input: Sendable { case run }
    @Transition(on: Input.run)
    static func run(_ source: Idle) throws(N.Hidden) -> Idle { source }
}
