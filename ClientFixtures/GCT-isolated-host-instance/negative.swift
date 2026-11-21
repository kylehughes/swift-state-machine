import StateMachine
import StateMachineExamples

// A confined host cannot move to another instance of its owning actor's type.
actor Editor {
    private var note: GeneratedNote.IsolatedHost<Editor>?
    func open() {
        note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    }
    func hand(to other: Editor) async {
        guard let note else { return }
        await other.adopt(note)
    }
    func adopt(_ note: GeneratedNote.IsolatedHost<Editor>) { self.note = note }
}
