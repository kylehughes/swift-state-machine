import StateMachine
import StateMachineExamples
import StateMachineUI

@MainActor func misuse(_ note: GeneratedNote.MainActorHost) async throws {
    for await revision in try note.snapshots().map({ $0.revision }) { print(revision) }
}
