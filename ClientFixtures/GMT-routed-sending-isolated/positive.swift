// In .isolated mode, a non-Sendable routed: value compiles without sending, and a Sendable one compiles with sending.
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned, .local])
nonisolated enum IsolatedSendingRoutedControl {
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
    fileprivate static func take(_ source: Ready, routed box: Box) -> Done { Done(value: box.value) }
    @Transition(on: Input.go)
    fileprivate static func stay(_ source: Ready) -> Ready { source }
    @Route(on: Input.go)
    fileprivate static func choose(_ source: Ready) -> Route.Choose { .take(Box(1)) }
}
