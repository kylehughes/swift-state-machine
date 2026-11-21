import StateMachine
import StateMachineExamples
import StateMachineUI

actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })

    func legal() async throws {
        for await revision in try note.snapshots({ $0.revision }).map({ $0 + 1 }).prefix(1) { print(revision) }
        for await count in try note.pendingCompletionUpdates({ $0.count }).filter({ $0 > 0 }).prefix(1) { print(count) }
    }
}
