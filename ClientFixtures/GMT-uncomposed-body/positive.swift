// A body the macro never reads may call a declaration whose name is not in Normalization Form C, as an
// imported one may be: only the names the macro interprets must be composed.
import StateMachine

nonisolated func café() -> Int { 1 }

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Idle: Sendable { var count = 0 }
    struct Done: Sendable {}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input: Sendable { case go }
    static var total: Int { café() }
    static let next: @Sendable () -> Int = { café() + 1 }
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle) -> Done {
        _ = café()
        return Done()
    }
}
