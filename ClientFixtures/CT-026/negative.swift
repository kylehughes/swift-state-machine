import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func misuse(_ local: inout Flow.Local, raw: RuntimePendingID) {
 _ = local.reconcile(id: raw)
}
