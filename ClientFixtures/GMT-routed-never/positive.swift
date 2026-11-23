// A routed: payload naming an inhabited type alias compiles cleanly.
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum RoutedNeverControl: Sendable {
    typealias Payload = Int
    struct Ready: Sendable {}
    struct Done: Sendable {}
    @Initial case ready(Ready = Ready())
    @Terminal case done(Done)
    enum Input: Sendable { case go }

    @Transition(on: Input.go)
    fileprivate static func take(_ source: Ready, routed value: Payload) -> Done { Done() }
    @Transition(on: Input.go)
    fileprivate static func stay(_ source: Ready) -> Ready { source }
    @Route(on: Input.go)
    fileprivate static func choose(_ source: Ready) -> Route.Choose { .take(1) }
}
