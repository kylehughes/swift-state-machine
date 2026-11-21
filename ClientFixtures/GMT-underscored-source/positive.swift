import StateMachine

// `__shared` lends a source as `borrowing` does, and `__owned` takes it as its own as `consuming` does.
@StateMachine(mode: .shared)
nonisolated enum Review: Sendable {
    struct Draft: Sendable { var title = "" }
    struct Checking: Sendable { var title: String }
    struct Approved: Sendable { var title: String }
    @Initial case draft(Draft = Draft())
    case checking(Checking)
    @Terminal case approved(Approved)
    enum Input: Sendable { case submit(String), decide }
    @Operation(activeIn: [Checking.self])
    enum Check { typealias Output = Bool }
    @Transition(on: Input.submit, starts: [Check.self])
    fileprivate static func submit(_ source: __shared Draft, _ title: String) -> Change<Checking, Effect.Submit> {
        Change(Checking(title: title), effects: [.check])
    }
    @Route(onSuccess: Check.self)
    fileprivate static func screen(_ source: __shared Checking, _ passed: Bool) -> Route.Screen {
        passed ? .checked : .reverted
    }
    @Transition(onSuccess: Check.self)
    fileprivate static func checked(_ source: __shared Checking, _ passed: Bool) -> Checking { source }
    @Transition(onSuccess: Check.self)
    fileprivate static func reverted(_ source: __shared Checking, _ passed: Bool) -> Draft { Draft(title: source.title) }
    @Route(on: Input.decide)
    fileprivate static func decide(_ source: __shared Checking) -> Route.Decide { .approve }
    @Transition(on: Input.decide)
    fileprivate static func approve(_ source: __shared Checking) -> Approved { Approved(title: source.title) }
    @Transition(on: Input.decide)
    fileprivate static func reopen(_ source: __shared Checking) -> Draft { Draft(title: source.title) }
}

@StateMachine(mode: .ownedOnly)
nonisolated enum Token: ~Copyable {
    struct Ready: ~Copyable { var value = 5 }
    struct Spent: ~Copyable { var value: Int }
    enum Refusal: Error { case tooSmall }
    @Initial case ready(Ready)
    @Terminal case spent(Spent)
    enum Input { case spend, attempt }
    @Transition(on: Input.spend)
    fileprivate static func spend(_ source: __owned Ready) -> Spent { Spent(value: source.value) }
    @Transition(on: Input.attempt)
    fileprivate static func attempt(_ source: __owned Ready) -> Advance<Ready, Spent, Never, Refusal> {
        source.value > 3 ? .advanced(Spent(value: source.value), effects: []) : .rejected(.tooSmall, source)
    }
}

func spendToken() -> Int {
    let spent = Token.owned(Token.Ready()).spend()
    return spent.withValue { $0.value }
}

func approveDraft() -> String {
    var local = Review.Local()
    _ = try? local.send(.submit("Launch"))
    let change = Review.owned().submit("Launch")
    return "\(change.effects.count)"
}
