import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func legal(_ value: consuming Flow.Prepared, local: inout Flow.Local) { _ = local.commit(value) }
