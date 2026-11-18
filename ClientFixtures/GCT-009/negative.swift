import StateMachine
import StateMachineExamples
nonisolated func misuse(_ owner: inout GeneratedProfile.Local, _ work: GeneratedProfile.FetchWork, _ value: Profile) { _ = owner.deliver(.audit(work.succeeded(value))) }
