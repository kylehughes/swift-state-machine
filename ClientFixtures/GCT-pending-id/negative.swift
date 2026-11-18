import StateMachine
import StateMachineExamples
// Each schema has its own pending identity type, so another graph's ID does not type-check.
nonisolated func misuse(_ owner: inout GeneratedNote.Local, _ pending: GeneratedProfile.PendingCompletion) {
    _ = owner.reconcile(id: pending.id)
}
