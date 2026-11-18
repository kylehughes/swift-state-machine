import StateMachine
import StateMachineExamples
nonisolated func accepted(_ owner: GeneratedProfile.Shared, _ pending: GeneratedProfile.PendingCompletion) {
    _ = owner.reconcile(id: pending.id)
}
