import StateMachine
import StateMachineExamples
import StateMachineUI

actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })

    func misuse() throws {
        let subscription = try note.subscribe { print($0.revision) }
        Task.detached { withExtendedLifetime(subscription) {} }
    }
}
