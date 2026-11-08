import StateMachine
import StateMachineExamples
nonisolated func misuse(_ prepared: consuming GeneratedProfile.Prepared, _ owner: GeneratedProfile.Shared) {
    _ = owner.commit(prepared)
    _ = owner.commit(prepared)
}
