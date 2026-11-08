import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func legal(_ owner: consuming Flow.Owned<Flow.Idle>) { _ = owner.load(request()) }
