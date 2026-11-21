// The main actor is not the owning actor, so it cannot finish the call.
import StateMachine
import StateMachineTesting

actor Desk {
    let save = KeyedIsolatedControlledDriver<Desk, Int, Int, Int, Never>()
}

@MainActor final class Window {
    func finish(_ call: KeyedIsolatedControlledDriver<Desk, Int, Int, Int, Never>.Call) {
        call.succeed(1)
    }
}
