import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
actor Storage { func read() -> String { "value" } }
@concurrent func legal(_ storage: Storage) async { let copy = await storage.read(); print(copy) }
