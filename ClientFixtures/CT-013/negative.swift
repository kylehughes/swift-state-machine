import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
actor Storage { func read() -> IsolatedNote.Draft { .init(text: "x") } }
@concurrent func misuse(_ storage: Storage) async { let note = await storage.read(); print(note.text) }
