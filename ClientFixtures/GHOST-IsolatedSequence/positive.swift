import StateMachine
import StateMachineExamples
import StateMachineUI

@MainActor func legal(_ owner: GeneratedNote.MainActorHost) async throws {
    for await snapshot in try owner.snapshots() { print(snapshot.revision) }
}
