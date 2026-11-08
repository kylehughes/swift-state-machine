import StateMachineExamples
nonisolated func accepted(_ loading: ReferenceProfile.Observed<ReferenceProfile.Loading>, _ work: ReferenceProfile.FetchWork, _ value: Profile) throws { if case .success(let completion) = work.succeeded(value) { _ = try loading.received(completion) } }
