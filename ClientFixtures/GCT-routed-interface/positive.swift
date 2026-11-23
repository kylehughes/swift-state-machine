// Separate-module client exercising public routed schemas across binary and .swiftinterface lanes.
import RoutedHandoffFixtureLibrary
import StateMachine

nonisolated func consumeRoutedPublicSchemas(
    _ comparing: PublicSortingFlow.Observed<PublicSortingFlow.Comparing>,
    _ open: MoveOnlyRoutedPublicFlow.Observed<MoveOnlyRoutedPublicFlow.Open>,
    _ alpha: SplitShapeRoutedFlow.Observed<SplitShapeRoutedFlow.Alpha>,
    _ beta: SplitShapeRoutedFlow.Observed<SplitShapeRoutedFlow.Beta>
) {
    _ = comparing.routeChoice(true)
    _ = PublicSortingFlow.owned().routeReadyStep("go", request: .init(input: 1))

    _ = open.routeOpen(true)
    _ = MoveOnlyRoutedPublicFlow.owned().routeOpen(false)

    _ = alpha.choose(true)
    _ = beta.choose(false)
    _ = SplitShapeRoutedFlow.owned().choose(true)

    var local = SplitShapeRoutedFlow.Local()
    _ = try? local.send(.step(true))
    _ = try? local.send(.step(true))
}
