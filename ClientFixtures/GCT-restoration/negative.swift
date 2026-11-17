import StateMachine
import StateMachineExamples
nonisolated func misuse(_ request: ProfileRequest) throws { let restored: GeneratedProfile.Restoration = .loading(GeneratedProfile.Loading(request: request)); _ = restored; _ = try GeneratedProfile.Local(restoring: .loading(request)) }
