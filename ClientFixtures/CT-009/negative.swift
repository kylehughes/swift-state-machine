import StateMachineExamples
nonisolated func rejected(_ local: inout ReferenceProfile.Local, _ audit: ReferenceProfile.AuditWork, _ value: Profile) { _ = local.deliver(.fetch(audit.succeeded(value))) }
