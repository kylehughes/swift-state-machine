// Another actor may read the key, which is Sendable, and whether the call is finished.
import StateMachine
import StateMachineTesting

actor Desk {
    let save = KeyedIsolatedControlledDriver<Desk, Int, Int, Int, Never>()
}

@MainActor final class Window {
    func finish(_ call: KeyedIsolatedControlledDriver<Desk, Int, Int, Int, Never>.Call) {
        _ = (call.key, call.isFinished, call.isCancelled)
    }
}
