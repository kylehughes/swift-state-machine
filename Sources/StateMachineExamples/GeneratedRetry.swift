import StateMachine

/// A generated workflow whose one input reaches two edges through a router that may decline it.
///
/// Both `send(.retry)` and a typed `waiting.decide()` run the router `decide`, so neither can reach
/// `again` or `giveUp` while the waiting phase is locked.
@StateMachine(mode: .shared)
nonisolated public enum GeneratedRetry: Sendable {
    /// A failed attempt waiting for a decision.
    public struct Waiting: Sendable {
        /// Attempts made so far.
        public let attempts: Int
        /// Whether retries are currently refused.
        public let locked: Bool
        /// Creates ordinary waiting data.
        public init(attempts: Int, locked: Bool) {
            self.attempts = attempts
            self.locked = locked
        }
    }
    /// Another attempt in progress.
    public struct Trying: Sendable {
        /// The number of this attempt.
        public let attempt: Int
        /// Creates ordinary attempt data.
        public init(attempt: Int) { self.attempt = attempt }
    }
    /// The workflow stopped retrying.
    public struct GaveUp: Sendable {
        /// Attempts made before stopping.
        public let attempts: Int
        /// Creates ordinary final data.
        public init(attempts: Int) { self.attempts = attempts }
    }
    @Initial case waiting(Waiting)
    @Terminal case trying(Trying)
    @Terminal case gaveUp(GaveUp)
    /// Closed dynamic inputs.
    public enum Input: Sendable { case retry }
    /// Why the router declined to retry.
    public enum Refusal: Error, Sendable { case locked }
    /// The most attempts before the workflow stops.
    public static let limit = 3
    /// Starts another attempt.
    @Transition(on: Input.retry)
    fileprivate static func again(_ source: Waiting) -> Trying { Trying(attempt: source.attempts + 1) }
    /// Stops after the last allowed attempt.
    @Transition(on: Input.retry)
    fileprivate static func giveUp(_ source: Waiting) -> GaveUp { GaveUp(attempts: source.attempts) }
    /// Refuses while locked, then retries until the limit.
    @Route(on: Input.retry)
    fileprivate static func decide(_ source: Waiting) throws(Refusal) -> Route.Decide {
        guard !source.locked else { throw .locked }
        return source.attempts < limit ? .again : .giveUp
    }
}
