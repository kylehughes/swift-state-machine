// The owning actor finishes a call with a value that shares state with its input.
import StateMachine
import StateMachineTesting

final class Draft { var text = "" }

nonisolated final class Cleanup {
    let call: IsolatedControlledDriver<Desk, Draft, Draft, Never>.Call
    init(_ call: IsolatedControlledDriver<Desk, Draft, Draft, Never>.Call) { self.call = call }
}

actor Desk {
    let save = IsolatedControlledDriver<Desk, Draft, Draft, Never>()
    let open = KeyedIsolatedControlledDriver<Desk, Int, Draft, Draft, Never>()
    private var cleanup: Cleanup?

    func finish() async throws {
        let call = try await save.nextStarted()
        // The output may share state with the input: it stays on this actor.
        call.succeed(call.input())
        let keyed = try await open.nextStarted(for: 1)
        keyed.succeed(keyed.input())
        cleanup = Cleanup(try await save.nextStarted())
    }
}
