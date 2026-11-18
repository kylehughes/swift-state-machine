import StateMachine
import StateMachineExamples
// One verb joins a managed owner, with or without a deadline.
nonisolated func accepted(_ owner: GeneratedProfile.Shared) async {
    await owner.shutdown()
    if case .timedOut(let diagnostics) = await owner.shutdown(deadline: .now) {
        _ = diagnostics.outstandingExecutions
    }
}
