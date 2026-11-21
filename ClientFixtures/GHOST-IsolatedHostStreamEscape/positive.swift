import StateMachine
import StateMachineExamples
import StateMachineUI

actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })

    func legal() async throws {
        await read(try note.snapshots())
    }

    func read(_ snapshots: consuming GeneratedNote.IsolatedSnapshots) async {
        var snapshots = snapshots
        _ = await snapshots.next()
    }
}
