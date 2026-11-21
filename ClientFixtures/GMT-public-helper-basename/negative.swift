// A type that a public signature names through a path needs the schema's access at each step.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum Approval: Sendable {
    public struct Draft: Sendable {}
    public struct Approved: Sendable {}
    enum Notes { struct Detail: Sendable {} }
    @Initial case draft(Draft)
    @Terminal case approved(Approved)
    public enum Input: Sendable { case approve(Notes.Detail) }
    @Transition(on: Input.approve)
    fileprivate static func approve(_ source: Draft, _ note: Notes.Detail) -> Approved { Approved() }
}
