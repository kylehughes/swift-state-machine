import StateMachine
import StateMachineExamples
// An operation that cannot fail has a driver that returns its output itself.
@MainActor func misuse() async {
    let saved: Result<GeneratedNote.Saved, Never> = .success(GeneratedNote.Saved(text: "saved"))
    let owner = GeneratedNote.MainActorHost(saveDriver: { _ in saved })
    await owner.shutdown()
}
