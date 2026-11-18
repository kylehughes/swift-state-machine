import StateMachine
import StateMachineExamples
// A routed edge has no method of its own, so a typed call cannot skip the router.
nonisolated func misuse(_ waiting: GeneratedRetry.Observed<GeneratedRetry.Waiting>) -> GeneratedRetry.Prepared {
    waiting.again()
}
