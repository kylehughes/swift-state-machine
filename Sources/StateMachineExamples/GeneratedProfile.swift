import StateMachine

/// A generated profile workflow with typed operations and sealed host authority.
@StateMachine(mode: .shared)
nonisolated public enum GeneratedProfile: Sendable {
    /// Initial user data.
    public struct Idle: Sendable {
        /// The validated user identifier.
        public let userID: UserID
        /// Creates ordinary model data without installation authority.
        public init(userID: UserID) { self.userID = userID }
    }
    /// An in-flight request.
    public struct Loading: Sendable {
        /// The immutable request.
        public let request: ProfileRequest
        /// Creates ordinary in-flight data.
        public init(request: ProfileRequest) { self.request = request }
    }
    /// A successful response.
    public struct Loaded: Sendable {
        /// The immutable profile.
        public let profile: Profile
        /// Creates ordinary loaded data.
        public init(profile: Profile) { self.profile = profile }
    }
    /// A failed request and reason.
    public struct Failed: Sendable {
        /// The immutable original request.
        public let request: ProfileRequest
        /// The typed network failure.
        public let failure: ProfileFailure
        /// Creates ordinary failure data.
        public init(request: ProfileRequest, failure: ProfileFailure) {
            self.request = request
            self.failure = failure
        }
    }
    @Initial case idle(Idle)
    case loading(Loading)
    case loaded(Loaded)
    case failed(Failed)
    /// Authority that edges invalidate and operations hold.
    enum Scope { case load, authentication }
    /// Closed dynamic inputs.
    public enum Input: Sendable {
        case load(ProfileRequest)
        case cancel
        case authenticationChanged
        case refresh(ProfileRequest)
        case retry
        case audit(String)
    }
    /// Typed request validation.
    public enum LoadRejection: Error { case wrongUser }
    /// Saved profile data, without provenance or operation authority.
    public enum Archive: Sendable {
        /// A user whose profile was not loaded.
        case idle(UserID)
        /// A request that was in flight when the data was saved.
        case loading(ProfileRequest)
        /// A loaded profile.
        case loaded(Profile)
        /// A request and the reason it failed.
        case failed(ProfileRequest, ProfileFailure)
    }
    /// Why saved data cannot be restored.
    public enum RestoreRejection: Error, Sendable {
        /// The saved request has no task to resume; restoring cannot fabricate one.
        case interruptedLoading
    }
    /// Validates saved data into a resting phase, rejecting an interrupted load.
    @Restoration
    fileprivate static func restore(_ saved: Archive) throws(RestoreRejection) -> Restoration {
        switch saved {
        case .idle(let userID): return .idle(Idle(userID: userID))
        case .loading: throw .interruptedLoading
        case .loaded(let profile): return .loaded(Loaded(profile: profile))
        case .failed(let request, let failure): return .failed(Failed(request: request, failure: failure))
        }
    }
    /// The profile fetch operation.
    @Operation(scope: Scope.load, requires: [Scope.authentication], activeIn: [Loading.self], admission: .latest)
    public enum Fetch {
        /// The immutable fetch input.
        public typealias Input = ProfileRequest
        /// The successful fetch value.
        public typealias Output = Profile
        /// The network failure value.
        public typealias Failure = ProfileFailure
    }
    /// An independent operation with different work and completion types.
    @Operation(
        scope: Scope.load,
        requires: [Scope.authentication],
        activeIn: [Loading.self],
        admission: .parallel(limit: 2)
    )
    public enum Audit {
        /// The immutable audit input.
        public typealias Input = String
        /// The successful audit value.
        public typealias Output = Profile
        /// The failed audit value.
        public typealias Failure = ProfileFailure
    }
    /// Starts a fetch only for the initial user.
    @Transition(on: Input.load, starts: [Fetch.self])
    fileprivate static func begin(
        _ source: Idle,
        _ request: ProfileRequest
    ) throws(LoadRejection) -> Change<Loading, Effect.Begin> {
        guard source.userID == request.userID else { throw .wrongUser }
        return Change(Loading(request: request), effects: [.fetch(request)])
    }
    /// Cancels the load: leaving `Loading` revokes the work that was active there.
    @Transition(on: Input.cancel)
    fileprivate static func cancel(_ source: Loading) -> Idle {
        Idle(userID: source.request.userID)
    }
    /// Accepts a successful fetch.
    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Loading, _ output: Fetch.Output) -> Loaded {
        Loaded(profile: output)
    }
    /// Accepts a failed fetch.
    @Transition(onFailure: Fetch.self)
    fileprivate static func failed(_ source: Loading, _ failure: Fetch.Failure) -> Failed {
        Failed(request: source.request, failure: failure)
    }
    /// Rotates a dependency epoch without replacing the visible phase.
    @Transition(on: Input.authenticationChanged, invalidates: [Scope.authentication])
    fileprivate static func authenticationChanged(_ source: Loading) -> Loading {
        source
    }
    /// Starts a refresh only for the loaded user.
    @Transition(on: Input.refresh, starts: [Fetch.self])
    fileprivate static func refresh(
        _ source: Loaded,
        _ request: ProfileRequest
    ) throws(LoadRejection) -> Change<Loading, Effect.Refresh> {
        guard source.profile.userID == request.userID else { throw .wrongUser }
        return Change(Loading(request: request), effects: [.fetch(request)])
    }
    /// Restarts the retained request.
    @Transition(on: Input.retry, starts: [Fetch.self])
    fileprivate static func retry(_ source: Failed) -> Change<Loading, Effect.Retry> {
        Change(Loading(request: source.request), effects: [.fetch(source.request)])
    }
    /// Starts an independent audit while the load scope remains eligible.
    @Transition(on: Input.audit, starts: [Audit.self])
    fileprivate static func audit(_ source: Loading, _ input: String) -> Change<Loading, Effect.Audit> {
        Change(source, effects: [.audit(input)])
    }
    /// Acknowledges audit success without changing profile data.
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: Loading, _ output: Audit.Output) -> Loading {
        source
    }
    /// Acknowledges audit failure without changing profile data.
    @Transition(onFailure: Audit.self)
    fileprivate static func auditFailed(
        _ source: Loading,
        _ failure: Audit.Failure
    ) -> Loading { source }
}
