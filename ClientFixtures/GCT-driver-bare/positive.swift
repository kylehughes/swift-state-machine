import StateMachine
import StateMachineExamples
// An operation that cannot fail has a driver that returns its output itself.
@MainActor func accepted() async {
    let owner = GeneratedNote.MainActorHost(saveDriver: { draft in GeneratedNote.Saved(text: draft.text) })
    await owner.shutdown()
}
