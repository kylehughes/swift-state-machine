import StateMachine
import StateMachineExamples
import StateMachineUI
import Testing

// A presentation that observes a projection registers it through a closure, which runs only once the
// current observation has released its registration, so observing the same owner again needs no
// spare slot. A plain argument is evaluated first, while the old registration still holds the slot.

private typealias Snapshot = GeneratedTransfers.Snapshot

private func sharedTransfers(subscribers: Int = 1) throws -> GeneratedTransfers.Shared {
    GeneratedTransfers.Shared(
        downloadDriver: { _, _ in .success("") },
        onLogged: { _ in },
        configuration: try GeneratedTransfers.Configuration(subscribers: subscribers)
    )
}

private func actorTransfers(subscribers: Int = 1) throws -> GeneratedTransfers.ActorHost {
    GeneratedTransfers.ActorHost(
        downloadDriver: { _, _ in .success("") },
        onLogged: { _ in },
        configuration: try GeneratedTransfers.Configuration(subscribers: subscribers)
    )
}

/// Both presentation classes' registering overloads, for a generated transfer snapshot.
@MainActor private protocol Registering: AnyObject {
    var isObserving: Bool { get }
    func observe(_ snapshots: SnapshotSequence<Snapshot>)
    func observe<Failure: Error>(
        snapshotsFrom register: () throws(Failure) -> SnapshotSequence<Snapshot>
    ) throws(Failure)
    func observe<Failure: Error>(
        snapshotsFrom register: @MainActor () async throws(Failure) -> SnapshotSequence<Snapshot>
    ) async throws(Failure)
    func follow<Failure: Error>(
        snapshotsFrom register: @MainActor () async throws(Failure) -> SnapshotSequence<Snapshot>
    ) async throws(Failure)
    func stopObserving()
    func untilLive() async
}

extension SnapshotObservableObject: Registering where Snapshot == GeneratedTransfers.Snapshot {
    fileprivate func untilLive() async { await untilObserving(self) }
}

@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
extension SnapshotPresentation: Registering where Snapshot == GeneratedTransfers.Snapshot {
    fileprivate func untilLive() async { await untilObserving(self) }
}

