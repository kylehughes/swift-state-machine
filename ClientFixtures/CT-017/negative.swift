import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func misuse(_ owner: consuming Flow.Owned<Flow.Idle>) -> () -> Void {
 return { _ = owner.load(request()) }
}
