/// Validated count bounds for a managed owner and its callback registrations.
///
/// Local manual ownership uses `Limits` directly and has no subscription bound.
nonisolated public struct ManagedConfiguration: Sendable {
    /// The immutable admission, plan, and physical execution bounds.
    public let limits: Limits
    /// The maximum number of live serial callback registrations.
    public let subscriberCapacity: Int
    /// The documented defaults: 256 batches, 64 descriptors, 256 executions, and 128 subscriptions.
    public static let `default` = ManagedConfiguration(validatedLimits: .default, subscribers: 128)

    private init(validatedLimits: Limits, subscribers: Int) {
        limits = validatedLimits
        subscriberCapacity = subscribers
    }
    /// Validates positive admission, plan, execution, and subscription capacities.
    public init(
        commits: Int = 256,
        descriptors: Int = 64,
        executions: Int = 256,
        subscribers: Int = 128
    ) throws(Limits.Failure) {
        try self.init(
            limits: Limits(commits: commits, descriptors: descriptors, executions: executions),
            subscribers: subscribers
        )
    }
    /// Combines validated value-engine bounds with a checked positive subscription bound.
    public init(limits: Limits, subscribers: Int = 128) throws(Limits.Failure) {
        guard subscribers > 0 else { throw .nonpositiveCapacity }
        self.limits = limits
        subscriberCapacity = subscribers
    }
}
