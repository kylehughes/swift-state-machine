import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func misuse(_ local: inout Flow.Local, work: Flow.FetchWork, profile: Profile) {
 guard case .loading(let observed) = local.snapshot(), case .success(let completion) = work.succeeded(profile) else { return }
 _ = local.commit(observed.received(completion))
}
