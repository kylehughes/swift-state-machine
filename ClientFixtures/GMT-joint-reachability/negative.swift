// Each entrance to `Checking` holds one operation's work, and `Reviewed` is reached only by consuming
// `Review`, so no path reaches it holding `Publish`: `Published` is unreachable.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Article: Sendable {
    struct Drafting: Sendable {}
    struct Checking: Sendable {}
    struct Reviewed: Sendable {}
    struct Published: Sendable {}
    @Initial case drafting(Drafting)
    case checking(Checking)
    case reviewed(Reviewed)
    @Terminal case published(Published)
    enum Input: Sendable { case review, publish }
    @Operation(activeIn: [Checking.self])
    enum Review {}
    @Operation(activeIn: [Checking.self, Reviewed.self])
    enum Publish {}
    @Transition(on: Input.review, starts: [Review.self])
    fileprivate static func review(_ source: Drafting) -> Change<Checking, Effect.Review> {
        Change(Checking(), effects: [.review])
    }
    @Transition(on: Input.publish, starts: [Publish.self])
    fileprivate static func publish(_ source: Drafting) -> Change<Checking, Effect.Publish> {
        Change(Checking(), effects: [.publish])
    }
    @Transition(onSuccess: Review.self)
    fileprivate static func approved(_ source: Checking) -> Reviewed { Reviewed() }
    @Transition(onSuccess: Publish.self)
    fileprivate static func withdrawn(_ source: Checking) -> Drafting { Drafting() }
    @Transition(onSuccess: Publish.self)
    fileprivate static func released(_ source: Reviewed) -> Published { Published() }
}
