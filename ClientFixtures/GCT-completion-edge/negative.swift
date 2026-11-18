import StateMachine
import StateMachineExamples
// A completion edge is not a method a client can prepare, so it cannot replace a retained outcome.
nonisolated func misuse(_ loading: GeneratedProfile.Observed<GeneratedProfile.Loading>, _ value: Profile) {
    _ = loading.received(value)
}
