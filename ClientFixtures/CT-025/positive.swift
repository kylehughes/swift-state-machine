import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func legal(_ shared: Flow.Shared, work: Flow.FetchWork, profile: Profile) {
 _ = work.succeeded(profile)
 for pending in shared.pendingCompletions() { _ = shared.reconcile(id: pending.id) }
}
