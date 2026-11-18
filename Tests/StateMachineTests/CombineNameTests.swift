import Combine
import StateMachine
import Testing

/// Importing Combine beside StateMachine must leave every unqualified name unambiguous.
@Suite struct CombineNameTests {
    @MainActor private func describe(
        _ token: SnapshotSubscription?,
        _ mainActorToken: MainActorSnapshotSubscription?,
        _ publisherToken: (any Subscription)?
    ) -> [Bool] {
        [token == nil, mainActorToken == nil, publisherToken == nil]
    }

    @MainActor @Test func theRuntimeSubscriptionNamesCoexistWithCombinesSubscription() {
        let registration = MainActorSnapshotSubscription(onCancel: {})
        #expect(describe(nil, registration, nil) == [true, false, true])
        registration.cancel()
    }
}
