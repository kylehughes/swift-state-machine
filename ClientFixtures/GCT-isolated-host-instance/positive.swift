import StateMachine
import StateMachineExamples

// Each editor creates and keeps its own confined host.
actor Editor {
    private var note: GeneratedNote.IsolatedHost<Editor>?
    func open() {
        note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    }
    func hand(to other: Editor) async { await other.open() }
}
