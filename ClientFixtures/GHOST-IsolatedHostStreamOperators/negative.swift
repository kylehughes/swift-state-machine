import StateMachine
import StateMachineExamples
import StateMachineUI

actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })

    func misuse() async throws {
        let revisions = try note.snapshots().map { $0.revision }
        _ = revisions
    }
}
