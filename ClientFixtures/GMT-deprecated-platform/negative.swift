// A deprecation from a platform version is availability the macro cannot compare with the deployment target, so
// it is refused as every other availability on an authored function is.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable {}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input: Sendable { case go }
    @available(macOS, deprecated: 14, message: "Use the replacement.")
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle) -> Done { Done() }
}
