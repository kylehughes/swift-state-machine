// A synchronous static method without parameters named graph is the same declaration as the generated property.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Node: Sendable {}
    @Initial @Terminal case graph(Node)
    enum Input: Sendable {}
    static func graph() throws -> Int { 2 }
}
