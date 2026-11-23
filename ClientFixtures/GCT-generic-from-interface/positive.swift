// Separate-module consumer calling generic <Source> @Transition(from:) methods across binary & .swiftinterface lanes.
import GenericFromFixtureLibrary
import StateMachine

nonisolated func consumeGenericFromPublicSchemas(
    _ browsing: NavigationPublicFlow.Observed<NavigationPublicFlow.Browsing>,
    _ confirming: NavigationPublicFlow.Observed<NavigationPublicFlow.Confirming>,
    _ sheet: NavigationPublicFlow.Observed<NavigationPublicFlow.PresentingSheet>,
    _ sheetConfirming: NavigationPublicFlow.Observed<NavigationPublicFlow.PresentingSheetConfirming>,
    _ pending: NavigationPublicFlow.Observed<NavigationPublicFlow.PendingNavigation>,
    _ stageA: ComposedPublicFlow.Observed<ComposedPublicFlow.StageA>,
    _ stageB: ComposedPublicFlow.Observed<ComposedPublicFlow.StageB>
) {
    _ = browsing.selectList(1)
    _ = confirming.selectList(2)
    _ = sheet.selectList(3)
    _ = sheetConfirming.selectList(4)
    _ = pending.selectList(5)
    _ = NavigationPublicFlow.owned().selectList(1).presentSheet("s").selectList(2)

    _ = stageA.routeDecide(false)
    _ = stageB.routeDecide(true)
    _ = ComposedPublicFlow.owned().routeDecide(false)

    _ = DocPublicFlow.owned(.init(title: "a")).rename("b")
    _ = DocPublicFlow.owned(.init(title: "a")).submit().rename("c")
}
