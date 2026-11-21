import StateMachine
import StateMachineExamples
import StateMachineUI

@MainActor func misuse(_ host: GeneratedNote.MainActorHost) throws {
    _ = try host.pendingCompletionUpdates { $0 }
}
