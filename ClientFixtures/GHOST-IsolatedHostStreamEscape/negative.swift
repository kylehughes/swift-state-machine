import StateMachine
import StateMachineExamples
import StateMachineUI

actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })

    func misuse(_ reader: Reader) async throws {
        await reader.read(try note.snapshots())
    }
}

actor Reader {
    func read(_ snapshots: consuming GeneratedNote.IsolatedSnapshots) async {
        var snapshots = snapshots
        _ = await snapshots.next()
    }
}
