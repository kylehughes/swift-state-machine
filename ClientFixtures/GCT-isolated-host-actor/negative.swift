import StateMachine
import StateMachineExamples

// A host confined to `Editor` cannot run on another actor: its isolation parameter must be an `Editor`.
actor Editor {
    private var note: GeneratedNote.IsolatedHost<Editor>?
    func open() {
        note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    }
}

actor Reviewer {
    func suggest(_ text: String, to note: GeneratedNote.IsolatedHost<Editor>) throws { try note.send(.edit(text)) }
}
