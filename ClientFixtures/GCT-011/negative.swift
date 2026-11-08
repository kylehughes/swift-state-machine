import StateMachine
@_spi(Internals) import StateMachineExamples
nonisolated func misuse(_ owner: GeneratedProfile.Shared) { _ = owner.host }
