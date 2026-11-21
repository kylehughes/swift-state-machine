import StateMachine
import StateMachineExamples
import StateMachineUI

@MainActor func legal(_ host: GeneratedNote.MainActorHost) async throws {
    for await count in try host.pendingCompletionUpdates({ $0.count }).map({ $0 * 2 }).prefix(1) { print(count) }
}
