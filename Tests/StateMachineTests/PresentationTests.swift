import Combine
import Observation
import StateMachine
import StateMachineExamples
import StateMachineUI
import SwiftUI
import Testing
import os

/// Fake registrations that record their receivers, finishes, and cancellations, in order.
@MainActor private final class SourceRegistrations {
    var receivers: [String: @MainActor (GeneratedProfile.Snapshot) -> Void] = [:]
    var finishers: [String: @MainActor () -> Void] = [:]
    var cancelled: [String] = []
    func register(
        _ name: String,
        _ receive: @escaping @MainActor (GeneratedProfile.Snapshot) -> Void,
        _ finish: @escaping @MainActor () -> Void,
        whileCancelling: (@MainActor @Sendable () -> Void)?
    ) -> MainActorSnapshotSubscription {
        receivers[name] = receive
        finishers[name] = finish
        return MainActorSnapshotSubscription(onCancel: { [self] in
            cancelled.append(name)
            whileCancelling?()
        })
    }
}

/// A `MainActor` source that delivers its snapshot synchronously when it registers, as a generated host
/// does, and can run a callback while it registers or while its registration is cancelled.
///
/// It conforms to the host protocol, which confers no authority, so a presentation observes it through
/// the same `observe(_:)` as a generated host.
@MainActor private final class FakeSource: MainActorStateMachineHost {
    struct Receipt: StateMachineReceipt {
        let snapshot: GeneratedProfile.Snapshot
        var edgeID: String? { nil }
    }
    struct Prepared: ~Copyable {}
    enum SendRejection: Error {}

    private let name: String
    private let current: GeneratedProfile.Snapshot
    private let registrations: SourceRegistrations
    /// Runs inside `subscribe`, before the registration exists.
    var whileRegistering: (@MainActor @Sendable () -> Void)?
    /// Runs when the registration is cancelled, after it is recorded.
    var whileCancelling: (@MainActor @Sendable () -> Void)?

    init(_ name: String, _ current: GeneratedProfile.Snapshot, _ registrations: SourceRegistrations) {
        self.name = name
        self.current = current
        self.registrations = registrations
    }

    func snapshot() -> GeneratedProfile.Snapshot { current }
    func send(_ input: Never) throws(SendRejection) -> Receipt {}
    func commit(_ prepared: consuming Prepared) {}
    func subscribe(
        _ receive: @escaping @MainActor (GeneratedProfile.Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        whileRegistering?()
        let token = registrations.register(name, receive, onFinish, whileCancelling: whileCancelling)
        receive(current)
        return token
    }
    func close() -> Receipt { Receipt(snapshot: current) }
}

@MainActor @Suite struct PresentationTests {
    private enum Failure: Error { case unexpected }

    private func host(_ user: UserID) -> GeneratedProfile.MainActorHost {
        GeneratedProfile.MainActorHost(
            .init(userID: user),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
        )
    }

    @Test func sendPublishesInTheSameTurnAndReportsOneRejectionChannel() async throws {
        let user = try UserID("kyle")
        let presentation = StateMachineObservableObject(host(user))
        #expect(presentation.isObserving)
        #expect(presentation.snapshot.revision == 0)
        let receipt = try presentation.send(.load(ProfileRequest(userID: user)))
        #expect(receipt.revision == 1)
        #expect(presentation.snapshot.revision == 1)
        guard case .loading = presentation.snapshot else { throw Failure.unexpected }
        do {
            try presentation.send(.retry)
            Issue.record("An input with no edge from the current phase was admitted")
        } catch {
            guard case .preparation(.invalidPhase) = error else { throw Failure.unexpected }
        }
        #expect(presentation.snapshot.revision == 1)
        let closed = presentation.close()
        #expect(presentation.snapshot.isClosed)
        #expect(presentation.snapshot.revision == closed.revision)
        #expect(!presentation.isObserving)
        do {
            try presentation.send(.cancel)
            Issue.record("A closed owner admitted an input")
        } catch {
            guard case .commit(.closed) = error else { throw Failure.unexpected }
        }
        await presentation.host.shutdown()
        #expect(presentation.host.isQuiescent)
    }

