import StateMachine
import StateMachineExamples
import StateMachineUI

@concurrent nonisolated func misuse(_ owner: GeneratedNote.MainActorHost) async throws {
    var snapshots = try await owner.snapshots()
    while let snapshot = await snapshots.next() { print(snapshot.revision) }
}
