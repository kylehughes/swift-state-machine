import StateMachine
import StateMachineExamples

// Code outside the owning actor reaches the host only by asking the actor.
actor Editor {
    private var note: GeneratedNote.IsolatedHost<Editor>?
    func open() {
        note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    }
    func edit(_ text: String) throws { try note?.send(.edit(text)) }
}

nonisolated func suggest(_ text: String, to editor: Editor) async throws { try await editor.edit(text) }
