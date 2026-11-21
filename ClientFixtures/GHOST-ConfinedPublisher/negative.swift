#if canImport(Combine)
import Combine
import Dispatch
import StateMachine
import StateMachineExamples
import StateMachineUI

@MainActor func misuse(_ host: GeneratedNote.MainActorHost) throws -> AnyCancellable {
    try host.snapshotPublisher { $0 }.receive(on: DispatchQueue.global()).sink { @Sendable snapshot in
        if case .draft(let draft) = snapshot { print(draft.value.text) }
    }
}
#endif
