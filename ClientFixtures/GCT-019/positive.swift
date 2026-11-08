import StateMachine
import StateMachineExamples
nonisolated func accepted(_ loading: GeneratedProfile.Observed<GeneratedProfile.Loading>, _ work: GeneratedProfile.FetchWork, _ value: Profile) throws { if case .success(let completion) = work.succeeded(value) { _ = try loading.received(completion) } }
