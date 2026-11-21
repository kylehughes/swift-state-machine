import StateMachine
import StateMachineExamples

// A confined stream ends on the actor that owns it; there is no absent actor to pass.
actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })

    func readOnce() async throws {
        var snapshots = try note.snapshots()
        _ = await snapshots.next()
        snapshots.cancel(isolation: nil)
    }
}
