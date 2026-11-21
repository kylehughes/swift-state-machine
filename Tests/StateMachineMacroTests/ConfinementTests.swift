import Combine
import Dispatch
import StateMachine
import Testing
import os

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

/// Suspends until the calling task is cancelled.
private func waitForCancellation() async {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    defer { continuation.finish() }
    for await _ in stream {}
}

/// A reference that the owning actor mutates, so a snapshot that carries it is genuinely not `Sendable`.
private final class Tally {
    var count = 0
}

/// An isolated journal whose payload shares a mutable reference with its owner.
@StateMachine(mode: .isolated)
nonisolated private enum Journal {
    struct Open {
        let tally: Tally
        let lines: Int
    }
    @Initial case open(Open)
    enum Input {
        case write
        case audit
    }
    @Operation(activeIn: [Open.self], admission: .parallel(limit: 4))
    enum Audit {
        typealias Input = Int
        typealias Output = Int
    }
    enum Refusal: Error { case refused }
    @Transition(on: Input.write)
    fileprivate static func write(_ source: Open) -> Open { Open(tally: source.tally, lines: source.lines + 1) }
    @Transition(on: Input.audit, starts: [Audit.self])
    fileprivate static func audit(_ source: Open) -> Change<Open, Effect.Audit> {
        Change(source, effects: [.audit(source.lines)])
    }
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: Open, _ line: Audit.Output) throws(Refusal) -> Open {
        throw .refused
    }
}

/// A shared log whose writes emit an event, and whose held work runs until it is cancelled.
@StateMachine(mode: .shared)
nonisolated private enum Log: Sendable {
    struct Open: Sendable { var lines: [String] = [] }
    @Initial case open(Open = Open())
    enum Input: Sendable {
        case write(String)
        case hold
    }
    @Event
    enum Wrote { typealias Payload = String }
    @Operation(activeIn: [Open.self])
    enum Hold {}
    @Transition(on: Input.write, emits: [Wrote.self])
    fileprivate static func write(_ source: Open, _ line: String) -> Change<Open, Effect.Write> {
        Change(Open(lines: source.lines + [line]), effects: [.wrote(line)])
    }
    @Transition(on: Input.hold, starts: [Hold.self])
    fileprivate static func hold(_ source: Open) -> Change<Open, Effect.Hold> { Change(source, effects: [.hold]) }
    @Transition(onSuccess: Hold.self)
    fileprivate static func held(_ source: Open) -> Open { source }
}

/// Collects values from any thread in order.
private actor Recorder<Value: Sendable> {
    private(set) var values: [Value] = []
    func record(_ value: Value) { values.append(value) }
}

/// The actor that owns a journal and reads it on its own executor.
private actor Desk {
    private var host: Journal.IsolatedHost<Desk>!
    private let tally = Tally()

    init() async {
        host = Journal.IsolatedHost(
            Journal.Open(tally: tally, lines: 0),
            isolation: self,
            auditDriver: { _, line in line },
            completionPolicy: .manual
        )
    }

    // The owner changes the reference its snapshots share, then records the change.
    private func write() throws {
        tally.count += 1
        try host.send(.write)
    }

    /// Reads the confined stream directly on this actor while the payload's reference changes here.
    func readDirectly(writes: Int) async throws -> [Int] {
        var snapshots = try host.snapshots()
        var counts: [Int] = []
        while let snapshot = await snapshots.next() {
            guard case .open(let open) = snapshot else { continue }
            counts.append(open.value.tally.count)
            guard open.value.lines < writes else { break }
            try write()
        }
        return counts
    }

    /// Composes standard operators, consumed off this actor, over a `Sendable` projection that reads
    /// the shared reference here.
    func projectWithOperators(writes: Int) async throws -> [Int] {
        let projected = try host.snapshots { snapshot -> Int in
            guard case .open(let open) = snapshot else { return -1 }
            return open.value.tally.count
        }
        let consumer = Task.detached {
            var seen: [Int] = []
            for await count in projected.map({ $0 * 10 }).filter({ $0 >= 0 }) {
                seen.append(count)
                if count == writes * 10 { break }
            }
            return seen
        }
        // Each suspension lets the consumer interleave; its result does not depend on how it does.
        for _ in 0 ..< writes {
            try write()
            await Task.yield()
        }
        return await consumer.value
    }

    /// Projects the retained completions to a `Sendable` count and composes operators over it.
    func pendingWithOperators(writes: Int) async throws -> [Int] {
        let counts = try host.pendingCompletionUpdates { $0.count }
        for _ in 0 ..< writes { try host.send(.audit) }
        var seen: [Int] = []
        for await count in counts.map({ $0 }) {
            seen.append(count)
            if count == writes { break }
        }
        return seen
    }

    /// Reads one element of a confined stream and releases it, returning the live registrations after.
    func releaseStreamAfterOneElement() async throws -> Int {
        do {
            var snapshots = try host.snapshots()
            _ = await snapshots.next()
        }
        return host.subscriberCount()
    }

    func close() async { await host.shutdown() }
}

