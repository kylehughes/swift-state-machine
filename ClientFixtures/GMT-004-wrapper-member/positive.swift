// Phases may take Snapshot member names, and an edge that takes a payload generates revision(_:) beside the revision property.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Counter: Sendable {
    struct Idle: Sendable { let value: [String: [Int?]] }
    struct Done: Sendable { let value: Int }
    @Initial case revision(Idle)
    @Terminal case description(Done)
    enum Input: Sendable { case finish(Int) }
    @Transition(on: Input.finish)
    fileprivate static func revision(_ source: Idle, _ value: Int) -> Done {
        Done(value: source.value.count)
    }
}
