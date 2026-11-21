// Without a payload, the edge would generate Observed.revision(), which redeclares the revision property.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Counter: Sendable {
    struct Idle: Sendable { let value: [String: [Int?]] }
    struct Done: Sendable { let value: Int }
    @Initial case revision(Idle)
    @Terminal case description(Done)
    enum Input: Sendable { case finish }
    @Transition(on: Input.finish)
    fileprivate static func revision(_ source: Idle) -> Done {
        Done(value: source.value.count)
    }
}
