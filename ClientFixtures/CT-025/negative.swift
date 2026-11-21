import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func misuse(_ shared: Flow.Shared, work: Flow.FetchWork, profile: Profile) {
 _ = shared.deliver(.fetch(work.succeeded(profile)))
}
