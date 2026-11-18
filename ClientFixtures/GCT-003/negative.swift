import StateMachine
import StateMachineExamples
nonisolated func misuse(_ idle: GeneratedProfile.Observed<GeneratedProfile.Idle>) {
    _ = idle.cancel()
}
