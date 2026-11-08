import StateMachine
import StateMachineSchema

/// A generated profile workflow with typed operations and sealed host authority.
@StateMachine(mode: .shared, initial: "idle", scopes: ["load", "authentication"])
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
    case idle(Idle)
    case loading(Loading)
    case loaded(Loaded)
    case failed(Failed)
    /// Closed dynamic inputs.
    public enum Input: Sendable {
        case load(ProfileRequest)
        case cancel
        case authenticationChanged
        case refresh(ProfileRequest)
        case retry
        case audit(String)
    }
    /// Ordered inert operation descriptions.
    public enum Effect: Sendable {
        case fetch(Fetch.Input)
        case audit(Audit.Input)
    }
    /// Typed request validation.
    public enum LoadRejection: Error { case wrongUser }
    /// The profile fetch operation.
    @Operation(effect: "fetch", scope: "load", requires: ["authentication"], activeIn: ["loading"], admission: .latest)
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
        effect: "audit",
        scope: "load",
        requires: ["authentication"],
        activeIn: ["loading"],
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
    @Transition(from: "idle", to: "loading", on: .input("load"), invalidates: ["load"], starts: ["fetch"])
    fileprivate static func begin(
        _ source: borrowing Idle,
        _ request: ProfileRequest
    ) throws(LoadRejection) -> Change<Loading, Effect> {
        guard source.userID == request.userID else { throw .wrongUser }
        return Change(Loading(request: request), effects: [.fetch(request)])
    }
    /// Cancels the active load epoch.
    @Transition(from: "loading", to: "idle", on: .input("cancel"), invalidates: ["load"])
    fileprivate static func cancel(_ source: borrowing Loading) -> Change<Idle, Effect> {
        Change(Idle(userID: source.request.userID))
    }
    /// Accepts a successful fetch.
    @Transition(from: "loading", to: "loaded", on: .success("fetch"))
    fileprivate static func received(_ source: borrowing Loading, _ output: Fetch.Output) -> Change<Loaded, Effect> {
        Change(Loaded(profile: output))
    }
    /// Accepts a failed fetch.
    @Transition(from: "loading", to: "failed", on: .failure("fetch"))
    fileprivate static func failed(_ source: borrowing Loading, _ failure: Fetch.Failure) -> Change<Failed, Effect> {
        Change(Failed(request: source.request, failure: failure))
    }
    /// Rotates a dependency epoch without replacing the visible phase.
    @Transition(from: "loading", to: "loading", on: .input("authenticationChanged"), invalidates: ["authentication"])
    fileprivate static func authenticationChanged(_ source: borrowing Loading) -> Change<Loading, Effect> {
        Change(copy source)
    }
    /// Starts a refresh only for the loaded user.
    @Transition(from: "loaded", to: "loading", on: .input("refresh"), invalidates: ["load"], starts: ["fetch"])
    fileprivate static func refresh(
        _ source: borrowing Loaded,
        _ request: ProfileRequest
    ) throws(LoadRejection) -> Change<Loading, Effect> {
        guard source.profile.userID == request.userID else { throw .wrongUser }
        return Change(Loading(request: request), effects: [.fetch(request)])
    }
    /// Restarts the retained request.
    @Transition(from: "failed", to: "loading", on: .input("retry"), invalidates: ["load"], starts: ["fetch"])
    fileprivate static func retry(_ source: borrowing Failed) -> Change<Loading, Effect> {
        Change(Loading(request: source.request), effects: [.fetch(source.request)])
    }
    /// Starts an independent audit while the load scope remains eligible.
    @Transition(from: "loading", to: "loading", on: .input("audit"), starts: ["audit"])
    fileprivate static func audit(_ source: borrowing Loading, _ input: String) -> Change<Loading, Effect> {
        Change(copy source, effects: [.audit(input)])
    }
    /// Acknowledges audit success without changing profile data.
    @Transition(from: "loading", to: "loading", on: .success("audit"))
    fileprivate static func audited(_ source: borrowing Loading, _ output: Audit.Output) -> Change<Loading, Effect> {
        Change(copy source)
    }
    /// Acknowledges audit failure without changing profile data.
    @Transition(from: "loading", to: "loading", on: .failure("audit"))
    fileprivate static func auditFailed(
        _ source: borrowing Loading,
        _ failure: Audit.Failure
    ) -> Change<Loading, Effect> { Change(copy source) }
}
