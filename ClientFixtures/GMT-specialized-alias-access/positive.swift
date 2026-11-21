// A member of a generic type is one declaration whatever the type's arguments, so a public schema needs it public
// through a specialized alias and through a specialization written in place.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum Flow: Sendable {
    public enum Box<T> { public struct Hidden: Error {} }
    public typealias N = Box<Int>
    public struct Idle: Sendable { public init() {} }
    @Initial case idle(Idle)
    public enum Input: Sendable { case run, walk }
    @Transition(on: Input.run)
    static func run(_ source: Idle) throws(N.Hidden) -> Idle { source }
    @Transition(on: Input.walk)
    static func walk(_ source: Idle) throws(Box<String>.Hidden) -> Idle { source }
}

func drive() {
    let flow = Flow.Shared(Flow.Idle())
    do { _ = try flow.send(.run) } catch { _ = error }
}
