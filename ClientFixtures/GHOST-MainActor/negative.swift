import StateMachine
import StateMachineExamples
import StateMachineUI

nonisolated func misuse(_ owner: GeneratedNote.MainActorHost) throws {
    _ = try owner.send(.save)
}
