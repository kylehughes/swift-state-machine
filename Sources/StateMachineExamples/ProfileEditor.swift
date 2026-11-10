import StateMachine
import StateMachineUI

/// Screen-scoped profile editing and navigation ownership using the generated public facade.
///
/// A returning screen constructs a new editor. Disposed historical loading data does
/// not authorize resurrecting an earlier request.
@MainActor public final class ProfileEditor {
    /// The complete `MainActor` snapshot projected through an `ObservableObject`.
    public let presentation: SnapshotPresentation<GeneratedProfile.Snapshot>
    private let machine: GeneratedProfile.MainActorHost
    private let request: ProfileRequest

    /// Creates a screen with immutable execution dependencies; initialization starts no request.
    public init(
        request: ProfileRequest,
        drivers: GeneratedProfile.MainActorDrivers,
        configuration: GeneratedProfile.Configuration = .default
    ) throws(RuntimeHostSubscriptionFailure) {
        self.request = request
        let machine = GeneratedProfile.MainActorHost(
            .init(userID: request.userID),
            drivers: drivers,
            configuration: configuration
        )
        self.machine = machine
        presentation = SnapshotPresentation(machine.snapshot(), revision: { $0.revision })
        try presentation.observe {
            (receive, finish) throws(RuntimeHostSubscriptionFailure) -> RuntimeMainActorSubscription in
            try machine.subscribe(receive, onFinish: finish)
        }
    }
    /// Accepts a load immediately in this MainActor turn and publishes its receipt synchronously.
    @discardableResult public func load() throws(GeneratedProfile.PreparationRejection) -> GeneratedProfile.CommitResult
    {
        try send(.load(request))
    }
    /// Refreshes a loaded profile using a newly materialized request value.
    @discardableResult public func refresh(
        _ request: ProfileRequest
    ) throws(GeneratedProfile.PreparationRejection) -> GeneratedProfile.CommitResult {
        try send(.refresh(request))
    }
    /// Retries the current typed failure.
    @discardableResult public func retry() throws(GeneratedProfile.PreparationRejection)
        -> GeneratedProfile.CommitResult
    {
        try send(.retry)
    }
    /// Revokes the current request while preserving independent historical data.
    @discardableResult public func cancel() throws(GeneratedProfile.PreparationRejection)
        -> GeneratedProfile.CommitResult
    {
        try send(.cancel)
    }
    /// Invalidates the account dependency before a late response can be admitted.
    @discardableResult public func accountChanged() throws(GeneratedProfile.PreparationRejection)
        -> GeneratedProfile.CommitResult
    {
        try send(.authenticationChanged)
    }
    private func send(
        _ input: GeneratedProfile.Input
    ) throws(GeneratedProfile.PreparationRejection) -> GeneratedProfile.CommitResult {
        let result = try machine.send(input)
        if case .committed(let receipt) = result { presentation.apply(receipt.snapshot) }
        return result
    }
    /// Navigates away by removing observation and closing this screen's work authority.
    public func dispose() {
        presentation.stopObserving()
        let receipt = machine.close()
        presentation.apply(receipt.snapshot)
    }
    /// Disposes and waits for actual task termination, independently of visible navigation.
    public func shutdown() async {
        dispose()
        await machine.shutdown()
    }
    /// Whether this screen's actual work and delivery obligations have settled.
    public var isQuiescent: Bool { machine.isQuiescent }
}
