import StateMachine
import StateMachineExamples
import Testing

// Generic code reaches each managed host through its hosting protocol, including the projecting
// sequences the generated facades offer.

/// The projections of a shared host's snapshots, through its protocol.
private func closures<Host: SharedStateMachineHost>(of host: Host) throws -> SnapshotSequence<Bool> {
    try host.snapshots { snapshot in snapshot.revision == UInt64.max }
}

private func distinctOnes<Host: SharedStateMachineHost>(of host: Host) throws -> SnapshotSequence<Int> {
    try host.distinctSnapshots { _ in 1 }
}

private func distinctOnes<Host: ActorStateMachineHost>(of host: Host) async throws -> SnapshotSequence<Int> {
    try await host.distinctSnapshots { _ in 1 }
}

private func revisions<Host: ActorStateMachineHost>(of host: Host) async throws -> SnapshotSequence<UInt64> {
    try await host.snapshots { $0.revision }
}

@MainActor private func distinctOnes<Host: MainActorStateMachineHost>(of host: Host) throws -> SnapshotSequence<Int> {
    try host.distinctSnapshots { _ in 1 }
}

@MainActor private func revisions<Host: MainActorStateMachineHost>(of host: Host) throws -> SnapshotSequence<UInt64> {
    try host.snapshots { $0.revision }
}

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

/// Collects a sequence until it ends.
private func collect<Element: Sendable>(_ sequence: SnapshotSequence<Element>) async -> [Element] {
    var values: [Element] = []
    for await value in sequence { values.append(value) }
    return values
}

/// A `MainActor` test double that delivers what the test tells it to, and records its registrations.
@MainActor private final class ScriptedHost: MainActorStateMachineHost {
    struct Snapshot: StateMachineSnapshot {
        let revision: UInt64
        let title: String
    }
    struct Receipt: StateMachineReceipt {
        let snapshot: Snapshot
        var edgeID: String? { nil }
    }
    struct Prepared: ~Copyable {}
    enum SendRejection: Error {}

    private var receive: (@MainActor (Snapshot) -> Void)?
    private var finish: (@MainActor () -> Void)?
    private(set) var registrations = 0
    private(set) var cancellations = 0
    let cancelled = Signal()

    func snapshot() -> Snapshot { Snapshot(revision: 0, title: "") }
    func send(_ input: Never) throws(SendRejection) -> Receipt {}
    func commit(_ prepared: consuming Prepared) {}
    func subscribe(
        _ receive: @escaping @MainActor (Snapshot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        registrations += 1
        self.receive = receive
        finish = onFinish
        receive(snapshot())
        return MainActorSnapshotSubscription(onCancel: { [weak self] in
            self?.receive = nil
            self?.finish = nil
            self?.cancellations += 1
            self?.cancelled.raise()
        })
    }
    func close() -> Receipt { Receipt(snapshot: snapshot()) }

    func deliver(_ snapshot: Snapshot) { receive?(snapshot) }
    func end() { finish?() }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct HostingProjectionTests {
    @Test func aSharedHostProjectsThroughItsProtocol() async throws {
        let host = GeneratedTransfers.Shared(downloadDriver: { _, _ in .success("") }, onLogged: { _ in })
        let flags = try closures(of: host)
        let ones = try distinctOnes(of: host)
        host.close()
        #expect(await collect(flags).last == false)
        #expect(await collect(ones) == [1])
    }

    @Test func anActorHostProjectsThroughItsProtocol() async throws {
        let host = GeneratedTransfers.ActorHost(downloadDriver: { _, _ in .success("") }, onLogged: { _ in })
        let seen = try await revisions(of: host)
        let ones = try await distinctOnes(of: host)
        let closed = await host.close()
        #expect(await collect(seen).last == closed.revision)
        #expect(await collect(ones) == [1])
    }

    @Test func aMainActorHostProjectsThroughItsProtocol() async throws {
        let host = GeneratedTransfers.MainActorHost(downloadDriver: { _, _ in .success("") }, onLogged: { _ in })
        let seen = try revisions(of: host)
        let ones = try distinctOnes(of: host)
        let closed = host.close()
        #expect(await collect(seen).last == closed.revision)
        #expect(await collect(ones) == [1])
    }

    // A test double that implements only `subscribe` projects through it. Each value is read before the
    // next is delivered, because the sequence keeps only the latest one.
    @Test func aMainActorTestDoubleProjectsThroughItsSubscription() async throws {
        let host = ScriptedHost()
        var titles = try host.distinctSnapshots { $0.title }.makeAsyncIterator()
        #expect(host.registrations == 1)
        #expect(await titles.next() == "")
        host.deliver(.init(revision: 1, title: "A"))
        #expect(await titles.next() == "A")
        host.deliver(.init(revision: 2, title: "A"))
        host.end()
        #expect(await titles.next() == nil)
    }

    @Test func aMainActorTestDoubleOffersEveryProjectionThroughItsSubscription() async throws {
        let host = ScriptedHost()
        var seen = try revisions(of: host).makeAsyncIterator()
        #expect(await seen.next() == 0)
        host.deliver(.init(revision: 1, title: "A"))
        #expect(await seen.next() == 1)
        host.end()
        #expect(await seen.next() == nil)
    }

    // Ending a projection cancels the double's subscription on the main actor.
    @Test func endingADoublesProjectionCancelsItsSubscription() async throws {
        let host = ScriptedHost()
        var iterator = try revisions(of: host).makeAsyncIterator()
        #expect(await iterator.next() == 0)
        withUnsafeCurrentTask { $0?.cancel() }
        #expect(await iterator.next() == nil)
        await host.cancelled.wait()
        #expect(host.cancellations == 1)
    }
}
