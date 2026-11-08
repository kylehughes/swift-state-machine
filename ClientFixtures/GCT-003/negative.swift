import StateMachine
import StateMachineExamples
nonisolated func misuse(_ idle: GeneratedProfile.Observed<GeneratedProfile.Idle>, _ value: GeneratedProfile.FetchSuccessCompletion) throws {
    _ = try idle.received(value)
}
