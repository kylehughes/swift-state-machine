import StateMachine
import StateMachineExamples
// A managed owner runs its own work, so no caller holds a completion to deliver.
nonisolated func misuse(_ owner: GeneratedProfile.Shared, _ completion: GeneratedProfile.Completion) {
    _ = owner.deliver(completion)
}
