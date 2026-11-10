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
extension Change: Sendable where Next: Sendable, Effect: Sendable {}

/// A consuming transition that preserves its predecessor on recoverable rejection.
@frozen nonisolated public enum Advance<Before: ~Copyable, After: ~Copyable, Effect, Failure: Error>: ~Copyable {
    /// The successor and the exact ordered effect descriptions.
    case advanced(After, effects: [Effect])
    /// A recoverable failure and the original predecessor.
    case rejected(Failure, Before)
}

/// A state-independent defect in an inert effect plan.
nonisolated public enum PlanRejection: Error, Equatable, Sendable {
    /// The plan violates the declared operation metadata.
    case invalidPlan
    /// The plan alone exceeds a configured maximum.
    case planTooLarge
}

/// Separates authored validation failure from permanent plan failure.
@frozen nonisolated public enum PreparationFailure<DomainFailure: Error>: Error {
    /// Authored domain validation failed.
    case domain(DomainFailure)
    /// The effect plan cannot be admitted, even after capacity becomes available.
    case plan(PlanRejection)
}

extension PreparationFailure: Equatable where DomainFailure: Equatable {}
