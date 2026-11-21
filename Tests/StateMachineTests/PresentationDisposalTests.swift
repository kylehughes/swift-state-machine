import Dispatch
import Foundation
import StateMachine
import StateMachineExamples
import StateMachineUI
import Testing
import os

// A presentation lives on the main actor, but an object that stores it can be released on another
// thread, and the presentation with it. Its gate closes there at once, and everything it holds that
// belongs to the main actor, the shown snapshot, its closures and its owner, the registration with
// its token, and an element still unread, is released on a later main-actor turn. Each test hands the
// presentation's last reference to another thread while the main actor waits, then awaits the releases.

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

/// Where and how often the values a test watches were released, and the order of its events.
private final class Releases: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (count: 0, offMain: 0, events: [String]()))
    private let signal = Signal()

    var count: Int { state.withLock { $0.count } }
    var offMain: Int { state.withLock { $0.offMain } }
    var events: [String] { state.withLock { $0.events } }
    func record(_ event: String) {
        let onMain = Thread.isMainThread
        state.withLock {
            $0.count += 1
            if !onMain { $0.offMain += 1 }
            $0.events.append(event)
        }
        signal.raise()
    }
    func note(_ event: String) { state.withLock { $0.events.append(event) } }
    /// Returns once `count` releases have been recorded.
    func wait(for count: Int) async {
        while self.count < count { await signal.wait() }
    }
}

/// A `Sendable` snapshot whose release a test records.
private final class Shot: StateMachineSnapshot, Sendable {
    let revision: UInt64
    private let name: String
    private let releases: Releases?
    init(_ revision: UInt64, _ name: String, _ releases: Releases?) {
        self.revision = revision
        self.name = name
        self.releases = releases
    }
    deinit { releases?.record(name) }
}

/// A value a closure captures, whose release a test records.
private final class Capture: Sendable {
    private let releases: Releases
    init(_ releases: Releases) { self.releases = releases }
    deinit { releases.record("capture") }
}

/// Hands one reference to another thread, which drops it while the main actor waits.
private func drop<Kept: Sendable>(_ kept: consuming Kept) {
    let slot = OSAllocatedUnfairLock<Kept?>(initialState: kept)
    let dropped = DispatchSemaphore(value: 0)
    DispatchQueue.global()
        .async {
            slot.withLock { $0 = nil }
            dropped.signal()
        }
    dropped.wait()
}

/// A sequence of an owner of the test's own, whose token records its cancellation.
private final class Feed: Sendable {
    private let receive = OSAllocatedUnfairLock<(@Sendable (Shot) -> Void)?>(initialState: nil)
    private let finish = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    private let releases: Releases

    init(_ releases: Releases) { self.releases = releases }
    func sequence(first: Shot) throws -> SnapshotSequence<Shot> {
        try SnapshotSequence<Shot> { receive, finish in
            self.receive.withLock { $0 = receive }
            self.finish.withLock { $0 = finish }
            receive(first)
            return SnapshotSubscription { [releases] in releases.note("slot freed") }
        }
    }
    func offer(_ shot: Shot) { receive.withLock { $0 }?(shot) }
}

private typealias RawHost = RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>

/// A `MainActor` host of the test's own with one slot, freed when its subscription is cancelled, whose
/// own release the test records.
@MainActor private final class DisposableHost: MainActorStateMachineHost {
    typealias Input = Never
    typealias Snapshot = Shot
    struct Receipt: StateMachineReceipt {
        let snapshot: Shot
        var edgeID: String? { nil }
    }
    typealias SendRejection = Never
    typealias Prepared = Never
    typealias CommitResult = Void

    private let releases: Releases
    private(set) var registrations = 0

    init(_ releases: Releases) { self.releases = releases }
    deinit { releases.record("host") }

