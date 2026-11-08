import StateMachine
import StateMachineExamples
import StateMachineUI

@MainActor func legal() {
    let owner = GeneratedNote.MainActorHost(
        .init(text: "value"),
        drivers: .init(save: { .success(.init(text: $0.text)) })
    )
    _ = owner.close()
}
