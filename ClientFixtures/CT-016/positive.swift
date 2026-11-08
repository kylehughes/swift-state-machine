import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func legal(_ archive: Flow.Archive) throws { let data = try JSONEncoder().encode(archive); let decoded = try JSONDecoder().decode(Flow.Archive.self, from: data); let restored = Flow.Local.restore(decoded); _ = restored.snapshot() }
