import StateMachine
import StateMachineExamples

// The owning actor reads the host's counts.
actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })

    func counts() -> (running: Int, subscribers: Int, quiescent: Bool) {
        (note.runningCount(), note.subscriberCount(), note.isQuiescent())
    }
}
