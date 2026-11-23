// An omitted reachable phase gains no generated method from a @PhaseSet-backed transition.
import PhaseSetFixtureLibrary
import StateMachine

nonisolated func omittedPhaseHasNoReset(
    _ exporting: EditorWorkflow.Observed<EditorWorkflow.Exporting>
) {
    _ = exporting.reset()
}
