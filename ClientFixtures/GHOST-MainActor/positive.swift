import StateMachine
import StateMachineExamples
import StateMachineUI

@MainActor func legal() async throws {
    let owner = GeneratedNote.MainActorHost(
        .init(text: "value"),
        drivers: .init(save: { .init(text: $0.text) })
    )
    _ = try owner.send(.save)
    let view = SnapshotObservableObject(owner.snapshot(), revision: { $0.revision })
    view.apply(owner.snapshot())
    await owner.shutdown()
}
