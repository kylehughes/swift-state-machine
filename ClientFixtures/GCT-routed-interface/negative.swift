// Separate-module client cannot name a fileprivate routed choice enum or call a routed candidate directly.
import RoutedHandoffFixtureLibrary
import StateMachine

nonisolated func cannotSeePrivateChoiceOrCandidate(
    _ comparing: PublicSortingFlow.Observed<PublicSortingFlow.Comparing>
) {
    let _: PublicSortingFlow.Route.RouteChoice.Type = PublicSortingFlow.Route.RouteChoice.self
    _ = comparing
}
