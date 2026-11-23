// In .isolated mode, marking a non-Sendable routed: parameter sending fails the generated Sendable check.
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned, .local])
nonisolated enum IsolatedSendingRoutedRefused {
    final class Box {
        let value: Int
        init(_ value: Int) { self.value = value }
    }
    struct Ready {}
    struct Done { let value: Int }
    @Initial case ready(Ready = Ready())
    @Terminal case done(Done)
    enum Input { case go }

    @Transition(on: Input.go)
    fileprivate static func take(_ source: Ready, routed box: sending Box) -> Done { Done(value: box.value) }
    @Transition(on: Input.go)
    fileprivate static func stay(_ source: Ready) -> Ready { source }
    @Route(on: Input.go)
    fileprivate static func choose(_ source: Ready) -> Route.Choose { .take(Box(1)) }
}
