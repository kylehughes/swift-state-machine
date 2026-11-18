import Combine
import Observation
import StateMachine
import StateMachineExamples
import StateMachineUI
import SwiftUI
import Testing
import os

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
        let closing = presentation.$snapshot.dropFirst()
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
        let nested = presentation.$snapshot.dropFirst()
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
        presentation.observe(try owner.snapshots())
        #expect(presentation.isObserving)
        let ended = Signal()
        var published: [UInt64] = []
        let snapshots = presentation.$snapshot.dropFirst().sink { published.append($0.revision) }
        let observing = presentation.$isObserving.dropFirst().sink { if !$0 { ended.raise() } }
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
        // Each `observe` first stops the previous observation, then starts its own.
        let expected = [false, true, false, false, true, false]
        var observing: [Bool] = []
        let ended = Signal()
        let history = presentation.$isObserving.dropFirst()
            .sink {
                observing.append($0)
                if observing.count == expected.count { ended.raise() }
            }
        let detached = Signal()
        presentation.observe(try owner.snapshots({ $0 }, onDetach: { detached.raise() }))
        try advance(owner)
        presentation.stopObserving()
        // Cleanup edge: the stopped consumer has removed its registration.
        await detached.wait()
        #expect(presentation.snapshot.revision == 0)
        presentation.observe(try owner.snapshots())
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
        #expect(model.isObserving)
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
        var lateReceive: (@MainActor (GeneratedProfile.Snapshot) -> Void)?
        var lateFinish: (@MainActor () -> Void)?
        try presentation.observe { receive, finish in
            lateReceive = receive
            lateFinish = finish
            return MainActorSnapshotSubscription(onCancel: {})
        }
        let shown = try advance(first, user)
        presentation.apply(shown.snapshot)
        #expect(presentation.snapshot.revision == 3)
        // The second owner counts its own revisions from zero.
        try presentation.observe(startingAt: second.snapshot()) { (receive, finish) throws(SubscriptionFailure) in
            try second.subscribe(receive, onFinish: finish)
        }
        guard case .idle = presentation.snapshot else { throw Failure.unexpected }
        #expect(presentation.snapshot.revision == 0 && presentation.isObserving)
        lateReceive?(first.close().snapshot)
        lateFinish?()
        guard case .idle = presentation.snapshot else { throw Failure.unexpected }
        #expect(presentation.isObserving)
        // The new source's next change is shown, though its revision is below the old source's.
        // The owner's driver can settle at once, so the test keeps the snapshot that was published.
        let published = Signal()
        var shownNext: GeneratedProfile.Snapshot?
        let sink = presentation.$snapshot.dropFirst()
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

    @Test func aSequenceFromAnotherOwnerStartsFromItsCurrentSnapshot() async throws {
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
        // Without a starting snapshot, a lower revision from another owner would be discarded.
        presentation.observe(try shared.snapshots(), startingAt: shared.snapshot())
        guard case .idle = presentation.snapshot else { throw Failure.unexpected }
        #expect(presentation.snapshot.revision == 0)
        let closed = shared.close()
        await presentation.follow(try shared.snapshots(), startingAt: shared.snapshot())
        #expect(presentation.snapshot.isClosed && presentation.snapshot.revision == closed.revision)
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            // The first owner's own driver may have settled its load since, so read its revision again.
            let shown = first.snapshot()
            let model = SnapshotPresentation(shown)
            await model.follow(try shared.snapshots(), startingAt: shared.snapshot())
            #expect(model.snapshot.isClosed && model.snapshot.revision == closed.revision)
            let current = first.snapshot()
            try model.observe(startingAt: current) { (receive, finish) throws(SubscriptionFailure) in
                try first.subscribe(receive, onFinish: finish)
            }
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
    /// Fake registrations that record their receivers and their cancellation, in order.
    @MainActor private final class Registrations {
        var receivers: [String: @MainActor (GeneratedProfile.Snapshot) -> Void] = [:]
        var cancelled: [String] = []
        func register(
            _ name: String,
            _ receive: @escaping @MainActor (GeneratedProfile.Snapshot) -> Void
        ) -> MainActorSnapshotSubscription {
            receivers[name] = receive
            return MainActorSnapshotSubscription(onCancel: { [self] in cancelled.append(name) })
        }
    }

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
        let registrations = Registrations()
        var switched = false
        let sink = presentation.$snapshot.dropFirst()
            .sink { _ in
                guard !switched else { return }
                switched = true
                try? presentation.observe(startingAt: sources.c) { receive, _ in registrations.register("C", receive) }
            }
        try presentation.observe(startingAt: sources.b) { receive, _ in registrations.register("B", receive) }
        sink.cancel()
        #expect(registrations.cancelled == [])
        #expect(registrations.receivers.keys.sorted() == ["C"])
        registrations.receivers["B"]?(sources.bLate)
        #expect(presentation.snapshot.revision == sources.c.revision)
        #expect(presentation.isObserving)
        presentation.stopObserving()
        #expect(registrations.cancelled == ["C"])
        await finish(sources)
    }

    @Test func aRegistrationThatSwitchesSourcesLosesToTheSourceItStarted() async throws {
        let sources = try sources()
        let presentation = SnapshotObservableObject(sources.a)
        let registrations = Registrations()
        try presentation.observe(startingAt: sources.b) { receive, _ in
            try? presentation.observe(startingAt: sources.c) { receive, _ in registrations.register("C", receive) }
            return registrations.register("B", receive)
        }
        // B's registration came back after C replaced it, so it is cancelled and C's is kept.
        #expect(registrations.cancelled == ["B"])
        registrations.receivers["B"]?(sources.bLate)
        #expect(presentation.snapshot.revision == sources.c.revision)
        #expect(presentation.isObserving)
        presentation.stopObserving()
        #expect(registrations.cancelled == ["B", "C"])
        await finish(sources)
    }

    @Test func aSequenceReplacedWhileItsSourceIsShownIsNeverFollowed() async throws {
        let sources = try sources()
        let user = try UserID("kyle")
        let shared = GeneratedProfile.Shared(
            .init(userID: user),
            fetchDriver: { _ in .failure(.unavailable) },
            auditDriver: { _ in .failure(.unavailable) }
        )
        let presentation = SnapshotObservableObject(sources.a)
        let registrations = Registrations()
        var switches = 0
        let sink = presentation.$snapshot.dropFirst()
            .sink { snapshot in
                guard snapshot.revision == shared.snapshot().revision, case .idle = snapshot else { return }
                switches += 1
                try? presentation.observe(startingAt: sources.c) { receive, _ in registrations.register("C", receive) }
            }
        presentation.observe(try shared.snapshots(), startingAt: shared.snapshot())
        // The replaced sequence is released at once rather than followed.
        #expect(shared.subscriberCount == 0)
        // `follow` returns at once when its sequence is replaced before it starts.
        await presentation.follow(try shared.snapshots(), startingAt: shared.snapshot())
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

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    @Test func anObservationChangeThatSwitchesSourcesKeepsTheNewestRegistration() async throws {
        let sources = try sources()
        let model = SnapshotPresentation(sources.a)
        let registrations = Registrations()
        let c = sources.c
        withObservationTracking {
            _ = model.snapshot
        } onChange: {
            MainActor.assumeIsolated {
                try? model.observe(startingAt: c) { receive, _ in registrations.register("C", receive) }
            }
        }
        try model.observe(startingAt: sources.b) { receive, _ in registrations.register("B", receive) }
        #expect(registrations.cancelled == [])
        #expect(registrations.receivers.keys.sorted() == ["C"])
        registrations.receivers["B"]?(sources.bLate)
        #expect(model.snapshot.revision == sources.c.revision)
        #expect(model.isObserving)
        // A registration that switches sources loses to the source it started.
        try model.observe(startingAt: sources.b) { receive, _ in
            try? model.observe(startingAt: c) { receive, _ in registrations.register("C2", receive) }
            return registrations.register("B2", receive)
        }
        #expect(registrations.cancelled == ["C", "B2"])
        registrations.receivers["B2"]?(sources.bLate)
        #expect(model.snapshot.revision == sources.c.revision)
        model.stopObserving()
        #expect(registrations.cancelled == ["C", "B2", "C2"])
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