@MainActor private func registering(_ kind: PresentationClass, _ initial: Snapshot) -> (any Registering)? {
    switch kind {
    case .combine: return SnapshotObservableObject(initial)
    case .observation:
        guard #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else { return nil }
        return SnapshotPresentation(initial)
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationRegistrationFactoryTests {
    // A one-slot shared owner. Observing its projection again through a closure ends the current
    // observation first, so the second registration takes the slot the first released. A shared owner
    // hands its first element over on its own task, so the test waits for each observation to go live.
    @Test(arguments: PresentationClass.allCases)
    func observingAProjectionAgainReleasesTheOldSlotFirst(_ kind: PresentationClass) async throws {
        let host = try sharedTransfers()
        guard let presentation = registering(kind, host.snapshot()) else { return }
        try presentation.observe(snapshotsFrom: { try host.snapshots { $0 } })
        await presentation.untilLive()
        // An argument registers before the call can release anything.
        #expect(throws: SubscriptionFailure.capacityExceeded) { presentation.observe(try host.snapshots { $0 }) }
        try presentation.observe(snapshotsFrom: { try host.snapshots { $0 } })
        #expect(host.subscriberCount == 1)
        await presentation.untilLive()
        presentation.stopObserving()
        #expect(host.subscriberCount == 0)
    }

    // A refusal by an owner that another registration holds is thrown, and the presentation is not
    // observing.
    @Test(arguments: PresentationClass.allCases)
    func aRefusedRegistrationThrows(_ kind: PresentationClass) throws {
        let host = try sharedTransfers()
        guard let presentation = registering(kind, host.snapshot()) else { return }
        let other = try host.snapshots()
        #expect(throws: SubscriptionFailure.capacityExceeded) {
            try presentation.observe(snapshotsFrom: { try host.snapshots { $0 } })
        }
        #expect(!presentation.isObserving)
        other.cancel()
    }

    // The closure stops the presentation before it registers. The registration it returns is released at
    // once, and nothing is reported.
    @Test(arguments: PresentationClass.allCases)
    func aRegistrationThatItsOwnClosureReplacedIsReleased(_ kind: PresentationClass) throws {
        let host = try sharedTransfers()
        guard let presentation = registering(kind, host.snapshot()) else { return }
        try presentation.observe(snapshotsFrom: {
            presentation.stopObserving()
            return try host.snapshots { $0 }
        })
        #expect(host.subscriberCount == 0)
        #expect(!presentation.isObserving)
    }

    // Observing a one-slot actor owner's projection again through an asynchronous closure ends the
    // current observation before the closure registers, so the registration takes the slot the first
    // released. The observation belongs to the presentation, so the call returns once it is shown.
    @Test(arguments: PresentationClass.allCases)
    func observingAnActorOwnersProjectionAgainReleasesTheOldSlotFirst(_ kind: PresentationClass) async throws {
        let host = try actorTransfers()
        guard let presentation = registering(kind, await host.snapshot()) else { return }
        try await presentation.observe(snapshotsFrom: { try await host.snapshots { $0 } })
        await presentation.untilLive()
        #expect(await host.subscriberCount == 1)
        try await presentation.observe(snapshotsFrom: { try await host.snapshots { $0 } })
        await presentation.untilLive()
        #expect(await host.subscriberCount == 1)
        presentation.stopObserving()
        #expect(!presentation.isObserving)
        #expect(await host.subscriberCount == 0)
    }

    // An asynchronous registration that the owner refuses throws, and the presentation is not observing.
    @Test(arguments: PresentationClass.allCases)
    func aRefusedAsynchronousRegistrationThrows(_ kind: PresentationClass) async throws {
        let host = try actorTransfers()
        guard let presentation = registering(kind, await host.snapshot()) else { return }
        let other = try await host.snapshots()
        await #expect(throws: SubscriptionFailure.capacityExceeded) {
            try await presentation.observe(snapshotsFrom: { try await host.snapshots { $0 } })
        }
        #expect(!presentation.isObserving)
        other.cancel()
    }

    // A stop while the asynchronous closure awaits its owner replaces the observation: the sequence the
    // closure returns is released at once, nothing is shown or reported, and a refusal is not thrown.
    @Test(arguments: PresentationClass.allCases)
    func aStopWhileAnAsynchronousRegistrationAwaitsReleasesWhatItReturns(_ kind: PresentationClass) async throws {
        let host = try actorTransfers()
        guard let presentation = registering(kind, await host.snapshot()) else { return }
        try await presentation.observe(snapshotsFrom: {
            let snapshots = try await host.snapshots { $0 }
            presentation.stopObserving()
            return snapshots
        })
        #expect(!presentation.isObserving)
        #expect(await host.subscriberCount == 0)
        let held = try await host.snapshots()
        await #expect(throws: Never.self) {
            try await presentation.observe(snapshotsFrom: {
                presentation.stopObserving()
                return try await host.snapshots { $0 }
            })
        }
        #expect(!presentation.isObserving)
        held.cancel()
    }

    // Each registering overload runs as written on a concrete class: a synchronous closure without
    // `await` registers synchronously even in an asynchronous context.
    @Test func aSynchronousClosureSelectsTheSynchronousOverload() async throws {
        let host = try sharedTransfers()
        let presentation = SnapshotObservableObject(host.snapshot())
        try presentation.observe(snapshotsFrom: { try host.snapshots { $0 } })
        #expect(host.subscriberCount == 1)
        presentation.stopObserving()
        #expect(host.subscriberCount == 0)
    }

    // Following a one-slot actor owner's projection again through a closure ends the first follow's
    // observation before the closure registers, so the second registers and the first returns.
    @Test(arguments: PresentationClass.allCases)
    func followingAProjectionAgainReleasesTheOldSlotFirst(_ kind: PresentationClass) async throws {
        let host = try actorTransfers()
        guard let presentation = registering(kind, await host.snapshot()) else { return }
        let first = Task { @MainActor in
            try await presentation.follow(snapshotsFrom: { try await host.snapshots { $0 } })
        }
        await presentation.untilLive()
        let second = Task { @MainActor in
            try await presentation.follow(snapshotsFrom: { try await host.snapshots { $0 } })
        }
        try await first.value
        await presentation.untilLive()
        #expect(await host.subscriberCount == 1)
        second.cancel()
        try await second.value
        #expect(!presentation.isObserving)
        #expect(await host.subscriberCount == 0)
    }

    // A task that is already cancelled ends the current observation and registers nothing.
    @Test(arguments: PresentationClass.allCases)
    func aCancelledTaskFollowsNothing(_ kind: PresentationClass) async throws {
        let host = try sharedTransfers()
        guard let presentation = registering(kind, host.snapshot()) else { return }
        try presentation.observe(snapshotsFrom: { try host.snapshots { $0 } })
        await presentation.untilLive()
        var registered = false
        let follower = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await presentation.follow(snapshotsFrom: {
                registered = true
                return try host.snapshots { $0 }
            })
        }
        try await follower.value
        #expect(!registered)
        #expect(!presentation.isObserving)
        #expect(host.subscriberCount == 0)
    }
}
