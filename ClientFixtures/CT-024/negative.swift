import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func misuse(_ local: inout Flow.Local, audit: Flow.AuditWork, failure: ProfileFailure) {
 guard case .loading(let observed) = local.snapshot(), case .failure(let completion) = audit.failed(failure) else { return }
 _ = local.commit(observed.auditFailed(completion))
}
