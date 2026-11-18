import StateMachine
import StateMachineExamples
nonisolated func accepted(_ owner: inout GeneratedProfile.Local, _ pending: GeneratedProfile.PendingCompletion) {
    _ = owner.reconcile(id: pending.id)
}
