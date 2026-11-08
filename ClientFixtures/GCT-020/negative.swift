import StateMachine
import StateMachineExamples
nonisolated func misuse(_ loading: GeneratedProfile.Observed<GeneratedProfile.Loading>) throws { _ = try loading.failed(ProfileFailure.unavailable) }
