import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func misuse(_ local: inout Flow.Local, audit: Flow.AuditWork, profile: Profile) {
 guard case .loading(let observed) = local.snapshot(), case .success(let completion) = audit.succeeded(profile) else { return }
 _ = local.commit(observed.audited(completion))
}
