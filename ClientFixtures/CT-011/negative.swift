import StateMachine
@_spi(Internals) import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func misuse(_ local: borrowing Flow.Local) { _ = local.state }
