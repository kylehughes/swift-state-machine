import StateMachine
import StateMachineExamples
nonisolated func accepted(_ profile: Profile) throws { let restored: GeneratedProfile.Restoration = .loaded(GeneratedProfile.Loaded(profile: profile)); _ = restored; _ = try GeneratedProfile.Local(restoring: .loaded(profile)) }
