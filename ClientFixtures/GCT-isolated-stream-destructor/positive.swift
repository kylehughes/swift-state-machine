import StateMachine
import StateMachineExamples

// The owning actor ends the stream it stored in an ordinary object.
nonisolated final class Shelf {
    var snapshots: GeneratedNote.IsolatedSnapshots?
}

actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    private let shelf = Shelf()

    func observe() throws { shelf.snapshots = try note.snapshots() }
    func stop() {
        shelf.snapshots?.cancel()
        shelf.snapshots = nil
    }
}
