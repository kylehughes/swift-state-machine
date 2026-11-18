import StateMachine

/// A domain compiled in an independent package using only distributed runtime APIs.
@StateMachine(mode: .shared)
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
    @Initial case idle(Idle)
    case done(Done)
    /// Closed dynamic inputs.
    public enum Input: Sendable {
        case add(Int)
        case finish(Int)
    }
    /// Records one more value without leaving the initial phase.
    @Transition(on: Input.add)
    fileprivate static func add(_ source: Idle, _ value: Int) -> Idle {
        var values = source.value
        values["added", default: []].append(value)
        return Idle(values)
    }
    /// Computes the declared successor synchronously from a borrowed predecessor.
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Idle, _ value: Int) -> Done {
        Done(value + source.value.count)
    }
}
