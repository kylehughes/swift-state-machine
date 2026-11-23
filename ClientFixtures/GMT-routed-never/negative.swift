// A routed: payload aliasing Never fails the generated Never probe.
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum RoutedNeverRefused: Sendable {
    typealias Impossible = Never
    struct Ready: Sendable {}
    struct Done: Sendable {}
    @Initial case ready(Ready = Ready())
    @Terminal case done(Done)
    enum Input: Sendable { case go }

    @Transition(on: Input.go)
    fileprivate static func take(_ source: Ready, routed value: Impossible) -> Done { Done() }
    @Transition(on: Input.go)
    fileprivate static func stay(_ source: Ready) -> Ready { source }
    @Route(on: Input.go)
    fileprivate static func choose(_ source: Ready) -> Route.Choose { .stay }
}
