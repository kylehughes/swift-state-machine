import StateMachine
import StateMachineExamples
// A routed input is prepared through its router.
nonisolated func accepted(_ waiting: GeneratedRetry.Observed<GeneratedRetry.Waiting>) throws -> GeneratedRetry.Prepared {
    try waiting.decide()
}
