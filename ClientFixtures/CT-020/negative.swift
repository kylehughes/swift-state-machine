import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func misuse(_ observed: Flow.Observed<Flow.Loading>, failure: ProfileFailure) throws { _ = try observed.failed(failure) }
