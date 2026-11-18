import StateMachine
import StateMachineExamples
nonisolated func accepted(_ owner: inout GeneratedProfile.Local, _ work: GeneratedProfile.FetchWork, _ value: Profile) { _ = owner.deliver(work.succeeded(value)) }
