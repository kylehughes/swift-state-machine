import Combine
import Observation
import StateMachine
import StateMachineExamples
import StateMachineUI
import Testing

extension GeneratedProfile.Snapshot {
    /// The user whose owner produced this snapshot; each test gives each source its own user.
    fileprivate var user: String {
        switch self {
        case .idle(let idle): idle.value.userID.rawValue
        case .loading(let loading): loading.value.request.userID.rawValue
        case .loaded(let loaded): loaded.value.profile.userID.rawValue
        case .failed(let failed): failed.value.request.userID.rawValue
        }
    }
}

/// What a presentation publishes, awaited in order instead of inferred from scheduling.
@MainActor private final class Shown {
    struct Publication: Equatable {
        let user: String
        let revision: UInt64
    }
    private let stream: AsyncStream<Publication>
    private var cancellable: AnyCancellable?

    init(_ presentation: SnapshotObservableObject<GeneratedProfile.Snapshot>) {
        let (stream, continuation) = AsyncStream<Publication>.makeStream()
        self.stream = stream
        cancellable = presentation.presentedSnapshots.dropFirst()
            .sink { continuation.yield(Publication(user: $0.user, revision: $0.revision)) }
    }

    /// Returns the users of every publication up to the first of `user` at `revision` or later.
    func wait(for user: String, atLeast revision: UInt64) async -> [String] {
        var users: [String] = []
        for await publication in stream {
            users.append(publication.user)
            if publication.user == user, publication.revision >= revision { break }
        }
        return users
    }
}

