#if canImport(Combine)
import Combine
import Dispatch
import StateMachineExamples
import StateMachineUI

final class Box {
    var count = 0
}

@MainActor func legal(
    _ confined: SnapshotObservableObject<Box>,
    _ shared: SnapshotObservableObject<Int>,
    _ driving: StateMachineObservableObject<GeneratedNote.MainActorHost>,
    _ profile: StateMachineObservableObject<GeneratedProfile.MainActorHost>
) -> [AnyCancellable] {
    [
        confined.presentedSnapshots(projecting: { $0.count }).receive(on: DispatchQueue.global())
            .sink { @Sendable count in print(count) },
        shared.presentedSnapshots.receive(on: DispatchQueue.global()).sink { @Sendable value in print(value) },
        driving.presentedSnapshots(projecting: { $0.revision }).receive(on: DispatchQueue.global())
            .sink { @Sendable revision in print(revision) },
        profile.presentedSnapshots.receive(on: DispatchQueue.global()).sink { @Sendable snapshot in print(snapshot.revision) },
    ]
}
#endif
