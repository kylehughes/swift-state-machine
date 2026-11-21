import StateMachine
import StateMachineExamples

// The main actor is not the actor that owns the registration.
actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    private var subscription: GeneratedNote.IsolatedSubscription<Editor>?

    func observe() throws { subscription = try note.subscribe { _ in } }
}

@MainActor func stop(_ subscription: GeneratedNote.IsolatedSubscription<Editor>) { subscription.cancel() }
