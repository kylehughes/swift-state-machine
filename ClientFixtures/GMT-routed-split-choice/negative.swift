// Same router name across phases with different routed: shapes does not generate a shared Route.Choose.
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum SplitChoiceRefused: Sendable {
    struct Alpha: Sendable {}
    struct Beta: Sendable {}
    struct Done: Sendable {}
    @Initial case alpha(Alpha = Alpha())
    case beta(Beta)
    @Terminal case done(Done)
    enum Input: Sendable { case step }

    @Transition(on: Input.step)
    fileprivate static func go(_ source: Alpha, routed count: Int) -> Beta { Beta() }
    @Transition(on: Input.step)
    fileprivate static func stay(_ source: Alpha) -> Alpha { source }
    @Route(on: Input.step)
    fileprivate static func choose(_ source: Alpha) -> Route.Choose { .go(1) }

    @Transition(on: Input.step)
    fileprivate static func go(_ source: Beta, routed label: String) -> Done { Done() }
    @Transition(on: Input.step)
    fileprivate static func stay(_ source: Beta) -> Beta { source }
    @Route(on: Input.step)
    fileprivate static func choose(_ source: Beta) -> Route.Beta.Choose { .go("ok") }
}
