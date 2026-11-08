import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func legal(_ observed: Flow.Observed<Flow.Loading>, work: Flow.FetchWork) throws { if case .failure(let completion) = work.failed(.unavailable) { _ = try observed.failed(completion) } }
