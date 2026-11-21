import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func legal(_ local: inout Flow.Local, raw: RuntimePendingID) {
 _ = raw
 for pending in local.pendingCompletions() {
  _ = local.retryAdmission(id: pending.id)
  _ = local.reconcile(id: pending.id)
 }
}
