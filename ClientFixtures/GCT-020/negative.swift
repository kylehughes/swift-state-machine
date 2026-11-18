import StateMachine
import StateMachineExamples
nonisolated func misuse(_ owner: inout GeneratedProfile.Local) { _ = owner.deliver(ProfileFailure.unavailable) }
