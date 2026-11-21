// A global actor of any name may isolate code outside the authored functions, which generated code calls
// from nonisolated code.
import StateMachine

@globalActor actor uiActor { static let shared = uiActor() }

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable {}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input: Sendable { case go }
    @discardableResult @inline(never)
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle) -> Done { Done() }
}

@uiActor func show() {
    _ = try? Flow.Shared(Flow.Idle()).send(.go)
}
