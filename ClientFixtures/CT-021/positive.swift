import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func legal(_ local: inout Flow.Local, work: Flow.FetchWork, profile: Profile) {
 guard case .loading(let observed) = local.snapshot() else { return }
 _ = observed.value.request
 _ = local.deliver(.fetch(work.succeeded(profile)))
}
