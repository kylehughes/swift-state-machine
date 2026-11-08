import StateMachine
@_spi(Internals) import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func legal(_ initial: Flow.Idle) throws {
 var local = Flow.Local(initial)
 guard case .idle(let idle) = local.snapshot() else { return }
 let prepared = try idle.load(request())
 _ = local.commit(prepared)
}
