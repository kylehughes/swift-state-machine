import StateMachineExamples
nonisolated func accepted(_ local: inout ReferenceProfile.Local, _ work: ReferenceProfile.FetchWork, _ value: Profile) { _ = local.deliver(.fetch(work.succeeded(value))) }
