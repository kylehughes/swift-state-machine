import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func legal(_ snapshot: Flow.Snapshot) { let copy = snapshot; _ = copy.model; _ = copy.revision }