/// An actor that owns a confined profile host and presents it on the main actor.
private actor ProfileDesk {
    private(set) var host: GeneratedProfile.IsolatedHost<ProfileDesk>!

    init(_ user: UserID) async {
        host = GeneratedProfile.IsolatedHost(
            .init(userID: user),
            isolation: self,
            fetchDriver: { _, _ in .failure(.unavailable) },
            auditDriver: { _, _ in .failure(.unavailable) }
        )
    }

    func present(on presentation: SnapshotObservableObject<GeneratedProfile.Snapshot>) async throws {
        try await presentation.observe(host)
    }

    @discardableResult func send(_ input: GeneratedProfile.Input) throws -> UInt64 { try host.send(input).revision }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SourceBoundPresentationTests {
    private static func request(_ user: String) throws -> ProfileRequest {
        try ProfileRequest(userID: UserID(user))
    }

    private func mainActorHost(_ user: String) throws -> GeneratedProfile.MainActorHost {
        GeneratedProfile.MainActorHost(
            .init(userID: try UserID(user)),
            fetchDriver: { _ in .failure(.unavailable) },
            auditDriver: { _ in .failure(.unavailable) }
        )
    }

    /// A shared owner whose fetch fails at once, or with `holding`, only once its work is cancelled.
    private func sharedHost(_ user: String, holding: Bool = false) throws -> GeneratedProfile.Shared {
        GeneratedProfile.Shared(
            .init(userID: try UserID(user)),
            fetchDriver: { _ in
                // Held work ends when revocation cancels it, not after a duration.
                if holding { try? await Task.sleep(for: .seconds(86_400)) }
                return .failure(.unavailable)
            },
            auditDriver: { _ in .failure(.unavailable) }
        )
    }

    /// Moves an owner forward two revisions, revoking the work it starts so nothing commits later.
    private func advance(_ send: (GeneratedProfile.Input) throws -> UInt64, _ user: String) throws -> UInt64 {
        _ = try send(.load(Self.request(user)))
        return try send(.cancel)
    }

    @Test func aMainActorSourceSeedsItselfAndReplacesTheOldSource() async throws {
        let old = try mainActorHost("old")
        let new = try mainActorHost("new")
        let ahead = try advance({ try old.send($0).revision }, "old")
        let presentation = SnapshotObservableObject(new.snapshot())
        let shown = Shown(presentation)
        try presentation.observe(old)
        #expect(presentation.snapshot.revision == ahead)
        #expect(presentation.snapshot.user == "old")
        #expect(presentation.isObserving)
        // The old source commits again, but its delivery is processed only after the switch.
        try old.send(.load(Self.request("old")))
        // The new source is behind the old one; observing it restarts the revision check from its snapshot.
        try presentation.observe(new)
        #expect(presentation.snapshot.revision == 0)
        #expect(presentation.snapshot.user == "new")
        let next = try new.send(.load(Self.request("new"))).revision
        #expect(await shown.wait(for: "new", atLeast: next) == ["old", "new", "new"])
        #expect(old.subscriberCount == 0)
        presentation.stopObserving()
        #expect(new.subscriberCount == 0)
    }

    @Test func aSharedSourceSeedsItselfAndDiscardsLateDeliveriesFromTheOldSource() async throws {
        let old = try sharedHost("old", holding: true)
        let new = try sharedHost("new")
        let ahead = try advance({ try old.send($0).revision }, "old")
        let presentation = SnapshotObservableObject(new.snapshot())
        let shown = Shown(presentation)
        try presentation.observe(old)
        #expect(presentation.snapshot.revision == ahead)
        let followed = try old.send(.load(Self.request("old"))).revision
        #expect(await shown.wait(for: "old", atLeast: followed).allSatisfy { $0 == "old" })
        // A delivery the old source has already offered arrives after the switch and is discarded.
        try old.send(.cancel)
        try presentation.observe(new)
        #expect(presentation.snapshot.revision == 0)
        #expect(presentation.snapshot.user == "new")
        let next = try new.send(.load(Self.request("new"))).revision
        #expect(await shown.wait(for: "new", atLeast: next).allSatisfy { $0 == "new" })
        #expect(presentation.snapshot.user == "new")
        presentation.stopObserving()
    }

    @Test func anActorSourceSeedsItselfOnceItArrives() async throws {
        let old = try sharedHost("old", holding: true)
        let new = GeneratedProfile.ActorHost(
            .init(userID: try UserID("new")),
            fetchDriver: { _ in .failure(.unavailable) },
            auditDriver: { _ in .failure(.unavailable) }
        )
        let ahead = try advance({ try old.send($0).revision }, "old")
        let presentation = SnapshotObservableObject(old.snapshot())
        let shown = Shown(presentation)
        try presentation.observe(old)
        #expect(presentation.snapshot.revision == ahead)
        try await presentation.observe(new)
        #expect(presentation.snapshot.revision == 0)
        #expect(presentation.snapshot.user == "new")
        #expect(presentation.isObserving)
        let next = try await new.send(.load(Self.request("new"))).revision
        #expect(await shown.wait(for: "new", atLeast: next).drop { $0 == "old" }.allSatisfy { $0 == "new" })
        #expect(old.subscriberCount == 0)
        presentation.stopObserving()
        await new.close()
    }

    @Test func aSourceConfinedToTheMainActorSeedsItselfSynchronously() async throws {
        let old = try mainActorHost("old")
        let new = GeneratedProfile.IsolatedHost<MainActor>(
            .init(userID: try UserID("new")),
            isolation: MainActor.shared,
            fetchDriver: { _, _ in .failure(.unavailable) },
            auditDriver: { _, _ in .failure(.unavailable) }
        )
        _ = try advance({ try old.send($0).revision }, "old")
        let presentation = SnapshotObservableObject(old.snapshot())
        let shown = Shown(presentation)
        try presentation.observe(old)
        try presentation.observe(new)
        #expect(presentation.snapshot.revision == 0)
        #expect(presentation.snapshot.user == "new")
        #expect(new.subscriberCount() == 1)
        #expect(old.subscriberCount == 0)
        let next = try new.send(.load(Self.request("new"))).revision
        #expect(await shown.wait(for: "new", atLeast: next).drop { $0 == "old" }.allSatisfy { $0 == "new" })
        presentation.stopObserving()
        #expect(new.subscriberCount() == 0)
    }

    @Test func aSourceConfinedToAnotherActorHandsItsSeedToTheMainActor() async throws {
        let old = try mainActorHost("old")
        let desk = await ProfileDesk(try UserID("new"))
        let ahead = try advance({ try old.send($0).revision }, "old")
        let presentation = SnapshotObservableObject(old.snapshot())
        let shown = Shown(presentation)
        try presentation.observe(old)
        #expect(presentation.snapshot.revision == ahead)
        try await desk.present(on: presentation)
        #expect(presentation.snapshot.revision == 0)
        #expect(presentation.snapshot.user == "new")
        let next = try await desk.send(.load(Self.request("new")))
        #expect(await shown.wait(for: "new", atLeast: next).drop { $0 == "old" }.allSatisfy { $0 == "new" })
        #expect(old.subscriberCount == 0)
        presentation.stopObserving()
    }

    @Test func anObservationPresentationBindsToEachSourceKind() async throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let main = try mainActorHost("old")
        let shared = try sharedHost("new")
        let ahead = try advance({ try main.send($0).revision }, "old")
        let presentation = SnapshotPresentation(shared.snapshot())
        try presentation.observe(main)
        #expect(presentation.snapshot.revision == ahead)
        try presentation.observe(shared)
        #expect(presentation.snapshot.revision == 0)
        #expect(presentation.snapshot.user == "new")
        let (changes, changed) = AsyncStream<Void>.makeStream()
        withObservationTracking {
            _ = presentation.snapshot
        } onChange: {
            changed.yield(())
        }
        let next = try shared.send(.load(Self.request("new"))).revision
        var iterator = changes.makeAsyncIterator()
        _ = await iterator.next()
        #expect(presentation.snapshot.revision >= next)
        #expect(presentation.snapshot.user == "new")
        #expect(main.subscriberCount == 0)
        presentation.stopObserving()
    }

    @Test func aRefusedRegistrationLeavesThePresentationNotObserving() throws {
        let full = GeneratedProfile.MainActorHost(
            .init(userID: try UserID("full")),
            fetchDriver: { _ in .failure(.unavailable) },
            auditDriver: { _ in .failure(.unavailable) },
            configuration: try GeneratedProfile.Configuration(subscribers: 1)
        )
        let holder = try full.subscribe { _ in }
        let presentation = SnapshotObservableObject(full.snapshot())
        #expect(throws: SubscriptionFailure.capacityExceeded) { try presentation.observe(full) }
        #expect(!presentation.isObserving)
        holder.cancel()
    }
}
