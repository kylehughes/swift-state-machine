import StateMachine
import StateMachineExamples
import StateMachineUI

@MainActor func legal(_ note: GeneratedNote.MainActorHost, _ profile: GeneratedProfile.MainActorHost) async throws {
    for await revision in try note.snapshots({ $0.revision }).prefix(1) { print(revision) }
    for await revision in try profile.snapshots().map({ $0.revision }).prefix(1) { print(revision) }
}
