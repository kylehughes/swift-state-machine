import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func legal(_ local: inout Flow.Local, audit: Flow.AuditWork, failure: ProfileFailure) {
 guard case .loading(let observed) = local.snapshot() else { return }
 _ = local.commit(observed.audit("audit"))
 _ = local.deliver(.audit(audit.failed(failure)))
}
