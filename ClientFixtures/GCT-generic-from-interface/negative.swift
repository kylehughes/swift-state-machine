// An omitted reachable phase gains no generated method from a generic <Source> @Transition(from:) declaration.
import GenericFromFixtureLibrary
import StateMachine

nonisolated func omittedPhaseHasNoSelectList(
    _ maintenance: NavigationPublicFlow.Observed<NavigationPublicFlow.Maintenance>
) {
    _ = maintenance.selectList(1)
}
