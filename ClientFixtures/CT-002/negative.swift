import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func misuse(_ owner: consuming Flow.Owned<Flow.Idle>) {
 let alias = owner
 _ = owner.load(request())
 _ = alias.load(request())
}
