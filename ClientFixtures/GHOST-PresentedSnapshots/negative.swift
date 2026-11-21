#if canImport(Combine)
import Combine
import Dispatch
import StateMachineExamples
import StateMachineUI

final class Box {
    var count = 0
}

@MainActor func misuse(_ presentation: SnapshotObservableObject<Box>) -> AnyCancellable {
    presentation.presentedSnapshots.receive(on: DispatchQueue.global()).sink { @Sendable box in box.count += 1 }
}

@MainActor func misuse(_ presentation: StateMachineObservableObject<GeneratedNote.MainActorHost>) -> AnyCancellable {
    presentation.presentedSnapshots.receive(on: DispatchQueue.global()).sink { @Sendable snapshot in
        if case .draft(let draft) = snapshot { print(draft.value.text) }
    }
}
#endif
