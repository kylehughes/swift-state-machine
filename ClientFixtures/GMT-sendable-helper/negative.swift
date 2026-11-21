// A type reference to the helper is a use the public schema's generated members repeat.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum Flow: Swift::Sendable {
    enum Sendable {}
    public struct Idle: Swift::Sendable { public init() {} }
    @Initial case idle(Idle)
    public enum Input: Swift::Sendable { case run(@Sendable (Sendable) -> Swift::Int) }
    @Transition(on: Input.run)
    static func run(_ source: Idle, _ value: @escaping @Sendable (Sendable) -> Swift::Int) -> Idle { source }
}
