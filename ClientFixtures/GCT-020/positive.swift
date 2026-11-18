import StateMachine
import StateMachineExamples
nonisolated func accepted(_ owner: inout GeneratedProfile.Local, _ work: GeneratedProfile.FetchWork) { _ = owner.deliver(work.failed(.unavailable)) }
