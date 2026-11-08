import StateMachine
import StateMachineExamples
nonisolated func misuse(_ value: GeneratedProfile.Idle) { _ = GeneratedProfile.Observed(payload: value, record: (), claim: nil) }
