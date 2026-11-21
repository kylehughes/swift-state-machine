import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func legal(_ local: inout Flow.Local, work: Flow.FetchWork, failure: ProfileFailure) { _ = local.deliver(.fetch(work.failed(failure))) }
