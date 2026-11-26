import StateMachine
import StateMachineExamples
private nonisolated func placeholder<T>() -> T { fatalError() }
nonisolated func misuse() { _ = GeneratedProfile.Observed<GeneratedProfile.Idle>(record: placeholder(), claim: nil, _stateMachinePayload: placeholder()) }
