import StateMachine
import StateMachineExamples
import StateMachineUI
// The Observation presentations take the short names; the Combine ones name their protocol.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor func present(_ host: GeneratedProfile.MainActorHost) -> StateMachinePresentation<GeneratedProfile.MainActorHost> {
    _ = SnapshotPresentation(host.snapshot())
    _ = SnapshotObservableObject(host.snapshot())
    _ = StateMachineObservableObject(host)
    return StateMachinePresentation(host)
}
