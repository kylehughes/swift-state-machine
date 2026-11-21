// A phase case, an async static method, a static method that takes arguments, and an instance property may share the name of the generated graph.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {
    struct Node: Sendable {}
    @Initial @Terminal case graph(Node)
    enum Input: Sendable {}
    static func graph(_ index: Int) -> Int { index }
    static func graph() async -> Int { 2 }
    var graph: Int { 0 }
}
func check() async -> Int { await Flow.graph() + Flow.graph(1) + Flow.graph.phases.count }
func owned() { _ = Flow.Local(Flow.Node()).snapshot() }
