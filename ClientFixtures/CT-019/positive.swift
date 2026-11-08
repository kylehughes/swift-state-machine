import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func legal(_ observed: Flow.Observed<Flow.Loading>, work: Flow.FetchWork, profile: Profile) throws { if case .success(let completion) = work.succeeded(profile) { _ = try observed.received(completion) } }
