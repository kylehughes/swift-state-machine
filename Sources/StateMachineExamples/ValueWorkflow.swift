import StateMachine

/// A value-only ownership fixture with two distinct inert effect descriptions.
nonisolated public enum ValueWorkflow {
    /// The declared initial phase data.
    public struct Ready: Sendable {
        /// The source value.
        public let value: Int
        /// Creates ordinary initial data.
        public init(value: Int) { self.value = value }
    }
    /// The complete successor data.
    public struct Finished: Sendable {
        /// The preserved value.
        public let value: Int
        /// The preserved label.
        public let label: String
    }
    /// Ordered inert descriptions, without hosted execution authority.
    public enum Effect: Equatable, Sendable {
        case audit(Int)
        case publish(String)
    }
    /// Unique authority over a workflow phase.
    public struct Owned<Phase: ~Copyable>: ~Copyable {
        fileprivate let phase: Phase
        fileprivate init(_ phase: consuming Phase) { self.phase = phase }
        /// Borrows the payload for a synchronous nonescaping read.
        public borrowing func withValue<Result>(_ body: (borrowing Phase) -> Result) -> Result { body(phase) }
    }
    /// Creates unique authority only for the declared initial phase.
    public static func start(_ initial: Ready) -> Owned<Ready> { Owned(initial) }
}

extension ValueWorkflow.Owned where Phase == ValueWorkflow.Ready {
    /// Returns the whole successor and both inert effects in authored order.
    public consuming func finish(
        label: String
    ) -> Change<ValueWorkflow.Owned<ValueWorkflow.Finished>, ValueWorkflow.Effect> {
        Change(
            ValueWorkflow.Owned(ValueWorkflow.Finished(value: phase.value, label: label)),
            effects: [.audit(phase.value), .publish(label)]
        )
    }
}
