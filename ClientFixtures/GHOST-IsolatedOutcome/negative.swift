import StateMachine
import StateMachineExamples
import StateMachineUI

@concurrent nonisolated func misuse(_ owner: GeneratedNote.MainActorHost) async {
    let value = await owner.snapshot()
    print(value.ordinal)
}