    @Test func domainRejectionKeepsItsTypedCase() async throws {
        let presentation = StateMachineObservableObject(host(try UserID("kyle")))
        let foreign = try ProfileRequest(userID: try UserID("someone-else"))
        do {
            try presentation.send(.load(foreign))
            Issue.record("A request for another user was admitted")
        } catch {
            guard case .preparation(.begin(.wrongUser)) = error else { throw Failure.unexpected }
        }
        #expect(presentation.snapshot.revision == 0)
        presentation.close()
        await presentation.host.shutdown()
    }

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    @Test func observableModelTracksItsSnapshotAndPublishesInTheSameTurn() async throws {
        let user = try UserID("kyle")
        let model = StateMachinePresentation(host(user))
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = model.snapshot
        } onChange: {
            changed.withLock { $0 = true }
        }
        #expect(!changed.withLock { $0 })
        let receipt = try model.send(.load(ProfileRequest(userID: user)))
        #expect(changed.withLock { $0 })
        #expect(model.snapshot.revision == receipt.revision)
        #expect(model.isObserving)
        model.close()
        #expect(model.snapshot.isClosed)
        #expect(!model.isObserving)
        await model.host.shutdown()
        #expect(model.host.isQuiescent)
    }

    @Test func commitAdmitsATypedEdgeInTheSameTurnAndRejectsAStaleObservation() async throws {
        let user = try UserID("kyle")
        let presentation = StateMachineObservableObject(host(user))
        guard case .idle(let idle) = presentation.snapshot else { throw Failure.unexpected }
        let request = try ProfileRequest(userID: user)
        guard case .committed(let receipt) = presentation.commit(try idle.begin(request)) else {
            throw Failure.unexpected
        }
        #expect(presentation.snapshot.revision == receipt.revision)
        guard case .loading = presentation.snapshot else { throw Failure.unexpected }
        // The edge still exists on the old observation, but that observation is no longer current.
        guard case .rejected(.conflict, let current) = presentation.commit(try idle.begin(request)) else {
            throw Failure.unexpected
        }
        #expect(current.revision == receipt.revision)
        #expect(presentation.snapshot.revision == receipt.revision)
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            let model = StateMachinePresentation(presentation.host)
            guard case .loading(let loading) = model.snapshot, case .committed = model.commit(loading.cancel())
            else { throw Failure.unexpected }
            guard case .idle = model.snapshot else { throw Failure.unexpected }
        }
        presentation.close()
        await presentation.host.shutdown()
    }

    @Test func aRegistrationTokenRunsItsActionOnceAcrossCancelAndRelease() async throws {
        var count = 0
        var cancelled: MainActorSnapshotSubscription? = MainActorSnapshotSubscription(onCancel: { count += 1 })
        cancelled?.cancel()
        cancelled?.cancel()
        cancelled = nil
        var released: MainActorSnapshotSubscription? = MainActorSnapshotSubscription(onCancel: { count += 10 })
        #expect(released != nil)
        released = nil
        // Main-actor jobs run in order, so both releases' actions, if any, ran before this one.
        await Task { @MainActor in }.value
        #expect(count == 11)
    }

    @Test func snapshotsDescribeTheirPhaseAndRevisionWithoutThePayload() async throws {
        let owner = host(try UserID("kyle"))
        #expect("\(owner.snapshot())" == "idle, revision 0")
        guard case .idle(let idle) = owner.snapshot() else { throw Failure.unexpected }
        #expect(idle.description == "Idle, revision 0")
        let closed = owner.close()
        #expect(closed.description == "idle, revision 1, closed")
        await owner.shutdown()
    }

    @Test func presentingAClosedOwnerIsNotObserving() async throws {
        let owner = host(try UserID("kyle"))
        let closed = owner.close()
        let presentation = StateMachineObservableObject(owner)
        #expect(!presentation.isObserving)
        #expect(presentation.snapshot.isClosed && presentation.snapshot.revision == closed.revision)
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            let model = StateMachinePresentation(owner)
            #expect(!model.isObserving)
            #expect(model.snapshot.isClosed)
        }
        await owner.shutdown()
    }

    @Test func aSinkThatClosesDuringPublicationLeavesTheTerminalSnapshotVisible() async throws {
        let user = try UserID("kyle")
        let presentation = StateMachineObservableObject(host(user))
        var published: [UInt64] = []
        // `@Published` emits from `willSet`, so this closes while revision 1 is still being assigned.
        let closing = presentation.presentedSnapshots.dropFirst()
            .sink {
                published.append($0.revision)
                if $0.revision == 1 { presentation.close() }
            }
        try presentation.send(.load(ProfileRequest(userID: user)))
        #expect(presentation.snapshot.isClosed)
        #expect(presentation.snapshot.revision == presentation.host.snapshot().revision)
        #expect(published == [1, 2])
        closing.cancel()
        await presentation.host.shutdown()
    }

    @Test func aSinkThatAppliesANewerSnapshotDuringPublicationKeepsTheNewerOne() async throws {
        let user = try UserID("kyle")
        let owner = host(user)
        let presentation = SnapshotObservableObject(owner.snapshot())
        let first = try owner.send(.load(ProfileRequest(userID: user)))
        let second = owner.close()
        let nested = presentation.presentedSnapshots.dropFirst()
            .sink {
                if $0.revision == first.revision { presentation.apply(second.snapshot) }
            }
        #expect(presentation.apply(first.snapshot))
        #expect(presentation.snapshot.isClosed && presentation.snapshot.revision == second.revision)
        #expect(!presentation.apply(first.snapshot))
        nested.cancel()
        await owner.shutdown()
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SequencePresentationTests {
    private typealias Host = RuntimeSharedHost<Int, Int, RuntimeTicket, Never>
    private typealias Engine = Host.Engine

    /// A one-shot event a test awaits instead of inferring progress from scheduling.
    private struct Signal: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
        func raise() { continuation.yield(()) }
        func wait() async {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }

    private func host() throws -> Host {
        Host(
            manual: 0,
            scopes: [],
            limits: try Limits(),
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
    }

    private func advance(_ owner: Host) throws {
        _ = owner.commit(try Engine.prepare(on: owner.snapshot(), next: owner.snapshot().model + 1))
    }

    @Test func generatedSnapshotsNeedNoRevisionProjection() throws {
        let owner = GeneratedProfile.Shared(
            .init(userID: try UserID("kyle")),
            drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
        )
        let presentation = SnapshotObservableObject(owner.snapshot())
        let closed = owner.close()
        #expect(presentation.apply(closed.snapshot))
        #expect(!presentation.apply(owner.snapshot()))
        #expect(presentation.snapshot.isClosed)
    }

    @Test func publishesASharedOwnersSnapshotsUntilItCloses() async throws {
        let owner = try host()
        let presentation = SnapshotObservableObject(owner.snapshot(), revision: \.revision)
        let live = Signal()
        let ended = Signal()
        var published: [UInt64] = []
        let snapshots = presentation.presentedSnapshots.dropFirst().sink { published.append($0.revision) }
        let observing = presentation.$isObserving.dropFirst().sink { $0 ? live.raise() : ended.raise() }
        presentation.observe(try owner.snapshots())
        // The sequence's first element reaches the presentation on the registration's delivery task;
        // the observation is live once it is shown.
        await live.wait()
        #expect(presentation.isObserving)
        try advance(owner)
        let closed = owner.close()
        // Completion edge: the sequence delivered the closed snapshot and then ended.
        await ended.wait()
        #expect(presentation.snapshot.isClosed && presentation.snapshot.revision == closed.revision)
        #expect(zip(published, published.dropFirst()).allSatisfy { $0 < $1 })
        #expect(published.last == closed.revision)
        #expect(!presentation.isObserving)
        snapshots.cancel()
        observing.cancel()
    }

    @Test func stoppingDiscardsLaterSnapshotsAndAReplacementKeepsObserving() async throws {
        let owner = try host()
        let presentation = SnapshotObservableObject(owner.snapshot(), revision: \.revision)
        // Each `observe` first stops the previous observation, which publishes nothing when none is
        // live, then starts its own, which is live once its first element is shown.
        let expected = [true, false, true, false]
        var observing: [Bool] = []
        let live = Signal()
        let ended = Signal()
        let history = presentation.$isObserving.dropFirst()
            .sink {
                observing.append($0)
                if $0 { live.raise() }
                if observing.count == expected.count { ended.raise() }
            }
        let detached = Signal()
        presentation.observe(try owner.snapshots({ $0 }, onDetach: { detached.raise() }))
        await live.wait()
        try advance(owner)
        presentation.stopObserving()
        // Cleanup edge: the stopped consumer has removed its registration.
        await detached.wait()
        #expect(presentation.snapshot.revision == 0)
        presentation.observe(try owner.snapshots())
        await live.wait()
        let closed = owner.close()
        await ended.wait()
        #expect(observing == expected)
        #expect(presentation.snapshot.revision == closed.revision)
        history.cancel()
    }

    @Test func followReturnsAfterTheClosedSnapshot() async throws {
        let owner = try host()
        let presentation = SnapshotObservableObject(owner.snapshot(), revision: \.revision)
        try advance(owner)
        let closed = owner.close()
        await presentation.follow(try owner.snapshots())
        #expect(presentation.snapshot.isClosed && presentation.snapshot.revision == closed.revision)
        #expect(!presentation.isObserving)
    }

    @Test func cancellingTheFollowingTaskStopsObservingAndFreesItsSlot() async throws {
        let owner = try host()
        let presentation = SnapshotObservableObject(owner.snapshot(), revision: \.revision)
        let started = Signal()
        let observing = presentation.$isObserving.dropFirst().sink { if $0 { started.raise() } }
        let detached = Signal()
        // The test keeps the sequence alive, so only the cancelled iterator can free the slot.
        let snapshots = try owner.snapshots({ $0 }, onDetach: { detached.raise() })
        let following = Task { await presentation.follow(snapshots) }
        // Attachment edge: `follow` has taken ownership of the observation.
        await started.wait()
        following.cancel()
        await following.value
        #expect(!presentation.isObserving)
        // Cleanup edge: the cancelled consumer has removed its registration.
        await detached.wait()
        observing.cancel()
    }

    @Test func stoppingEndsAFollowingTask() async throws {
        let owner = try host()
        let presentation = SnapshotObservableObject(owner.snapshot(), revision: \.revision)
        let started = Signal()
        let observing = presentation.$isObserving.dropFirst().sink { if $0 { started.raise() } }
        let snapshots = try owner.snapshots()
        let following = Task { await presentation.follow(snapshots) }
        await started.wait()
        presentation.stopObserving()
        await following.value
        try advance(owner)
        #expect(presentation.snapshot.revision == 0 && !presentation.isObserving)
        observing.cancel()
    }

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    @Test func observableModelFollowsASharedOwnerUntilItCloses() async throws {
        let owner = try host()
        let model = SnapshotPresentation(owner.snapshot(), revision: \.revision)
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = model.snapshot
        } onChange: {
            changed.withLock { $0 = true }
        }
        try advance(owner)
        let closed = owner.close()
        await model.follow(try owner.snapshots())
        #expect(changed.withLock { $0 })
        #expect(model.snapshot.isClosed && model.snapshot.revision == closed.revision)
        #expect(!model.isObserving)
    }

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    @Test func observableModelStopsApplyingAfterItStopsObserving() async throws {
        let owner = try host()
        let model = SnapshotPresentation(owner.snapshot(), revision: \.revision)
        let detached = Signal()
        model.observe(try owner.snapshots({ $0 }, onDetach: { detached.raise() }))
        await untilObserving(model)
        try advance(owner)
        model.stopObserving()
        // Cleanup edge: the stopped consumer has removed its registration.
        await detached.wait()
        #expect(model.snapshot.revision == 0 && !model.isObserving)
    }
}

/// A presentation constructs without throwing, and a passive one can change the owner it shows.
@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationSourceTests {
    private enum Failure: Error { case unexpected }

    /// A one-shot event a test awaits instead of inferring progress from scheduling.
    private struct Signal: Sendable {
        private let stream: AsyncStream<Void>
        private let continuation: AsyncStream<Void>.Continuation

        init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
        func raise() { continuation.yield(()) }
        func wait() async {
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
        }
    }

    private static let drivers = GeneratedProfile.MainActorDrivers(
        fetch: { _ in .failure(.unavailable) },
        audit: { _ in .failure(.unavailable) }
    )

    private func host(
        _ user: UserID,
        configuration: GeneratedProfile.Configuration = .default
    ) -> GeneratedProfile.MainActorHost {
        GeneratedProfile.MainActorHost(.init(userID: user), drivers: Self.drivers, configuration: configuration)
    }

    /// Advances an owner to revision 3, in the loading phase, and returns that receipt.
    private func advance(_ owner: GeneratedProfile.MainActorHost, _ user: UserID) throws -> GeneratedProfile.Receipt {
        try owner.send(.load(ProfileRequest(userID: user)))
        try owner.send(.cancel)
        return try owner.send(.load(ProfileRequest(userID: user)))
    }

    @Test func aPresentationOfAnOwnerAtCapacityReportsWhyItIsNotObserving() async throws {
        let user = try UserID("kyle")
        let owner = host(user, configuration: try GeneratedProfile.Configuration(subscribers: 1))
        let first = StateMachineObservableObject(owner)
        #expect(first.isObserving && first.observationFailure == nil)
        let refused = StateMachineObservableObject(owner)
        #expect(!refused.isObserving)
        #expect(refused.observationFailure == .capacityExceeded)
        // It still shows the owner and publishes every change made through it.
        let receipt = try refused.send(.load(ProfileRequest(userID: user)))
        #expect(refused.snapshot.revision == receipt.revision)
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            let model = StateMachinePresentation(owner)
            #expect(!model.isObserving)
            #expect(model.observationFailure == .capacityExceeded)
            #expect(model.snapshot.revision == receipt.revision)
        }
        first.stopObserving()
        let replacement = StateMachineObservableObject(owner)
        #expect(replacement.isObserving && replacement.observationFailure == nil)
        owner.close()
        await owner.shutdown()
    }

    @Test func observingAnotherOwnerShowsItAtOnceAndIgnoresTheReplacedOne() async throws {
        let user = try UserID("kyle")
        let first = host(user)
        let second = host(user)
        let presentation = SnapshotObservableObject(first.snapshot())
        // The first source keeps its callbacks, so the test can deliver late on its behalf.
        let registrations = SourceRegistrations()
        try presentation.observe(FakeSource("first", first.snapshot(), registrations))
        let shown = try advance(first, user)
        presentation.apply(shown.snapshot)
        #expect(presentation.snapshot.revision == 3)
        // The second owner counts its own revisions from zero.
        try presentation.observe(second)
        guard case .idle = presentation.snapshot else { throw Failure.unexpected }
        #expect(presentation.snapshot.revision == 0 && presentation.isObserving)
        #expect(registrations.cancelled == ["first"])
        registrations.receivers["first"]?(first.close().snapshot)
        registrations.finishers["first"]?()
        guard case .idle = presentation.snapshot else { throw Failure.unexpected }
        #expect(presentation.isObserving)
        // The new source's next change is shown, though its revision is below the old source's.
        // The owner's driver can settle at once, so the test keeps the snapshot that was published.
        let published = Signal()
        var shownNext: GeneratedProfile.Snapshot?
        let sink = presentation.presentedSnapshots.dropFirst()
            .sink {
                guard $0.revision == 1 else { return }
                shownNext = $0
                published.raise()
            }
        try second.send(.load(ProfileRequest(userID: user)))
        await published.wait()
        guard case .loading = shownNext else { throw Failure.unexpected }
        #expect(presentation.snapshot.revision >= 1)
        sink.cancel()
        presentation.stopObserving()
        second.close()
        await first.shutdown()
        await second.shutdown()
    }

    @Test func aSequenceFromAnotherOwnerSeedsTheRevisionCheckWithItsFirstElement() async throws {
        let user = try UserID("kyle")
        let shared = GeneratedProfile.Shared(
            .init(userID: user),
            fetchDriver: { _ in .failure(.unavailable) },
            auditDriver: { _ in .failure(.unavailable) }
        )
        let first = host(user)
        let presentation = SnapshotObservableObject(first.snapshot())
        presentation.apply(try advance(first, user).snapshot)
        #expect(presentation.snapshot.revision == 3)
        // The other owner's first element has a lower revision, and it is shown, because it seeds the check.
        let seeded = Signal()
        let sink = presentation.presentedSnapshots.dropFirst().sink { if $0.revision == 0 { seeded.raise() } }
        presentation.observe(try shared.snapshots())
        await seeded.wait()
        sink.cancel()
        guard case .idle = presentation.snapshot else { throw Failure.unexpected }
        #expect(presentation.isObserving)
        let closed = shared.close()
        await presentation.follow(try shared.snapshots())
        #expect(presentation.snapshot.isClosed && presentation.snapshot.revision == closed.revision)
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            // The first owner's own driver may have settled its load since, so read its revision again.
            let shown = first.snapshot()
            let model = SnapshotPresentation(shown)
            await model.follow(try shared.snapshots())
            #expect(model.snapshot.isClosed && model.snapshot.revision == closed.revision)
            let current = first.snapshot()
            try model.observe(first)
            #expect(model.snapshot.revision == current.revision && model.isObserving)
            model.stopObserving()
        }
        first.close()
        await first.shutdown()
        await shared.shutdown()
    }
}

