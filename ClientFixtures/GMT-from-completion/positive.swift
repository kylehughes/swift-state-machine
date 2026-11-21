// A completion edge names its source phase in its first parameter.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Session: Sendable {
    struct SignedOut: Sendable {}
    struct Loading: Sendable {}
    struct Loaded: Sendable {}
    @Initial case signedOut(SignedOut)
    case loading(Loading)
    case loaded(Loaded)
    enum Input: Sendable { case signIn, signOut }
    @Operation(activeIn: [Loading.self])
    enum Fetch {}
    @Transition(on: Input.signIn, starts: [Fetch.self])
    fileprivate static func signIn(_ source: SignedOut) -> Change<Loading, Effect.SignIn> {
        Change(Loading(), effects: [.fetch])
    }
    @Transition(from: [Loading.self, Loaded.self], on: Input.signOut)
    fileprivate static func signOut() -> SignedOut { SignedOut() }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func fetched(_ source: Loading) -> Loaded { Loaded() }
}
nonisolated func accepted(_ loaded: Session.Observed<Session.Loaded>) -> Session.Prepared { loaded.signOut() }
