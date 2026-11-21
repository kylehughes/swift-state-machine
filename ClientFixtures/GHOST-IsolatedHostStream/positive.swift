import StateMachine
import StateMachineExamples
import StateMachineUI

actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })

    func legal() async throws {
        var snapshots = try note.snapshots()
        while let snapshot = await snapshots.next() { print(snapshot.revision) }
    }
}
