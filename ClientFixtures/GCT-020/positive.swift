import StateMachine
import StateMachineExamples
nonisolated func accepted(_ loading: GeneratedProfile.Observed<GeneratedProfile.Loading>, _ work: GeneratedProfile.FetchWork) throws { if case .failure(let completion) = work.failed(.unavailable) { _ = try loading.failed(completion) } }
