import StateMachine
import StateMachineExamples
import StateMachineUI
// The Observation presentations are not spelled with an `Observable` prefix.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor func present(_ host: GeneratedProfile.MainActorHost) -> ObservableStateMachinePresentation<GeneratedProfile.MainActorHost> {
    ObservableStateMachinePresentation(host)
}
