/// Validated count bounds for a managed owner and its callback registrations.
///
/// Local manual ownership uses `RuntimeLimits` directly and has no subscription bound.
nonisolated public struct RuntimeManagedConfiguration: Sendable {
    /// The immutable admission, plan and physical execution bounds.
    public let limits: RuntimeLimits
    /// The maximum number of live serial callback registrations.
    public let subscriberCapacity: Int
    /// The documented defaults: 256 batches, 64 descriptors, 256 executions and 128 subscriptions.
    public static let `default` = RuntimeManagedConfiguration(validatedLimits: .default, subscribers: 128)

    private init(validatedLimits: RuntimeLimits, subscribers: Int) {
        limits = validatedLimits
        subscriberCapacity = subscribers
    }
    /// Validates positive admission, plan, execution and subscription capacities.
    public init(
        commits: Int = 256,
        descriptors: Int = 64,
        executions: Int = 256,
        subscribers: Int = 128
    ) throws(RuntimeLimits.Failure) {
        try self.init(
            limits: RuntimeLimits(commits: commits, descriptors: descriptors, executions: executions),
            subscribers: subscribers
        )
    }
    /// Combines validated value-engine bounds with a checked positive subscription bound.
    public init(limits: RuntimeLimits, subscribers: Int = 128) throws(RuntimeLimits.Failure) {
        guard subscribers > 0 else { throw .nonpositiveCapacity }
        self.limits = limits
        subscriberCapacity = subscribers
    }
}
