import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func misuse(_ local: inout Flow.Local, profile: Profile) { _ = local.deliver(.fetch(.success(profile))) }
