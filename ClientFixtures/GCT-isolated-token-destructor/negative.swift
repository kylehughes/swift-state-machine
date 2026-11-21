import StateMachine
import StateMachineExamples

// An ordinary object's destructor can run on any thread, so it has no owning actor to cancel on.
nonisolated final class Cleanup {
    let token: GeneratedNote.IsolatedSubscription<Editor>
    init(_ token: GeneratedNote.IsolatedSubscription<Editor>) { self.token = token }
    deinit { token.cancel() }
}

actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    private var cleanup: Cleanup?

    func observe() throws { cleanup = Cleanup(try note.subscribe { _ in }) }
}
