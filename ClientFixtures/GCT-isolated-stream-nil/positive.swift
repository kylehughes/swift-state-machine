import StateMachine
import StateMachineExamples

// The owning actor ends the stream, by default or by passing itself.
actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })

    func readOnce() async throws {
        var snapshots = try note.snapshots()
        _ = await snapshots.next()
        snapshots.cancel()
        var again = try note.snapshots()
        again.cancel(isolation: self)
    }
}
