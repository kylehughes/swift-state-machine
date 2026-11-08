import StateMachine
import StateMachineExamples
import StateMachineUI

@MainActor func legal(_ owner: GeneratedNote.MainActorHost) {
    let value = owner.snapshot()
    print(value.ordinal)
}
