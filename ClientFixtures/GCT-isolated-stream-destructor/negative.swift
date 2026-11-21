import StateMachine
import StateMachineExamples

// An ordinary object's destructor can run on any thread, so it has no owning actor to end a stream on.
nonisolated final class Shelf {
    var snapshots: GeneratedNote.IsolatedSnapshots?
    deinit { snapshots?.cancel() }
}

actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    private let shelf = Shelf()

    func observe() throws { shelf.snapshots = try note.snapshots() }
}
