// A completion trigger cannot list source phases.
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
    @Transition(from: [Loading.self], onSuccess: Fetch.self)
    fileprivate static func fetched(_ output: Fetch.Output) -> Loaded { Loaded() }
}