/// Reentrant source replacement in a passive presentation.
///
/// A synchronous callback can switch a passive presentation to another source while it shows a new
/// one. The newest observation keeps its registration, and the one it replaced keeps none.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ReentrantSourceReplacementTests {
    /// Snapshots from three separate owners.
    ///
    /// A is shown first, B is the source being installed, and C replaces it. B's late snapshot has a
    /// higher revision than C's, so only the generation check can discard it.
    private struct Sources {
        let a: GeneratedProfile.Snapshot
        let b: GeneratedProfile.Snapshot
        let bLate: GeneratedProfile.Snapshot
        let c: GeneratedProfile.Snapshot
        let owners: [GeneratedProfile.MainActorHost]
    }

    private func sources() throws -> Sources {
        let user = try UserID("kyle")
        let drivers = GeneratedProfile.MainActorDrivers(
            fetch: { _ in .failure(.unavailable) },
            audit: { _ in .failure(.unavailable) }
        )
        let owners = (0 ..< 3).map { _ in GeneratedProfile.MainActorHost(.init(userID: user), drivers: drivers) }
        let request = try ProfileRequest(userID: user)
        let b = owners[1].snapshot()
        try owners[1].send(.load(request))
        try owners[1].send(.cancel)
        try owners[1].send(.load(request))
        let bLate = try owners[1].send(.cancel).snapshot
        try owners[2].send(.load(request))
        try owners[2].send(.cancel)
        let c = try owners[2].send(.load(request)).snapshot
        return Sources(a: owners[0].snapshot(), b: b, bLate: bLate, c: c, owners: owners)
    }

    private func finish(_ sources: Sources) async {
        for owner in sources.owners {
            owner.close()
            await owner.shutdown()
        }
    }

    @Test func aSinkThatSwitchesSourcesWhileBIsShownKeepsCsRegistration() async throws {
        let sources = try sources()
        let presentation = SnapshotObservableObject(sources.a)
        let registrations = SourceRegistrations()
        let c = FakeSource("C", sources.c, registrations)
        var switched = false
        let sink = presentation.presentedSnapshots.dropFirst()
            .sink { _ in
                guard !switched else { return }
                switched = true
                try? presentation.observe(c)
            }
        // B's first delivery shows B, and the sink switches to C before B's registration returns.
        try presentation.observe(FakeSource("B", sources.b, registrations))
        sink.cancel()
        #expect(registrations.cancelled == ["B"])
        #expect(registrations.receivers.keys.sorted() == ["B", "C"])
        registrations.receivers["B"]?(sources.bLate)
        #expect(presentation.snapshot.revision == sources.c.revision)
        #expect(presentation.isObserving)
        presentation.stopObserving()
        #expect(registrations.cancelled == ["B", "C"])
        await finish(sources)
    }

    @Test func aRegistrationThatSwitchesSourcesLosesToTheSourceItStarted() async throws {
        let sources = try sources()
        let presentation = SnapshotObservableObject(sources.a)
        let registrations = SourceRegistrations()
        let b = FakeSource("B", sources.b, registrations)
        let c = FakeSource("C", sources.c, registrations)
        b.whileRegistering = { try? presentation.observe(c) }
        try presentation.observe(b)
        // B's registration came back after C replaced it, so it is cancelled and C's is kept.
        #expect(registrations.cancelled == ["B"])
        registrations.receivers["B"]?(sources.bLate)
        #expect(presentation.snapshot.revision == sources.c.revision)
        #expect(presentation.isObserving)
        presentation.stopObserving()
        #expect(registrations.cancelled == ["B", "C"])
        await finish(sources)
    }

    @Test func aSourceReplacedWhileItsSnapshotIsShownIsNeverFollowed() async throws {
        let sources = try sources()
        let user = try UserID("kyle")
        let shared = GeneratedProfile.Shared(
            .init(userID: user),
            fetchDriver: { _ in .failure(.unavailable) },
            auditDriver: { _ in .failure(.unavailable) }
        )
        let presentation = SnapshotObservableObject(sources.a)
        let registrations = SourceRegistrations()
        let c = FakeSource("C", sources.c, registrations)
        var switches = 0
        let sink = presentation.presentedSnapshots.dropFirst()
            .sink { snapshot in
                guard snapshot.revision == shared.snapshot().revision, case .idle = snapshot else { return }
                switches += 1
                try? presentation.observe(c)
            }
        // The shared owner's snapshot is shown first, and the switch to C means it never registers.
        try presentation.observe(shared)
        #expect(shared.subscriberCount == 0)
        // A followed sequence whose first element switches to C is released, and `follow` returns.
        await presentation.follow(try shared.snapshots())
        #expect(shared.subscriberCount == 0)
        sink.cancel()
        #expect(switches == 2)
        #expect(registrations.cancelled == ["C"])
        #expect(presentation.snapshot.revision == sources.c.revision)
        #expect(presentation.isObserving)
        presentation.stopObserving()
        await shared.shutdown()
        await finish(sources)
    }

    @Test func cancellingTheOldSourceThatSwitchesSourcesKeepsTheNewestRegistration() async throws {
        let sources = try sources()
        let presentation = SnapshotObservableObject(sources.a)
        let registrations = SourceRegistrations()
        let a = FakeSource("A", sources.a, registrations)
        let c = FakeSource("C", sources.c, registrations)
        // A's token switches the presentation to C while it is being cancelled.
        a.whileCancelling = { try? presentation.observe(c) }
        try presentation.observe(a)
        try presentation.observe(FakeSource("B", sources.b, registrations))
        // C started while A was being cancelled, so B neither registers nor shows its snapshot.
        #expect(registrations.cancelled == ["A"])
        #expect(registrations.receivers.keys.sorted() == ["A", "C"])
        #expect(presentation.snapshot.revision == sources.c.revision)
        #expect(presentation.isObserving)
        registrations.receivers["A"]?(sources.bLate)
        #expect(presentation.snapshot.revision == sources.c.revision)
        presentation.stopObserving()
        #expect(registrations.cancelled == ["A", "C"])
        await finish(sources)
    }

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    @Test func cancellingTheOldSourceThatSwitchesSourcesKeepsTheNewestObservableRegistration() async throws {
        let sources = try sources()
        let model = SnapshotPresentation(sources.a)
        let registrations = SourceRegistrations()
        let a = FakeSource("A", sources.a, registrations)
        let c = FakeSource("C", sources.c, registrations)
        a.whileCancelling = { try? model.observe(c) }
        try model.observe(a)
        try model.observe(FakeSource("B", sources.b, registrations))
        #expect(registrations.cancelled == ["A"])
        #expect(registrations.receivers.keys.sorted() == ["A", "C"])
        #expect(model.snapshot.revision == sources.c.revision)
        #expect(model.isObserving)
        model.stopObserving()
        #expect(registrations.cancelled == ["A", "C"])
        await finish(sources)
    }

    @MainActor private final class PresentationBox {
        var presentation: SnapshotObservableObject<GeneratedProfile.Snapshot>?
    }

    @Test func aRevisionProjectionThatSwitchesSourcesDiscardsTheDeliveryBeingProjected() async throws {
        let sources = try sources()
        let registrations = SourceRegistrations()
        let box = PresentationBox()
        let c = FakeSource("C", sources.c, registrations)
        let late = sources.bLate.revision
        var switching = true
        // Projecting B's late snapshot switches the presentation to C before the snapshot is shown.
        let presentation = SnapshotObservableObject(sources.a) { snapshot in
            if switching, snapshot.revision == late {
                switching = false
                try? box.presentation?.observe(c)
            }
            return snapshot.revision
        }
        box.presentation = presentation
        try presentation.observe(FakeSource("B", sources.b, registrations))
        registrations.receivers["B"]?(sources.bLate)
        #expect(!switching)
        #expect(registrations.cancelled == ["B"])
        #expect(presentation.snapshot.revision == sources.c.revision)
        #expect(presentation.isObserving)
        presentation.stopObserving()
        #expect(registrations.cancelled == ["B", "C"])
        box.presentation = nil
        await finish(sources)
    }

    @Test func stoppingASequenceFreesItsRegistrationInTheSameTurn() async throws {
        let owner = RuntimeSharedHost<Int, Int, RuntimeTicket, Never>(
            manual: 0,
            scopes: [],
            limits: try Limits(),
            subscriberCapacity: 1,
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let presentation = SnapshotObservableObject(owner.snapshot(), revision: \.revision)
        presentation.observe(try owner.snapshots())
        presentation.stopObserving()
        #expect(owner.subscriberCount == 0)
        // The only slot is free again, so a replacement registers in the same main-actor turn.
        presentation.observe(try owner.snapshots())
        // The replacement holds the slot; it is live once its first element arrives.
        #expect(owner.subscriberCount == 1)
        presentation.stopObserving()
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            let model = SnapshotPresentation(owner.snapshot(), revision: \.revision)
            model.observe(try owner.snapshots())
            model.stopObserving()
            model.observe(try owner.snapshots())
            #expect(owner.subscriberCount == 1)
            model.stopObserving()
        }
        #expect(owner.subscriberCount == 0)
    }

    @Test func stoppingAnActorSequenceFreesItsRegistrationBeforeTheNextOne() async throws {
        let owner = RuntimeActorHost<Int, Int, RuntimeTicket, Never>(
            0,
            scopes: [],
            configuration: try ManagedConfiguration(subscribers: 1),
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let presentation = SnapshotObservableObject(await owner.snapshot(), revision: \.revision)
        presentation.observe(try await owner.snapshots())
        presentation.stopObserving()
        presentation.observe(try await owner.snapshots())
        #expect(presentation.isObserving)
        presentation.stopObserving()
        _ = await owner.close()
        await owner.shutdown()
    }

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    @Test func anObservationChangeThatSwitchesSourcesKeepsTheNewestRegistration() async throws {
        let sources = try sources()
        let model = SnapshotPresentation(sources.a)
        let registrations = SourceRegistrations()
        let c = FakeSource("C", sources.c, registrations)
        withObservationTracking {
            _ = model.snapshot
        } onChange: {
            MainActor.assumeIsolated { try? model.observe(c) }
        }
        // B's first delivery changes the snapshot, and the change switches to C before B's registration returns.
        try model.observe(FakeSource("B", sources.b, registrations))
        #expect(registrations.cancelled == ["B"])
        #expect(registrations.receivers.keys.sorted() == ["B", "C"])
        registrations.receivers["B"]?(sources.bLate)
        #expect(model.snapshot.revision == sources.c.revision)
        #expect(model.isObserving)
        // A registration that switches sources loses to the source it started.
        let b2 = FakeSource("B2", sources.b, registrations)
        let c2 = FakeSource("C2", sources.c, registrations)
        b2.whileRegistering = { try? model.observe(c2) }
        try model.observe(b2)
        #expect(registrations.cancelled == ["B", "C", "B2"])
        registrations.receivers["B2"]?(sources.bLate)
        #expect(model.snapshot.revision == sources.c.revision)
        model.stopObserving()
        #expect(registrations.cancelled == ["B", "C", "B2", "C2"])
        await finish(sources)
    }
}

/// A view can hold a host-driving model in `@State`, because constructing one cannot throw.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
private struct LookupView: View {
    @State private var lookup = StateMachinePresentation(
        GeneratedProfile.MainActorHost(
            .init(userID: LookupView.user),
            fetchDriver: { _ in .failure(.unavailable) },
            auditDriver: { _ in .failure(.unavailable) }
        )
    )
    private static let user = try! UserID("view")
    var body: some View { Text("\(lookup.snapshot.revision)") }
}
