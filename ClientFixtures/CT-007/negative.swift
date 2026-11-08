import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func misuse(_ value: Flow.Idle) { _ = Flow.Observed<Flow.Idle>(payload: value) }
