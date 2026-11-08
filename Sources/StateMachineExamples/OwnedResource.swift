import StateMachine

/// An owned-only graph whose resource is never admitted to shared speculative storage.
nonisolated public enum ResourceWorkflow {
    /// A unique resource with explicit disposal instrumentation.
    public struct Resource: ~Copyable {
        /// The unique resource identifier.
        public let identifier: Int
        private let release: @Sendable (Int) -> Void
        /// Creates a unique resource with a disposal callback.
        public init(identifier: Int, onRelease: @escaping @Sendable (Int) -> Void) {
            self.identifier = identifier
            release = onRelease
        }
        deinit { release(identifier) }
    }
    /// The phase owning a resource before completion.
    public struct Ready: ~Copyable { fileprivate let resource: Resource }
    /// The completed phase that still uniquely owns its resource.
    public struct Finished: ~Copyable {
        fileprivate let resource: Resource
        /// The completion label.
        public let label: String
    }
    /// Unique authority over one workflow phase.
    public struct Owned<Phase: ~Copyable>: ~Copyable {
        fileprivate let phase: Phase
        fileprivate init(_ phase: consuming Phase) { self.phase = phase }
        /// Borrows the payload for a nonescaping synchronous read.
        public borrowing func withValue<Result>(_ body: (borrowing Phase) -> Result) -> Result { body(phase) }
    }
    /// Ordered inert descriptions for explicit caller execution.
    public enum Effect: Equatable, Sendable {
        case audit(Int)
        case publish(String)
    }
    /// A recoverable resource transition rejection.
    public enum Rejection: Error, Sendable { case emptyLabel }
    /// Consumes a resource into the declared initial phase.
    public static func start(_ resource: consuming Resource) -> Owned<Ready> { Owned(Ready(resource: resource)) }
}

extension ResourceWorkflow.Owned where Phase == ResourceWorkflow.Ready {
    /// Consumes the predecessor, preserving it on empty-label rejection.
    public consuming func finish(
        label: String
    ) -> Advance<
        Self, ResourceWorkflow.Owned<ResourceWorkflow.Finished>, ResourceWorkflow.Effect, ResourceWorkflow.Rejection
    > {
        guard !label.isEmpty else { return .rejected(.emptyLabel, self) }
        let identifier = phase.resource.identifier
        return .advanced(
            ResourceWorkflow.Owned(ResourceWorkflow.Finished(resource: phase.resource, label: label)),
            effects: [.audit(identifier), .publish(label)]
        )
    }
}

extension ResourceWorkflow.Ready {
    /// The unique resource identifier.
    public var identifier: Int { resource.identifier }
}
extension ResourceWorkflow.Finished {
    /// The unique resource identifier.
    public var identifier: Int { resource.identifier }
}
