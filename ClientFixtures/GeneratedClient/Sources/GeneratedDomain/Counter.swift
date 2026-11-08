import StateMachine
import StateMachineSchema

/// A domain compiled in an independent package using only distributed runtime APIs.
@StateMachine(mode: .shared, initial: "idle", scopes: [])
nonisolated public enum Counter: Sendable {
    /// Initial ordinary payload data.
    public struct Idle: Sendable {
        /// The initial count.
        public let value: [String: [Int?]]
        /// Creates initial model data without live authority.
        public init(_ value: [String: [Int?]]) { self.value = value }
    }
    /// Completed ordinary payload data.
    public struct Done: Sendable {
        /// The completed count.
        public let value: Int
        /// Creates completed model data without live authority.
        public init(_ value: Int) { self.value = value }
    }
    case idle(Idle)
    case done(Done)
    /// Closed dynamic inputs.
    public enum Input: Sendable { case finish(Int) }
    /// No managed operations are declared in this graph.
    public enum Effect: Sendable {}
    /// Computes the declared successor synchronously from a borrowed predecessor.
    @Transition(from: "idle", to: "done", on: .input("finish"))
    fileprivate static func finish(_ source: borrowing Idle, _ value: Int) -> Change<Done, Effect> {
        Change(Done(value + source.value.count))
    }
}
