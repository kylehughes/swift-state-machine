import StateMachine
import StateMachineExamples
// The deadline form is `shutdown(deadline:)`; the separate waiting verb is gone.
nonisolated func misuse(_ owner: GeneratedProfile.Shared) async {
    _ = await owner.shutdownAndWait(deadline: .now)
}
