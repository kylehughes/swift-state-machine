import StateMachine
import StateMachineExamples

// The owning actor cancels the registration it stored in an ordinary object.
nonisolated final class Cleanup {
    let token: GeneratedNote.IsolatedSubscription<Editor>
    init(_ token: GeneratedNote.IsolatedSubscription<Editor>) { self.token = token }
}

actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    private var cleanup: Cleanup?

    func observe() throws { cleanup = Cleanup(try note.subscribe { _ in }) }
    func stop() {
        cleanup?.token.cancel()
        cleanup = nil
    }
}