    func snapshot() -> Shot { Shot(0, "shown", releases) }
    func send(_ input: Never) -> Receipt {}
    func commit(_ prepared: consuming Never) {}
    func subscribe(
        _ receive: @escaping @MainActor (Shot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        guard registrations == 0 else { throw .capacityExceeded }
        registrations += 1
        return MainActorSnapshotSubscription { [weak self, releases] in
            self?.registrations -= 1
            releases.note("slot freed")
        }
    }
    @discardableResult func close() -> Receipt { Receipt(snapshot: Shot(0, "closed", nil)) }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationDisposalTests {
    // A Combine presentation that observes a sequence is released on another thread with an element
    // still unread. The shown snapshot, the unread element, and the revision closure's capture are
    // released on the main actor, after the registration's token is cancelled.
    @Test func aCombinePresentationReleasedElsewhereReleasesWhatItHoldsOnTheMainActor() async throws {
        let releases = Releases()
        let feed = Feed(releases)
        var presentation: SnapshotObservableObject<Shot>? = SnapshotObservableObject(
            Shot(0, "initial", nil),
            revision: { [capture = Capture(releases)] shot in withExtendedLifetime(capture) { shot.revision } }
        )
        presentation?.observe(try feed.sequence(first: Shot(1, "shown", releases)))
        feed.offer(Shot(2, "unread", releases))
        guard let held = presentation.take() else { return }
        drop(consume held)
        await releases.wait(for: 3)
        #expect(releases.offMain == 0, "\(releases.events)")
        #expect(releases.events.contains("slot freed"), "\(releases.events)")
    }

    // The same for an Observation presentation.
    @Test func anObservationPresentationReleasedElsewhereReleasesWhatItHoldsOnTheMainActor() async throws {
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
        let releases = Releases()
        let feed = Feed(releases)
        var presentation: SnapshotPresentation<Shot>? = SnapshotPresentation(
            Shot(0, "initial", nil),
            revision: { [capture = Capture(releases)] shot in withExtendedLifetime(capture) { shot.revision } }
        )
        presentation?.observe(try feed.sequence(first: Shot(1, "shown", releases)))
        feed.offer(Shot(2, "unread", releases))
        guard let held = presentation.take() else { return }
        drop(consume held)
        await releases.wait(for: 3)
        #expect(releases.offMain == 0, "\(releases.events)")
        #expect(releases.events.contains("slot freed"), "\(releases.events)")
    }

    // A presentation released on another thread while it observes a generated owner's sequence frees
    // that owner's slot at once, before any main-actor turn runs.
    @Test(arguments: PresentationClass.allCases)
    func aPresentationReleasedElsewhereFreesAGeneratedOwnersSlotAtOnce(_ kind: PresentationClass) throws {
        let host = RawHost(
            0,
            scopes: [],
            configuration: try ManagedConfiguration(subscribers: 1),
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        switch kind {
        case .combine:
            var presentation: SnapshotObservableObject<UInt64>? = SnapshotObservableObject(0, revision: { $0 })
            try presentation?.observe(snapshotsFrom: { try host.sendableSnapshots { $0.revision } })
            #expect(host.subscriberCount == 1)
            guard let held = presentation.take() else { return }
            drop(consume held)
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
            var presentation: SnapshotPresentation<UInt64>? = SnapshotPresentation(0, revision: { $0 })
            try presentation?.observe(snapshotsFrom: { try host.sendableSnapshots { $0.revision } })
            #expect(host.subscriberCount == 1)
            guard let held = presentation.take() else { return }
            drop(consume held)
        }
        #expect(host.subscriberCount == 0)
    }

    // A driving presentation of either class released on another thread cancels its subscription on
    // the main actor, which frees a host of your own's slot, and then releases the shown snapshot and
    // the owner there.
    @Test(arguments: PresentationClass.allCases)
    func aDrivingPresentationReleasedElsewhereReleasesWhatItHoldsOnTheMainActor(_ kind: PresentationClass) async {
        let releases = Releases()
        switch kind {
        case .combine:
            var presentation: StateMachineObservableObject<DisposableHost>? =
                StateMachineObservableObject(DisposableHost(releases))
            #expect(presentation?.isObserving == true)
            guard let held = presentation.take() else { return }
            drop(consume held)
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
            var presentation: StateMachinePresentation<DisposableHost>? =
                StateMachinePresentation(DisposableHost(releases))
            #expect(presentation?.isObserving == true)
            guard let held = presentation.take() else { return }
            drop(consume held)
        }
        await releases.wait(for: 2)
        #expect(releases.offMain == 0, "\(releases.events)")
        #expect(releases.events == ["slot freed", "shown", "host"], "\(releases.events)")
    }

    // The schedule the destructor must survive: the main-actor job that disposes of the presentation
    // runs, and returns, before the releasing thread destroys the presentation's stored properties.
    // The presentation holds its snapshot only in the storage the job owns, so nothing the main actor
    // must release is left for that thread.
    @Test(arguments: PresentationClass.allCases)
    func aSnapshotPresentationWhoseDisposalRunsFirstReleasesNothingWhereItIsReleased(
        _ kind: PresentationClass
    ) async throws {
        let releases = Releases()
        let feed = Feed(releases)
        // Each presentation holds the only reference to its revision closure.
        func revision() -> @MainActor (Shot) -> UInt64 {
            { [capture = Capture(releases)] shot in withExtendedLifetime(capture) { shot.revision } }
        }
        switch kind {
        case .combine:
            var presentation: SnapshotObservableObject<Shot>? = SnapshotObservableObject(
                Shot(0, "initial", nil),
                revision: revision()
            )
            presentation?.observe(try feed.sequence(first: Shot(1, "shown", releases)))
            feed.offer(Shot(2, "unread", releases))
            guard let held = presentation.take() else { return }
            await dropAfterItsJob(consume held)
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
            var presentation: SnapshotPresentation<Shot>? = SnapshotPresentation(
                Shot(0, "initial", nil),
                revision: revision()
            )
            presentation?.observe(try feed.sequence(first: Shot(1, "shown", releases)))
            feed.offer(Shot(2, "unread", releases))
            guard let held = presentation.take() else { return }
            await dropAfterItsJob(consume held)
        }
        await releases.wait(for: 3)
        #expect(releases.offMain == 0, "\(releases.events)")
        #expect(releases.events.contains("slot freed"), "\(releases.events)")
    }

    // The same schedule for a driving presentation: its owner and its shown snapshot are released on
    // the main actor, after its subscription is cancelled.
    @Test(arguments: PresentationClass.allCases)
    func aDrivingPresentationWhoseDisposalRunsFirstReleasesNothingWhereItIsReleased(
        _ kind: PresentationClass
    ) async {
        let releases = Releases()
        switch kind {
        case .combine:
            var presentation: StateMachineObservableObject<DisposableHost>? =
                StateMachineObservableObject(DisposableHost(releases))
            guard let held = presentation.take() else { return }
            await dropAfterItsJob(consume held)
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
            var presentation: StateMachinePresentation<DisposableHost>? =
                StateMachinePresentation(DisposableHost(releases))
            guard let held = presentation.take() else { return }
            await dropAfterItsJob(consume held)
        }
        await releases.wait(for: 2)
        #expect(releases.offMain == 0, "\(releases.events)")
        #expect(releases.events == ["slot freed", "shown", "host"], "\(releases.events)")
    }

    // A main-actor token of your own released on another thread whose job runs first releases its
    // action, and what that action captures, on the main actor.
    @Test func aMainActorTokenWhoseJobRunsFirstReleasesItsActionOnTheMainActor() async {
        let releases = Releases()
        await dropAfterItsJob(
            MainActorSnapshotSubscription { [capture = Capture(releases)] in
                withExtendedLifetime(capture) { releases.note("cancelled") }
            }
        )
        await releases.wait(for: 1)
        #expect(releases.offMain == 0, "\(releases.events)")
        #expect(releases.events == ["cancelled", "capture"], "\(releases.events)")
    }

    // A main-actor stream dropped elsewhere whose job runs first releases its unread snapshot on the
    // main actor, once the registration is removed.
    @Test func aMainActorStreamWhoseJobRunsFirstReleasesItsUnreadSnapshotOnTheMainActor() async throws {
        let releases = Releases()
        let host = RawHost(
            0,
            scopes: [],
            configuration: try ManagedConfiguration(subscribers: 1),
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let holder = StreamHolder(try host.snapshots { _ in Shot(1, "unread", releases) })
        #expect(host.subscriberCount == 1)
        await dropAfterItsJob(consume holder)
        await releases.wait(for: 1)
        #expect(host.subscriberCount == 0)
        #expect(releases.offMain == 0, "\(releases.events)")
    }

    // A generated owner confined to the main actor counts a presentation's registration through a
    // gate that the presentation's destructor closes at once, on the thread that releases it.
    @Test(arguments: PresentationClass.allCases)
    func aPresentationReleasedElsewhereFreesAnIsolatedMainActorOwnersSlotAtOnce(_ kind: PresentationClass) throws {
        let host = GeneratedNote.IsolatedHost(
            isolation: MainActor.shared,
            saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) },
            configuration: try ManagedConfiguration(subscribers: 1)
        )
        switch kind {
        case .combine:
            var presentation: SnapshotObservableObject<GeneratedNote.Snapshot>? = SnapshotObservableObject(
                host.snapshot()
            )
            try presentation?.observe(host)
            #expect(host.subscriberCount() == 1)
            guard let held = presentation.take() else { return }
            drop(consume held)
        case .observation:
            guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return }
            var presentation: SnapshotPresentation<GeneratedNote.Snapshot>? = SnapshotPresentation(host.snapshot())
            try presentation?.observe(host)
            #expect(host.subscriberCount() == 1)
            guard let held = presentation.take() else { return }
            drop(consume held)
        }
        #expect(host.subscriberCount() == 0)
        let replacement = SnapshotObservableObject(host.snapshot())
        #expect(throws: Never.self) { try replacement.observe(host) }
        #expect(replacement.isObserving)
    }
}

/// An object on the main actor that stores a main-actor stream, as a view model does.
@MainActor private final class StreamHolder {
    var stream: MainActorSnapshotSequence<Shot>?
    init(_ stream: consuming MainActorSnapshotSequence<Shot>) { self.stream = consume stream }
}
