import StateMachine
import StateMachineExamples

// An ordinary object's destructor can run on any thread, so it cannot read the host's confined state.
nonisolated final class Report {
    let note: GeneratedNote.IsolatedHost<Editor>
    init(_ note: GeneratedNote.IsolatedHost<Editor>) { self.note = note }
    deinit { print(note.runningCount(), note.subscriberCount(), note.isQuiescent()) }
}

actor Editor {
    private lazy var note = GeneratedNote.IsolatedHost(isolation: self, saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) })
    private var report: Report?

    func start() { report = Report(note) }
}
