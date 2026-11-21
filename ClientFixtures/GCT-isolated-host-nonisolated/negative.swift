import StateMachine
import StateMachineExamples

// A nonisolated context has no actor to pass as the host's owner.
actor Editor {
    private var note: GeneratedNote.IsolatedHost<Editor>?
    func open() {
        note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    }
}

nonisolated func suggest(_ text: String, to note: GeneratedNote.IsolatedHost<Editor>) throws {
    try note.send(.edit(text))
}
