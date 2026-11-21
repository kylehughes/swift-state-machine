// A member named through a namespace alias is the member of the type the alias names, so a public schema needs
// that member public however its spelling reaches it.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum Flow: Sendable {
    public enum Box { public struct Hidden: Error {} }
    public typealias N = Box
    public struct Idle: Sendable { public init() {} }
    @Initial case idle(Idle)
    public enum Input: Sendable { case run }
    @Transition(on: Input.run)
    static func run(_ source: Idle) throws(N.Hidden) -> Idle { source }
}
