import StateMachine
import StateMachineExamples
import StateMachineUI

actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    private var subscription: GeneratedNote.IsolatedSubscription<Editor>?

    func legal() throws {
        subscription = try note.subscribe { print($0.revision) }
        subscription?.cancel()
    }
}