@Suite(.timeLimit(.minutes(1))) struct ConfinedStreamTests {
    @Test func aConfinedStreamIsReadOnItsOwnersActor() async throws {
        let desk = await Desk()
        #expect(try await desk.readDirectly(writes: 3).last == 3)
        // Releasing a stream on its actor removes its registration before the next statement.
        #expect(try await desk.releaseStreamAfterOneElement() == 0)
        await desk.close()
    }

    @Test func aSendableProjectionComposesWithOperatorsWhileTheOwnerMutatesItsPayload() async throws {
        let desk = await Desk()
        let seen = try await desk.projectWithOperators(writes: 50)
        #expect(seen.last == 500)
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 })
        await desk.close()
    }

    @Test func aConfinedOwnersPendingCompletionsProjectToASendableSequence() async throws {
        let desk = await Desk()
        #expect(try await desk.pendingWithOperators(writes: 2).last == 2)
        await desk.close()
    }

    @MainActor @Test func aConfinedMainActorOwnerPublishesASendableProjectionToAnotherThread() async throws {
        let host = Journal.MainActorHost(
            Journal.Open(tally: Tally(), lines: 0),
            auditDriver: { $0 },
            completionPolicy: .manual
        )
        let revisions = OSAllocatedUnfairLock(initialState: [UInt64]())
        let finished = Signal()
        let publisher = try host.snapshotPublisher { $0.revision }
        // The serial queue delivers every value before the completion, which raises the signal.
        let cancellable = publisher.receive(on: DispatchQueue(label: "background"))
            .sink(
                receiveCompletion: { @Sendable _ in finished.raise() },
                receiveValue: { @Sendable revision in revisions.withLock { $0.append(revision) } }
            )
        try host.send(.write)
        let closed = host.close()
        await finished.wait()
        cancellable.cancel()
        await host.shutdown()
        #expect(revisions.withLock { $0.last } == closed.revision)
    }

    @MainActor @Test func aConfinedMainActorOwnersPendingCompletionsProjectToASendableSequence() async throws {
        let host = Journal.MainActorHost(
            Journal.Open(tally: Tally(), lines: 0),
            auditDriver: { $0 },
            completionPolicy: .manual
        )
        let counts = try host.pendingCompletionUpdates { $0.count }
        try host.send(.audit)
        // Updates are coalesced, so the empty collection current at registration may never be seen.
        var seen: [Int] = []
        for await count in counts {
            seen.append(count)
            if count == 1 { break }
        }
        #expect(seen.last == 1)
        #expect(host.pendingCompletions().count == 1)
        await host.shutdown()
    }
}

/// An actor that owns a log and releases it within one turn after an accepted change.
private actor LogBook {
    private var lines: [String] = []

    func releaseAfterAcceptedChange() async throws -> ([String], Log.Snapshot?) {
        var host: Log.IsolatedHost<LogBook>? = Log.IsolatedHost(
            isolation: self,
            holdDriver: { _ in await waitForCancellation() },
            onWrote: { book, line in book.lines.append(line) }
        )
        let snapshots = try host!.snapshots()
        try host!.send(.write("tea"))
        host!.close()
        host = nil
        var last: Log.Snapshot?
        for await snapshot in snapshots { last = snapshot }
        return (lines, last)
    }
}

