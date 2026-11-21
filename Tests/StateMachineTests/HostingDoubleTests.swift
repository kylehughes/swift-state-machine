import StateMachine
import StateMachineUI
import Testing
import os

// A preview or a test can conform a type of its own to each hosting protocol without forwarding to a
// generated owner. Each double here builds every value its protocol requires, including the
// registration tokens and the snapshot sequences, through public initializers.

/// The snapshot every double here offers.
private struct Count: StateMachineSnapshot, Sendable, Equatable {
    let revision: UInt64
}

/// The callbacks of one registration with a double.
private struct Observer: Sendable {
    let receive: @Sendable (Count) -> Void
    let finish: @Sendable () -> Void
}

/// Remembers the last projection a registration offered, so an equal successor is not offered.
private final class Distinct<Value: Equatable & Sendable>: Sendable {
    private let last = OSAllocatedUnfairLock<Value?>(initialState: nil)
    func admit(_ value: Value) -> Bool {
        last.withLock { last in
            guard last != value else { return false }
            last = value
            return true
        }
    }
}

/// A shared owner that a test drives directly.
nonisolated private final class SharedDouble: SharedStateMachineHost {
    private struct State {
        var current = Count(revision: 0)
        var observers: [UInt64: Observer] = [:]
        var next: UInt64 = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var observerCount: Int { state.withLock { $0.observers.count } }

    func snapshot() -> Count { state.withLock { $0.current } }
    func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Count> { try snapshots { $0 } }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Count) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try SnapshotSequence { receive, finish in
            register(Observer(receive: { receive(transform($0)) }, finish: finish))
        }
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Count) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        let distinct = Distinct<Projection>()
        return try SnapshotSequence { receive, finish in
            register(
                Observer(
                    receive: { count in
                        let projection = transform(count)
                        if distinct.admit(projection) { receive(projection) }
                    },
                    finish: finish
                )
            )
        }
    }

    /// Offers `revision` to every registration.
    func publish(_ revision: UInt64) {
        let observers = state.withLock { state in
            state.current = Count(revision: revision)
            return Array(state.observers.values)
        }
        for observer in observers { observer.receive(Count(revision: revision)) }
    }
    /// Finishes and releases every registration.
    func finishAll() {
        let observers = state.withLock { state in
            defer { state.observers = [:] }
            return Array(state.observers.values)
        }
        for observer in observers { observer.finish() }
    }

    private func register(_ observer: Observer) -> SnapshotSubscription {
        let (id, current) = state.withLock { state in
            state.next += 1
            state.observers[state.next] = observer
            return (state.next, state.current)
        }
        observer.receive(current)
        return SnapshotSubscription(onCancel: { [weak self] in
            self?.state.withLock { _ = $0.observers.removeValue(forKey: id) }
        })
    }
}

/// An actor owner that a test drives directly.
private actor ActorDouble: ActorStateMachineHost {
    private var current = Count(revision: 0)
    private var observers: [UInt64: Observer] = [:]
    private var next: UInt64 = 0

    var observerCount: Int { observers.count }

    func snapshot() -> Count { current }
    func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Count> { try snapshots { $0 } }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping @Sendable (Count) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try SnapshotSequence { receive, finish in
            register(Observer(receive: { receive(transform($0)) }, finish: finish))
        }
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping @Sendable (Count) -> Projection
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        let distinct = Distinct<Projection>()
        return try SnapshotSequence { receive, finish in
            register(
                Observer(
                    receive: { count in
                        let projection = transform(count)
                        if distinct.admit(projection) { receive(projection) }
                    },
                    finish: finish
                )
            )
        }
    }

    func publish(_ revision: UInt64) {
        current = Count(revision: revision)
        for observer in observers.values { observer.receive(current) }
    }

    private func register(_ observer: Observer) -> SnapshotSubscription {
        next += 1
        let id = next
        observers[id] = observer
        observer.receive(current)
        // The token may be cancelled on any thread, so the registration is removed on this actor.
        return SnapshotSubscription(onCancel: { [weak self] in Task { await self?.remove(id) } })
    }
    private func remove(_ id: UInt64) { observers[id] = nil }
}

