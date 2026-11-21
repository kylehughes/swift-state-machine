import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func misuse(_ local: inout Flow.Local, work: Flow.FetchWork, failure: ProfileFailure) {
 guard case .loading(let observed) = local.snapshot(), case .failure(let completion) = work.failed(failure) else { return }
 _ = local.commit(observed.failed(completion))
}