/// Releasing a host does not discard batches it has already accepted.
@Suite(.timeLimit(.minutes(1))) struct AcceptedBatchTests {
    @MainActor @Test func aReleasedMainActorHostProcessesItsAcceptedBatches() async throws {
        var lines: [String] = []
        var host: Log.MainActorHost? = Log.MainActorHost(
            holdDriver: { await waitForCancellation() },
            onWrote: { lines.append($0) }
        )
        let snapshots = try host!.snapshots()
        try host!.send(.write("tea"))
        host!.close()
        host = nil
        var last: Log.Snapshot?
        for await snapshot in snapshots { last = snapshot }
        #expect(lines == ["tea"])
        #expect(last?.isClosed == true)
    }

    @Test func aReleasedActorHostProcessesItsAcceptedBatches() async throws {
        let lines = Recorder<String>()
        let handled = Signal()
        var host: Log.ActorHost? = Log.ActorHost(
            holdDriver: { await waitForCancellation() },
            onWrote: { line in
                Task {
                    await lines.record(line)
                    handled.raise()
                }
            }
        )
        let snapshots = try await host!.snapshots()
        try await host!.send(.write("tea"))
        await host!.close()
        host = nil
        var last: Log.Snapshot?
        for await snapshot in snapshots { last = snapshot }
        await handled.wait()
        #expect(await lines.values == ["tea"])
        #expect(last?.isClosed == true)
    }

    @Test func aReleasedIsolatedHostProcessesItsAcceptedBatches() async throws {
        let (lines, last) = try await LogBook().releaseAfterAcceptedChange()
        #expect(lines == ["tea"])
        #expect(last?.isClosed == true)
    }
}

/// An actor that stores the host confined to it.
private actor Workshop {
    private var host: Log.IsolatedHost<Workshop>?
    private var observed: [UInt64] = []
    let started = Signal()
    let gone: Signal

    init(gone: Signal) { self.gone = gone }
    deinit { gone.raise() }

    func open() {
        host = Log.IsolatedHost(
            isolation: self,
            holdDriver: { workshop in await workshop.hold() },
            onWrote: { _, _ in }
        )
    }
    private func hold() async {
        started.raise()
        await waitForCancellation()
    }
    func startHoldingDriver() throws { _ = try host?.send(.hold) }
    /// Subscribes with a callback that captures this actor, then cancels on this actor.
    func subscribeAndCancel() throws -> Int {
        let token = try host!.subscribe { self.observed.append($0.revision) }
        token.cancel()
        return host!.subscriberCount()
    }
    func close() { _ = host?.close() }
}

/// An actor that stores an `ActorHost` isolated to it.
private actor Studio {
    private var host: Log.ActorHost?
    let gone: Signal

    init(gone: Signal) { self.gone = gone }
    deinit { gone.raise() }

    func open() { host = Log.ActorHost(holdDriver: {}, onWrote: { _ in }, isolatedTo: self) }
    func release() { host = nil }
}

/// What keeps an actor that stores its host alive, and what ends that.
@Suite(.timeLimit(.minutes(1))) struct HostLifetimeTests {
    @Test func anIdleActorThatStoresItsIsolatedHostIsReleased() async throws {
        let gone = Signal()
        var workshop: Workshop? = Workshop(gone: gone)
        await workshop?.open()
        weak let released = workshop
        workshop = nil
        await gone.wait()
        #expect(released == nil)
    }

    @Test func cancellingARegistrationOnTheOwningActorReleasesItsCallbackAtOnce() async throws {
        let gone = Signal()
        var workshop: Workshop? = Workshop(gone: gone)
        await workshop?.open()
        #expect(try await workshop?.subscribeAndCancel() == 0)
        weak let released = workshop
        workshop = nil
        // The cancelled callback captured the actor; the actor is released only because it is gone.
        await gone.wait()
        #expect(released == nil)
    }

    @Test func aRunningDriverRetainsItsActorUntilTheHostCloses() async throws {
        let gone = Signal()
        var workshop: Workshop? = Workshop(gone: gone)
        await workshop?.open()
        let started = try #require(workshop).started
        try await workshop?.startHoldingDriver()
        await started.wait()
        weak let held = workshop
        workshop = nil
        // The driver runs on the actor, so it keeps the actor alive while it runs.
        #expect(held != nil)
        await held?.close()
        await gone.wait()
        #expect(held == nil)
    }

    @Test func anActorHostIsolatedToTheActorThatStoresItRetainsThatActorUntilReleased() async throws {
        let gone = Signal()
        var studio: Studio? = Studio(gone: gone)
        await studio?.open()
        weak let kept = studio
        studio = nil
        // The host's executor is the actor's, so the host retains it for the host's whole lifetime.
        #expect(kept != nil)
        await kept?.release()
        await gone.wait()
        #expect(kept == nil)
    }
}
