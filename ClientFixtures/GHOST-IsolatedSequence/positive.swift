import StateMachine
import StateMachineExamples
import StateMachineUI

@MainActor func legal(_ owner: GeneratedNote.MainActorHost) async throws {
    var snapshots = try owner.snapshots()
    while let snapshot = await snapshots.next() { print(snapshot.revision) }
}
