// A built-in attribute's name, such as `Sendable` in `@Sendable`, names no declaration, so a helper of that name in
// a public schema needs no access of its own.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum Flow: Swift::Sendable {
    enum Sendable {}
    public struct Idle: Swift::Sendable { public init() {} }
    @Initial case idle(Idle)
    public enum Input: Swift::Sendable { case run(@Sendable () -> Swift::Int) }
    @Transition(on: Input.run)
    static func run(_ source: Idle, _ value: @escaping @Sendable () -> Swift::Int) -> Idle { source }
}
