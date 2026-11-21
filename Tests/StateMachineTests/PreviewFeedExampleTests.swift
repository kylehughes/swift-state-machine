import StateMachine
import StateMachineUI
import Testing
import os

// The preview feed example of TestingAGraph.md, verbatim: a host of one's own that keeps each
// registration's callbacks, removes them by identifier, and ends its sequences when it is released.

final class PreviewFeed: SharedStateMachineHost {
    struct Snapshot: StateMachineSnapshot, Sendable {
        let revision: UInt64
        let headline: String
    }

    private struct Registration {
        let receive: @Sendable (Snapshot) -> Void
        let finish: @Sendable () -> Void
    }
    private struct Registry {
        var nextID = 0
        var registrations: [Int: Registration] = [:]
    }

    private let registry = OSAllocatedUnfairLock(initialState: Registry())
    let current = Snapshot(revision: 1, headline: "Preview")

    /// How many registrations the feed is keeping.
    var registrationCount: Int { registry.withLock { $0.registrations.count } }

    func snapshot() -> Snapshot { current }

    func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Snapshot> {
        try snapshots { $0 }
    }

    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        let current = current
        return try SnapshotSequence { receive, finish in
            receive(transform(current))
            let registration = Registration(receive: { receive(transform($0)) }, finish: finish)
            let id = registry.withLock { registry in
                defer { registry.nextID += 1 }
                registry.registrations[registry.nextID] = registration
                return registry.nextID
            }
            return SnapshotSubscription { [weak self] in
                _ = self?.registry.withLock { $0.registrations.removeValue(forKey: id) }
            }
        }
    }

    // A feed with one snapshot never repeats a projection.
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Snapshot) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try snapshots(transform)
    }
}

@MainActor
@Test func aPresentationShowsThePreviewFeedForTheFeedsLifetime() async throws {
    var feed: PreviewFeed? = PreviewFeed()
    let presentation = SnapshotObservableObject(PreviewFeed.Snapshot(revision: 0, headline: ""))

    try presentation.observe(try #require(feed))
    #expect(presentation.snapshot.headline == "Preview")
    #expect(presentation.isObserving)
    presentation.stopObserving()
    #expect(feed?.registrationCount == 0)

    // Releasing the feed ends the sequence it registered; the unread headline stays readable.
    let snapshots = try #require(feed).snapshots()
    feed = nil
    await presentation.follow(snapshots)
    #expect(presentation.snapshot.headline == "Preview")
    #expect(!presentation.isObserving)
}
