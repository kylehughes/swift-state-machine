import StateMachine
import StateMachineExamples

// An isolated host is used from the actor that owns it; another actor asks that actor to use it.
actor Editor {
    private var note: GeneratedNote.IsolatedHost<Editor>?
    func open() {
        note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    }
    func edit(_ text: String) throws { try note?.send(.edit(text)) }
}

actor Reviewer {
    func suggest(_ text: String, to editor: Editor) async throws { try await editor.edit(text) }
}
