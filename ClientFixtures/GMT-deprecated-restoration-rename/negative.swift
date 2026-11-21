// The restoring initializers and resets keep their names, so a restoration function's deprecation cannot rename it.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    @Initial @Terminal case idle(Idle)
    enum Input: Sendable {}
    @available(*, deprecated, renamed: "restoreCurrent")
    @Restoration
    fileprivate static func restore(_ saved: Int) -> Restoration { .idle(Idle()) }
}
