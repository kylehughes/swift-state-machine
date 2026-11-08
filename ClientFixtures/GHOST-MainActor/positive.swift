import StateMachine
import StateMachineExamples
import StateMachineUI

@MainActor func legal() async throws {
    let owner = GeneratedNote.MainActorHost(
        .init(text: "value"),
        drivers: .init(save: { .success(.init(text: $0.text)) })
    )
    _ = try owner.send(.save)
    let view = SnapshotPresentation(owner.snapshot(), ordinal: { $0.ordinal })
    view.apply(owner.snapshot())
    await owner.shutdown()
}
