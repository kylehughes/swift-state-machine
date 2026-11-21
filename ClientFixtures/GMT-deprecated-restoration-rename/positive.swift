// A deprecated restoration function deprecates the restoring initializers and resets, with its message.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable {}
    @Initial @Terminal case idle(Idle)
    enum Input: Sendable {}
    @available(*, deprecated, message: "Restore from the current archive.")
    @Restoration
    fileprivate static func restore(_ saved: Int) -> Restoration { .idle(Idle()) }
}

@available(*, deprecated)
func restore() {
    _ = Flow.Shared(restoring: 1)
}
