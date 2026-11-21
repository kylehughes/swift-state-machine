// A public schema's private helper may share a basename with a public type its signatures name: the macro
// checks the declaration each spelling resolves to where it is written.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum Approval: Sendable {
    public struct Draft: Sendable {}
    public struct Approved: Sendable {}
    private enum Notes { struct Draft {} }
    fileprivate struct Holder { typealias Approved = Int }
    @Initial case draft(Draft)
    @Terminal case approved(Approved)
    public enum Input: Sendable { case approve }
    @Transition(on: Input.approve)
    fileprivate static func approve(_ source: Draft) -> Approved { Approved() }
}

public func approve() {
    _ = try? Approval.Shared(Approval.Draft()).send(.approve)
}
