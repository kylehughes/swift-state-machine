import StateMachine
import StateMachineExamples
import StateMachineUI

@concurrent nonisolated func misuse(_ snapshots: sending GeneratedNote.MainActorSnapshots) async {
    for await snapshot in snapshots { print(snapshot.revision) }
}