/// An owner confined to `Owner` that a test drives directly on that actor.
nonisolated private final class IsolatedDouble<Owner: Actor>: IsolatedStateMachineHost {
    private struct Registration {
        let receive: (Count) -> Void
        let finish: () -> Void
    }
    private var current = Count(revision: 0)
    private var registrations: [UInt64: Registration] = [:]
    private var next: UInt64 = 0
    // A token of a sequence may be cancelled on any thread; the next turn on the actor removes it.
    private let cancelled = OSAllocatedUnfairLock(initialState: Set<UInt64>())

    func registrationCount(isolation: isolated Owner = #isolation) -> Int {
        sweep()
        return registrations.count
    }

    func snapshot(isolation: isolated Owner) -> Count { current }
    func subscribe(
        _ receive: @escaping (Count) -> Void,
        onFinish: @escaping () -> Void,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> IsolatedSnapshotSubscription<Owner> {
        let id = register(Registration(receive: receive, finish: onFinish))
        let cancelled = cancelled
        return IsolatedSnapshotSubscription(
            isolation: isolation,
            onCancel: { [weak self] in self?.registrations[id] = nil },
            onRelease: { cancelled.withLock { _ = $0.insert(id) } }
        )
    }
    func snapshots<Projection: Sendable>(
        _ transform: @escaping (Count) -> Projection,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        try SnapshotSequence { receive, finish in
            sequenceToken(for: register(Registration(receive: { receive(transform($0)) }, finish: finish)))
        }
    }
    func distinctSnapshots<Projection: Sendable & Equatable>(
        _ transform: @escaping (Count) -> Projection,
        isolation: isolated Owner
    ) throws(SubscriptionFailure) -> SnapshotSequence<Projection> {
        let distinct = Distinct<Projection>()
        return try SnapshotSequence { receive, finish in
            let registration = Registration(
                receive: { count in
                    let projection = transform(count)
                    if distinct.admit(projection) { receive(projection) }
                },
                finish: finish
            )
            return sequenceToken(for: register(registration))
        }
    }

    func publish(_ revision: UInt64, isolation: isolated Owner = #isolation) {
        sweep()
        current = Count(revision: revision)
        for registration in registrations.values { registration.receive(current) }
    }
    func finishAll(isolation: isolated Owner = #isolation) {
        sweep()
        let finishing = registrations.values
        registrations = [:]
        for registration in finishing { registration.finish() }
    }

    private func register(_ registration: Registration) -> UInt64 {
        next += 1
        registrations[next] = registration
        registration.receive(current)
        return next
    }
    private func sequenceToken(for id: UInt64) -> SnapshotSubscription {
        let cancelled = cancelled
        return SnapshotSubscription(onCancel: { cancelled.withLock { _ = $0.insert(id) } })
    }
    private func sweep() {
        let ended = cancelled.withLock { cancelled in
            defer { cancelled = [] }
            return cancelled
        }
        for id in ended { registrations[id] = nil }
    }
}

/// An actor that owns an isolated double and reads it through the hosting protocol.
private actor Bench {
    let host = IsolatedDouble<Bench>()

    func revisionsThroughTheProtocol() async throws -> [UInt64] {
        let revisions = try projectedRevisions(of: host)
        var iterator = revisions.makeAsyncIterator()
        var seen: [UInt64] = []
        if let first = await iterator.next() { seen.append(first) }
        host.publish(1)
        if let second = await iterator.next() { seen.append(second) }
        host.finishAll()
        if await iterator.next() == nil { seen.append(.max) }
        return seen
    }

    func distinctThroughTheProtocol() async throws -> (values: [Int], remaining: Int) {
        let parities = try parities(of: host)
        var iterator = parities.makeAsyncIterator()
        var seen: [Int] = []
        if let first = await iterator.next() { seen.append(first) }
        // Revision 3 has the parity of revision 1, which the sequence already offered.
        host.publish(3)
        host.publish(4)
        if let next = await iterator.next() { seen.append(next) }
        _ = consume iterator
        _ = consume parities
        return (seen, host.registrationCount())
    }

    func subscribeThroughTheProtocol() throws -> (received: [UInt64], afterCancel: Int) {
        var received: [UInt64] = []
        let token = try subscribe(to: host) { received.append($0.revision) }
        host.publish(6)
        token.cancel()
        host.publish(7)
        return (received, host.registrationCount())
    }

    private func projectedRevisions<Host: IsolatedStateMachineHost>(
        of host: Host,
        isolation: isolated Host.Owner = #isolation
    ) throws -> SnapshotSequence<UInt64> {
        try host.snapshots({ $0.revision }, isolation: isolation)
    }
    private func parities<Host: IsolatedStateMachineHost>(
        of host: Host,
        isolation: isolated Host.Owner = #isolation
    ) throws -> SnapshotSequence<Int> {
        try host.distinctSnapshots({ Int($0.revision % 2) }, isolation: isolation)
    }
    private func subscribe<Host: IsolatedStateMachineHost>(
        to host: Host,
        isolation: isolated Host.Owner = #isolation,
        _ receive: @escaping (Host.Snapshot) -> Void
    ) throws -> IsolatedSnapshotSubscription<Host.Owner> {
        try host.subscribe(receive, onFinish: {}, isolation: isolation)
    }
}

private func revisions<Host: SharedStateMachineHost>(of host: Host) throws -> SnapshotSequence<UInt64> {
    try host.snapshots { $0.revision }
}

private func revisions<Host: ActorStateMachineHost>(of host: Host) async throws -> SnapshotSequence<UInt64> {
    try await host.snapshots { $0.revision }
}

@Suite(.timeLimit(.minutes(1))) struct HostingDoubleTests {
    @Test func aSharedDoubleBuildsItsSequencesFromItsOwnRegistrations() async throws {
        let host = SharedDouble()
        let revisions = try revisions(of: host)
        var iterator = revisions.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        host.publish(1)
        #expect(await iterator.next() == 1)
        host.finishAll()
        #expect(await iterator.next() == nil)
    }

    @Test func releasingADoublesSequenceCancelsItsToken() throws {
        let host = SharedDouble()
        do {
            let snapshots = try host.snapshots()
            #expect(host.observerCount == 1)
            _ = consume snapshots
        }
        #expect(host.observerCount == 0)
    }

    @Test func aSequenceEndsWhenADoubleReleasesItsCallbacksWithoutFinishing() async throws {
        let host = SharedDouble()
        var iterator = try host.distinctSnapshots { $0.revision % 2 }.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        host.publish(2)
        host.publish(3)
        #expect(await iterator.next() == 1)
        // Releasing the callbacks without finishing, as an owner released without closing does.
        _ = host.observerCountAfterDroppingAll()
        #expect(await iterator.next() == nil)
    }

    @Test func anActorDoubleBuildsItsSequencesFromItsOwnRegistrations() async throws {
        let host = ActorDouble()
        let revisions = try await revisions(of: host)
        var iterator = revisions.makeAsyncIterator()
        #expect(await iterator.next() == 0)
        await host.publish(1)
        #expect(await iterator.next() == 1)
        let distinct = try await host.distinctSnapshots { $0.revision > 0 }
        var flags = distinct.makeAsyncIterator()
        #expect(await flags.next() == true)
    }

    @Test func anIsolatedDoubleBuildsItsSequencesAndTokensOnItsActor() async throws {
        let bench = Bench()
        #expect(try await bench.revisionsThroughTheProtocol() == [0, 1, .max])
        let distinct = try await bench.distinctThroughTheProtocol()
        #expect(distinct.values == [1, 0])
        #expect(distinct.remaining == 0)
        let subscribed = try await bench.subscribeThroughTheProtocol()
        #expect(subscribed.received == [4, 6])
        #expect(subscribed.afterCancel == 0)
    }

    @MainActor @Test func presentationsObserveStandaloneDoubles() async throws {
        let shared = SharedDouble()
        shared.publish(3)
        let presentation = SnapshotObservableObject(Count(revision: 0), revision: { $0.revision })
        try presentation.observe(shared)
        #expect(presentation.isObserving)
        #expect(presentation.snapshot.revision == 3)
        let actor = ActorDouble()
        await actor.publish(7)
        try await presentation.observe(actor)
        #expect(presentation.isObserving)
        #expect(presentation.snapshot.revision == 7)
        #expect(shared.observerCount == 0)
        presentation.stopObserving()
        #expect(!presentation.isObserving)
    }
}

extension SharedDouble {
    /// Releases every registration's callbacks without finishing it, and returns how many remain.
    fileprivate func observerCountAfterDroppingAll() -> Int {
        let dropped = state.withLock { state in
            defer { state.observers = [:] }
            return state.observers
        }
        withExtendedLifetime(dropped) {}
        return observerCount
    }
}
