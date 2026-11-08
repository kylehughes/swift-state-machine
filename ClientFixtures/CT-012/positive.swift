import StateMachine
import StateMachineExamples
import Foundation

func legal(_ note: IsolatedNote.Draft) {
    let owner = IsolatedNote.owned(note)
    _ = owner.save()
    let isolated = RuntimeState<IsolatedNote.Draft, IsolatedNote.Draft>(note, limits: try! RuntimeLimits())
    _ = isolated.snapshot.model
    _ = AtomicRecordStorage(1)
    _ = ReferenceProfile.Shared(
        .init(userID: try! UserID("kyle")),
        drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
    )
}
actor ConfinedKernelControl {
    private var state = RuntimeState<IsolatedNote.Draft, IsolatedNote.Draft>(
        .init(text: "before"),
        limits: try! RuntimeLimits()
    )
    func replace() throws -> String {
        let candidate = try RuntimeState<IsolatedNote.Draft, IsolatedNote.Draft>
            .prepare(
                on: state.snapshot,
                next: .init(text: "after")
            )
        _ = state.commit(candidate)
        return state.snapshot.model.text
    }
}
