// Separate-module consumer calling @PhaseSet-expanded edges on listed phases across binary and .swiftinterface lanes.
import PhaseSetFixtureLibrary
import StateMachine

nonisolated func consumePhaseSetWorkflow(
    _ draft: EditorWorkflow.Observed<EditorWorkflow.Draft>,
    _ reviewing: EditorWorkflow.Observed<EditorWorkflow.Reviewing>,
    _ exporting: EditorWorkflow.Observed<EditorWorkflow.Exporting>
) {
    _ = draft.reset()
    _ = reviewing.reset()
    _ = draft.archive()
    _ = reviewing.archive()
    _ = exporting.finishExport()
    _ = EditorWorkflow.owned().reset()
    _ = EditorWorkflow.owned().submit().archive()
    var local = EditorWorkflow.Local()
    _ = try? local.send(.submit)
    _ = try? local.send(.reset)
}
