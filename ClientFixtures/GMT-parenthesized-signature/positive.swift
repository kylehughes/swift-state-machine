import StateMachine

// Swift reads a type in single unlabeled parentheses as that type, so each parenthesized spelling
// below declares what its plain spelling declares.
@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum Review: Sendable {
    struct Draft: Sendable { var title = "" }
    struct Checking: Sendable { var title: String }
    struct Approved: Sendable { var title: String }
    @Initial case draft((Draft) = Draft())
    case checking(((Review.Checking)))
    @Terminal case approved((Self).Approved)
    enum Input: Sendable { case submit((String)), decide }
    @Operation(activeIn: [Checking.self])
    enum Check { typealias Input = (String); typealias Output = (Bool) }
    @Event
    enum Submitted { typealias Payload = (String) }
    @Transition(on: Input.submit, starts: [Check.self], emits: [Submitted.self])
    fileprivate static func submit(_ source: (Draft), _ title: (String)) -> (Change<(Checking), (Effect).Submit>) {
        Change(Checking(title: title), effects: [.check(title), .submitted(title)])
    }
    @Transition(onSuccess: Check.self)
    fileprivate static func checked(_ source: borrowing (Checking), _ passed: (Bool)) -> ((Self).Checking) {
        Checking(title: source.title)
    }
    @Route(on: Input.decide)
    fileprivate static func decide(_ source: (borrowing Checking)) -> ((Route).Decide) { .approve }
    @Transition(on: Input.decide)
    fileprivate static func approve(_ source: (Review).Checking) -> ((Approved)) { Approved(title: source.title) }
    @Transition(on: Input.decide)
    fileprivate static func reopen(_ source: Checking) -> (Self.Draft) { Draft(title: source.title) }
}

func submitDraft() -> String {
    let change = Review.owned().submit("Launch")
    _ = change.next.decide()
    var local = Review.Local()
    _ = try? local.send(.submit("Launch"))
    return "\(change.effects.count)"
}
