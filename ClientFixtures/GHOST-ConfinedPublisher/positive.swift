#if canImport(Combine)
import Combine
import Dispatch
import StateMachine
import StateMachineExamples
import StateMachineUI

@MainActor func legal(_ host: GeneratedNote.MainActorHost, _ profile: GeneratedProfile.MainActorHost) throws -> [AnyCancellable] {
    let text = try host.snapshotPublisher { snapshot -> String in
        if case .draft(let draft) = snapshot { draft.value.text } else { "" }
    }
    let profiles = try profile.snapshotPublisher()
    return [
        text.receive(on: DispatchQueue.global()).sink { @Sendable text in print(text) },
        profiles.receive(on: DispatchQueue.global()).sink { @Sendable snapshot in print(snapshot.revision) },
    ]
}
#endif
