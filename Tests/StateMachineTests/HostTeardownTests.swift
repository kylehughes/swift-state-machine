import Combine
import Foundation
import StateMachine
import StateMachineExamples
import StateMachineTestSupport
import Testing
import os

// An owner released without closing promises nothing more, and every registration that learns of the
// release learns of it before the owner cancels any worker: a driver's cancellation handler runs
// synchronously inside that cancellation and can attach to, or read, such a registration.

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

/// A subscriber that requests every value and records what it receives.
private final class Recorder: Subscriber {
    typealias Input = UInt64
    typealias Failure = Never
    private(set) var events: [String] = []
    func receive(subscription: any Subscription) { subscription.request(.unlimited) }
    func receive(_ input: UInt64) -> Subscribers.Demand {
        events.append("value \(input)")
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) { events.append("finished") }
}

/// Whether a cancellation handler ran off the main thread, where it cannot attach.
private let attachedOffMain = OSAllocatedUnfairLock(initialState: false)

/// Attaches a subscriber to a publisher when asked, as a driver's cancellation handler does here.
@MainActor private final class LateAttachment {
    var publisher: SnapshotPublisher<UInt64>?
    let subscriber = Recorder()
    private(set) var attachedOnMain: Bool?
    nonisolated func attach() {
        guard Thread.isMainThread else {
            attachedOffMain.withLock { $0 = true }
            return
        }
        MainActor.assumeIsolated {
            attachedOnMain = true
            publisher?.subscribe(subscriber)
        }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct HostTeardownTests {
    // The last reference to an actor host is released on the main actor while a driver waits. The
    // host's destructor cancels that driver, whose cancellation handler attaches a subscriber to a
    // publisher of the host. The publisher already knows that its owner promises nothing more, so the
    // subscriber receives only the completion.
    @Test func aPublisherAttachedFromADriversCancellationDuringAnActorHostsReleaseOnlyFinishes() async throws {
        let user = try UserID("kyle")
        let late = LateAttachment()
        let started = Signal()
        var host: GeneratedProfile.ActorHost? = GeneratedProfile.ActorHost(
            .init(userID: user),
            drivers: .init(
                fetch: { _ in
                    await withTaskCancellationHandler {
                        started.raise()
                        // Held until the host's release cancels it.
                        try? await Task.sleep(for: .seconds(3600))
                    } onCancel: {
                        late.attach()
                    }
                    return .failure(.unavailable)
                },
                audit: { _ in .failure(.unavailable) }
            )
        )
        late.publisher = try await #require(host).snapshotPublisher { $0.revision }
        _ = try await #require(host).send(.load(ProfileRequest(userID: user)))
        await started.wait()
        weak let released = host
        host = nil
        #expect(released == nil)
        #expect(!attachedOffMain.withLock { $0 })
        #expect(late.attachedOnMain == true)
        #expect(late.subscriber.events == ["finished"])
    }

    // An actor host's first registration callback captures an object whose destructor attaches a
    // subscriber to a publisher registered second. Releasing the host releases that callback, and the
    // publisher already knows that its owner promises nothing more, so the subscriber receives only
    // the completion, not the ordinary snapshot the publisher holds.
    @Test func aCaptureDestructorAttachingToAnotherPublisherDuringAnActorHostsReleaseOnlyFinishes() async throws {
        let late = LateAttachment()
        var host: RuntimeActorHost<Int, Int, RuntimeTicket, Never>? = RuntimeActorHost(
            0,
            scopes: [],
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let token = try await #require(host)
            .subscribe { [hold = AttachOnRelease(late)] _ in
                withExtendedLifetime(hold) {}
            }
        late.publisher = try await #require(host).snapshotPublisher { $0.revision }
        weak let released = host
        host = nil
        #expect(released == nil)
        #expect(late.attachedOnMain == true)
        #expect(late.subscriber.events == ["finished"])
        withExtendedLifetime(token) {}
    }

    // An isolated host confined to the main actor, released there while a driver waits, ends its
    // registrations before it cancels the driver: the driver's cancellation handler finds the host's
    // snapshot sequence ended.
    @Test func anIsolatedHostEndsItsRegistrationsBeforeItCancelsItsDrivers() async throws {
        let user = try UserID("kyle")
        let started = Signal()
        let openAtCancellation = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let consumer = OSAllocatedUnfairLock<SnapshotSequence<UInt64>.Consumer?>(initialState: nil)
        var host: GeneratedProfile.IsolatedHost<MainActor>? = GeneratedProfile.IsolatedHost(
            .init(userID: user),
            isolation: MainActor.shared,
            fetchDriver: { _, _ in
                await withTaskCancellationHandler {
                    started.raise()
                    try? await Task.sleep(for: .seconds(3600))
                } onCancel: {
                    let open = consumer.withLock { $0?.isOpen }
                    openAtCancellation.withLock { $0 = open }
                }
                return .failure(.unavailable)
            },
            auditDriver: { _, _ in .failure(.unavailable) }
        )
        let sequence: SnapshotSequence<UInt64> = try #require(host)
            .snapshots({ $0.revision }, isolation: MainActor.shared)
        consumer.withLock { $0 = sequence.claim() }
        _ = try #require(host).send(.load(ProfileRequest(userID: user)))
        await started.wait()
        weak let released = host
        host = nil
        #expect(released == nil)
        #expect(openAtCancellation.withLock { $0 } == false)
    }

    // The same for a shared owner: its registrations go with its state, before the coordinator
    // that runs its workers cancels them, so a publisher attached from a driver's cancellation handler
    // only finishes.
    @Test func aPublisherAttachedFromADriversCancellationDuringASharedHostsReleaseOnlyFinishes() async throws {
        let user = try UserID("kyle")
        let late = LateAttachment()
        let started = Signal()
        let cancelled = Signal()
        var host: GeneratedProfile.Shared? = GeneratedProfile.Shared(
            .init(userID: user),
            fetchDriver: { _ in
                await withTaskCancellationHandler {
                    started.raise()
                    try? await Task.sleep(for: .seconds(3600))
                } onCancel: {
                    late.attach()
                    cancelled.raise()
                }
                return .failure(.unavailable)
            },
            auditDriver: { _ in .failure(.unavailable) }
        )
        late.publisher = try #require(host).snapshotPublisher { $0.revision }
        _ = try #require(host).send(.load(ProfileRequest(userID: user)))
        await started.wait()
        weak let released = host
        host = nil
        #expect(released == nil)
        await cancelled.wait()
        #expect(!attachedOffMain.withLock { $0 })
        #expect(late.attachedOnMain == true)
        #expect(late.subscriber.events == ["finished"])
    }
}

/// Attaches the late subscriber from its destructor, which runs when the callback that holds it is
/// released.
private final class AttachOnRelease: Sendable {
    let late: LateAttachment
    init(_ late: LateAttachment) { self.late = late }
    deinit { late.attach() }
}

private typealias RawShared = RuntimeSharedHost<Int, Int, RuntimeTicket, Never>

/// The only reference to an owner, which a destructor on a worker drops; the worker then waits until
/// the main actor lets it return, so whatever its frame holds stays held meanwhile.
private final class OwnerSlot<Owner: Sendable>: Sendable {
    private let owner: OSAllocatedUnfairLock<Owner?>
    let dropped = DispatchSemaphore(value: 0)
    let proceed = DispatchSemaphore(value: 0)
    let returned = DispatchSemaphore(value: 0)

    init(_ owner: Owner) { self.owner = OSAllocatedUnfairLock(initialState: owner) }

    /// Runs `body` with the owner, keeping no reference to it afterward.
    func with<Result>(_ body: (Owner) throws -> Result) rethrows -> Result {
        let current = owner.withLock { $0 }
        return try body(current!)
    }
    /// Blocks until a destructor on the worker has dropped the owner, or the waiting task is cancelled.
    func waitForDrop() { dropped.waitUnlessCancelled() }
    /// Lets the worker return, and blocks until it has or the waiting task is cancelled.
    func letWorkerReturn() {
        proceed.signal()
        returned.waitUnlessCancelled()
    }
    fileprivate func drop() {
        _ = owner.withLock { $0.take() }
        dropped.signal()
        proceed.wait()
    }
}

/// Drops the owner from its destructor, which runs when the registration callback that holds it is
/// released.
private final class DropOnRelease<Owner: Sendable>: Sendable {
    let slot: OwnerSlot<Owner>
    init(_ slot: OwnerSlot<Owner>) { self.slot = slot }
    deinit { slot.drop() }
}

@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) struct SharedOwnerLifetimeTests {
    // A saved publisher of a shared owner holds an ordinary snapshot. Another registration's
    // cancellation, on a worker, reads the owner's state, and releasing that registration's callback
    // there drops the owner's last reference while the cancellation still holds the state. A subscriber
    // that attaches then receives only the completion: the owner's release does not wait for the state.
    @Test func aRawSharedOwnersSavedPublisherOnlyFinishesWhileACancellationHoldsItsState() async throws {
        let slot = OwnerSlot(
            RawShared(
                manual: 0,
                scopes: [],
                limits: try Limits(),
                ticket: { $0 },
                prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
            )
        )
        let saved = try slot.with { try $0.snapshotPublisher { $0.revision } }
        let delivered = Signal()
        let token = try slot.with { owner in
            try owner.subscribe { [hold = DropOnRelease(slot)] _ in
                withExtendedLifetime(hold) {}
                delivered.raise()
            }
        }
        try await subscribeAfterOwnerDrop(slot, saved, cancelling: token, delivered: delivered)
    }

    @Test func aGeneratedSharedOwnersSavedPublisherOnlyFinishesWhileACancellationHoldsItsState() async throws {
        let slot = OwnerSlot(GeneratedTransfers.Shared(downloadDriver: { _, _ in .success("") }, onLogged: { _ in }))
        let saved = try slot.with { try $0.snapshotPublisher { $0.revision } }
        let delivered = Signal()
        let token = try slot.with { owner in
            try owner.subscribe { [hold = DropOnRelease(slot)] _ in
                withExtendedLifetime(hold) {}
                delivered.raise()
            }
        }
        try await subscribeAfterOwnerDrop(slot, saved, cancelling: token, delivered: delivered)
    }

    private func subscribeAfterOwnerDrop<Owner: Sendable>(
        _ slot: OwnerSlot<Owner>,
        _ saved: SnapshotPublisher<UInt64>,
        cancelling token: SnapshotSubscription,
        delivered: Signal
    ) async throws {
        await delivered.wait()
        runOnOwnThread {
            token.cancel()
            slot.returned.signal()
        }
        slot.waitForDrop()
        let late = Recorder()
        saved.subscribe(late)
        await Task { @MainActor in }.value
        let events = late.events
        slot.letWorkerReturn()
        #expect(events == ["finished"])
    }
}
