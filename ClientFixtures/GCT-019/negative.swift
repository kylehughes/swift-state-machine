import StateMachine
import StateMachineExamples
nonisolated func misuse(_ owner: inout GeneratedProfile.Local, _ value: Profile) { _ = owner.deliver(value) }
