/// A synchronous domain change and its ordered, inert effect descriptions.
@frozen nonisolated public struct Change<Next: ~Copyable, Effect>: ~Copyable {
    /// The successor payload.
    public let next: Next
    /// Effects in authored order; constructing a change executes none of them.
    public let effects: [Effect]

    /// Creates a change without executing effects.
    public init(_ next: consuming Next, effects: [Effect] = []) {
        self.next = next
        self.effects = effects
    }
}

extension Change: Copyable where Next: Copyable {}
extension Change: Sendable where Next: Sendable & ~Copyable, Effect: Sendable {}

/// A consuming transition that preserves its predecessor on recoverable rejection.
@frozen nonisolated public enum Advance<Before: ~Copyable, After: ~Copyable, Effect, Failure: Error>: ~Copyable {
    /// The successor and the exact ordered effect descriptions.
    case advanced(After, effects: [Effect])
    /// A recoverable failure and the original predecessor.
    case rejected(Failure, Before)
}

extension Advance: Sendable where Before: Sendable & ~Copyable, After: Sendable & ~Copyable, Effect: Sendable {}

/// A defect in an inert effect plan, found while preparing it.
nonisolated public enum PlanRejection: Error, Equatable, Sendable {
    /// The plan is malformed, or starts an operation whose scope or dependency it leaves inactive.
    case invalidPlan
    /// The plan alone exceeds a configured maximum.
    case planTooLarge
}
