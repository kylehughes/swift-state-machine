import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func legal(_ work: Flow.FetchWork, profile: Profile) -> @Sendable () -> Flow.FetchCompletion { { work.succeeded(profile) } }
