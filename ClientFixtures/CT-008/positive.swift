import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func legal(_ work: Flow.FetchWork, profile: Profile) { let copied = work; _ = copied.succeeded(profile); _ = work.execution }
