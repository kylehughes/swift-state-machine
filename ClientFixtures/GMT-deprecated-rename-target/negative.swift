// A rename the generated methods cannot use, here the authored function's qualified, labeled name, is refused at
// its string rather than repeated as a fix-it that names a file-private static function.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum Flow: Sendable {
    public struct Idle: Sendable { public init() {} }
    @Initial case idle(Idle)
    public enum Input: Sendable { case old(Int), next(Int) }
    @available(*, deprecated, renamed: "Flow.next(_:_:)")
    @Transition(on: Input.old)
    static func old(_ source: Idle, _ n: Int) -> Idle { source }
    @Transition(on: Input.next)
    static func next(_ source: Idle, _ n: Int) -> Idle { source }
}
