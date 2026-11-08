import StateMachine
import StateMachineExamples
nonisolated func misuse(_ loading: GeneratedProfile.Observed<GeneratedProfile.Loading>, _ audit: GeneratedProfile.AuditSuccessCompletion) throws { _ = try loading.received(audit) }
