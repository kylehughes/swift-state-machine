import StateMachine
import StateMachineUI

/// Screen-scoped profile editing and navigation ownership using the generated public facade.
///
/// A returning screen constructs a new editor. Disposed historical loading data does
/// not authorize resurrecting an earlier request.
@MainActor public final class ProfileEditor {
    /// The owner's complete snapshot, published through an `ObservableObject`.
    public let presentation: StateMachineObservableObject<GeneratedProfile.MainActorHost>
    private let request: ProfileRequest

    /// Creates a screen with immutable execution dependencies without starting a request.
    public init(
        request: ProfileRequest,
        drivers: GeneratedProfile.MainActorDrivers,
        configuration: GeneratedProfile.Configuration = .default
    ) {
        self.request = request
        presentation = StateMachineObservableObject(
            GeneratedProfile.MainActorHost(
                GeneratedProfile.Idle(userID: request.userID),
                drivers: drivers,
                configuration: configuration
            )
        )
    }
    /// Accepts a load immediately in this `MainActor` turn and publishes its receipt synchronously.
    @discardableResult public func load() throws(GeneratedProfile.SendRejection) -> GeneratedProfile.Receipt {
        try presentation.send(.load(request))
    }
    /// Refreshes a loaded profile using a newly materialized request value.
    @discardableResult public func refresh(
        _ request: ProfileRequest
    ) throws(GeneratedProfile.SendRejection) -> GeneratedProfile.Receipt {
        try presentation.send(.refresh(request))
    }
    /// Retries the current typed failure.
    @discardableResult public func retry() throws(GeneratedProfile.SendRejection) -> GeneratedProfile.Receipt {
        try presentation.send(.retry)
    }
    /// Revokes the current request while preserving independent historical data.
    @discardableResult public func cancel() throws(GeneratedProfile.SendRejection) -> GeneratedProfile.Receipt {
        try presentation.send(.cancel)
    }
    /// Invalidates the account dependency before a late response can be admitted.
    @discardableResult public func accountChanged() throws(GeneratedProfile.SendRejection)
        -> GeneratedProfile.Receipt
    {
        try presentation.send(.authenticationChanged)
    }
    /// Navigates away by removing observation and closing this screen's work authority.
    public func dispose() { presentation.close() }
    /// Disposes and waits for actual task termination, independently of visible navigation.
    public func shutdown() async {
        dispose()
        await presentation.host.shutdown()
    }
    /// Whether this screen's actual work and delivery obligations have settled.
    public var isQuiescent: Bool { presentation.host.isQuiescent }
}
