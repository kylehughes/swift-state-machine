import StateMachine
import StateMachineExamples

// A registration owned by an actor is cancelled on that actor.
actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    private var subscription: GeneratedNote.IsolatedSubscription<Editor>?

    func observe() throws { subscription = try note.subscribe { _ in } }
    func stop(_ subscription: GeneratedNote.IsolatedSubscription<Editor>) { subscription.cancel() }
}
