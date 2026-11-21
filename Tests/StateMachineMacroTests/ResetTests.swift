import StateMachine
import StateMachineExamples
import Testing

/// A graph whose initial phase has a default, so `reset()` needs no argument.
@StateMachine(mode: .shared)
nonisolated private enum Tally: Sendable {
    struct Ready: Sendable { var accepted: [Int] = [] }
    @Initial case ready(Ready = Ready())
    enum Input: Sendable {
        case check(Int)
        case note(Int)
    }
    enum Refusal: Error, Sendable { case negative }
    @Operation(activeIn: [Ready.self], admission: .parallel(limit: 4))
    enum Check {
        typealias Input = Int
        typealias Output = Int
    }
    @Transition(on: Input.check, starts: [Check.self])
    static func check(_ source: Ready, _ value: Int) -> Change<Ready, Effect.Check> {
        Change(source, effects: [.check(value)])
    }
    @Transition(on: Input.note)
    static func note(_ source: Ready, _ value: Int) -> Ready { Ready(accepted: source.accepted + [value]) }
    @Transition(onSuccess: Check.self)
    static func checked(_ source: Ready, _ value: Check.Output) throws(Refusal) -> Ready {
        guard value >= 0 else { throw .negative }
        return Ready(accepted: source.accepted + [value])
    }
}

/// A driver that each call waits in until the test releases it.
private final class HeldDriver: Sendable {
    let started: AsyncStream<Int>
    private let starting: AsyncStream<Int>.Continuation
    private let releases: AsyncStream<Void>
    private let release: AsyncStream<Void>.Continuation
    init() {
        (started, starting) = AsyncStream<Int>.makeStream()
        (releases, release) = AsyncStream<Void>.makeStream()
    }
    func run(_ value: Int) async -> Int {
        starting.yield(value)
        for await _ in releases { break }
        return value
    }
    func releaseOne() { release.yield() }
}

@Suite(.timeLimit(.minutes(1))) struct ResetTests {
    private struct Unexpected: Error {}

    private func accepted(_ snapshot: Tally.Snapshot) -> [Int] {
        guard case .ready(let ready) = snapshot else { return [] }
        return ready.value.accepted
    }

    @Test func aLocalResetRevokesWorkAndPublishesItsCancellation() throws {
        var local = Tally.Local()
        try local.send(.check(1))
        try local.send(.note(5))
        guard case .check(let work)? = local.drainCommands().first?.commands.first else { throw Unexpected() }
        let before = local.snapshot().revision
        let receipt = try local.reset()
        #expect(receipt.revision == before + 1)
        #expect(accepted(local.snapshot()).isEmpty)
        // The reset's batch cancels the revoked work.
        let batch = try #require(local.drainCommands().first)
        #expect(batch.receipt.revision == receipt.revision)
        guard case .cancel(let handle) = batch.commands.first, batch.commands.count == 1 else { throw Unexpected() }
        #expect(handle == work.execution)
        // A result that arrives after the reset is stale, and the work keeps its reservation until acknowledged.
        guard case .stale = local.deliver(work.succeeded(1)) else { throw Unexpected() }
        #expect(local.acknowledgeExecution(work.execution) == .recorded)
        local.close()
        _ = local.drainCommands()
        let quiescent = local.isQuiescent
        #expect(quiescent)
    }

    @Test func aResetDropsRetainedCompletionsAndStartsAFreshIncarnation() async throws {
        let (reports, report) = AsyncStream<Tally.PendingCompletion>.makeStream()
        let owner = Tally.Shared(
            checkDriver: { $0 },
            completionPolicy: .manual(onReconciliationRequired: { report.yield($0) })
        )
        let stale = owner.snapshot()
        try owner.send(.check(-1))
        var reported = reports.makeAsyncIterator()
        let refused = try #require(await reported.next())
        #expect(owner.pendingCompletions().map(\.id) == [refused.id])
        let updates = try owner.pendingCompletionUpdates()
        var collections = updates.makeAsyncIterator()
        let revision = owner.snapshot().revision
        let receipt = try owner.reset(to: Tally.Ready(accepted: [9]))
        #expect(receipt.revision == revision + 1)
        #expect(accepted(owner.snapshot()) == [9])
        #expect(owner.pendingCompletions().isEmpty)
        guard case .notPending = owner.reconcile(id: refused.id) else { throw Unexpected() }
        while let collection = await collections.next(), !collection.isEmpty {}
        // A candidate prepared before the reset belongs to the earlier incarnation.
        guard case .ready(let ready) = stale else { throw Unexpected() }
        guard case .rejected(.obsoleteIncarnation, _) = owner.commit(ready.note(1)) else { throw Unexpected() }
        await owner.shutdown()
        report.finish()
    }

    @Test func runningWorkStaysCountedUntilItTerminatesAndItsResultIsStale() async throws {
        let driver = HeldDriver()
        let owner = Tally.Shared(checkDriver: { await driver.run($0) }, completionPolicy: .retry)
        let snapshots = try owner.snapshots()
        let sent = try owner.send(.check(3))
        var started = driver.started.makeAsyncIterator()
        #expect(await started.next() == 3)
        // Flushing the start's receipt waits until its worker is registered.
        #expect(await owner.flush(through: sent) == .processed)
        try owner.reset()
        #expect(owner.runningCount == 1)
        driver.releaseOne()
        #expect(await owner.shutdown() == .quiescent)
        #expect(owner.runningCount == 0)
        // The late result never committed.
        var last: Tally.Snapshot?
        for await snapshot in snapshots { last = snapshot }
        #expect(last.map(accepted(_:)) == [])
    }

    @Test func anActorHostResetsAsynchronouslyAndAClosedOwnerRejects() async throws {
        let owner = Tally.ActorHost(checkDriver: { $0 }, completionPolicy: .retry)
        try await owner.send(.note(1))
        let receipt = try await owner.reset()
        #expect(receipt.revision == 2)
        #expect(accepted(await owner.snapshot()).isEmpty)
        await owner.close()
        await #expect(throws: CommitRejection.closed) { try await owner.reset() }
    }

    @MainActor @Test func aMainActorHostResetRejectsOnceClosed() throws {
        let owner = Tally.MainActorHost(checkDriver: { $0 }, completionPolicy: .retry)
        try owner.send(.note(2))
        try owner.reset(to: Tally.Ready(accepted: [7]))
        #expect(accepted(owner.snapshot()) == [7])
        owner.close()
        #expect(throws: CommitRejection.closed) { try owner.reset() }
    }

    @Test func anExpectingResetReplacesOnlyTheRootItObserved() throws {
        var local = Tally.Local()
        let reviewed = local.snapshot()
        try local.send(.note(1))
        // A change accepted since the review makes the expecting reset conflict and change nothing.
        #expect(throws: CommitRejection.conflict) { try local.reset(expecting: reviewed) }
        #expect(accepted(local.snapshot()) == [1])
        let current = local.snapshot()
        let receipt = try local.reset(to: Tally.Ready(accepted: [9]), expecting: current)
        #expect(receipt.edgeID == nil)
        #expect(accepted(local.snapshot()) == [9])
        // A reset since the review starts another incarnation.
        #expect(throws: CommitRejection.obsoleteIncarnation) { try local.reset(expecting: current) }
        // Another owner's snapshot is foreign to this one.
        let other = Tally.Local()
        #expect(throws: CommitRejection.foreignOwner) { try local.reset(expecting: other.snapshot()) }
        let last = local.snapshot()
        local.close()
        #expect(throws: CommitRejection.closed) { try local.reset(expecting: last) }
    }

    @Test func managedOwnersResetOnlyTheRootTheyObserved() async throws {
        let shared = Tally.Shared(checkDriver: { $0 }, completionPolicy: .retry)
        let reviewed = shared.snapshot()
        try shared.send(.note(1))
        #expect(throws: CommitRejection.conflict) { try shared.reset(expecting: reviewed) }
        #expect(try shared.reset(expecting: shared.snapshot()).revision == 2)
        #expect(await shared.shutdown() == .quiescent)
        let actor = Tally.ActorHost(checkDriver: { $0 }, completionPolicy: .retry)
        let before = await actor.snapshot()
        try await actor.send(.note(2))
        await #expect(throws: CommitRejection.conflict) { try await actor.reset(expecting: before) }
        #expect(try await actor.reset(expecting: await actor.snapshot()).revision == 2)
        #expect(await actor.shutdown() == .quiescent)
    }

    @MainActor @Test func aMainActorHostResetsOnlyTheRootItObserved() async throws {
        let owner = Tally.MainActorHost(checkDriver: { $0 }, completionPolicy: .retry)
        let reviewed = owner.snapshot()
        try owner.send(.note(2))
        #expect(throws: CommitRejection.conflict) { try owner.reset(expecting: reviewed) }
        try owner.reset(to: Tally.Ready(accepted: [7]), expecting: owner.snapshot())
        #expect(accepted(owner.snapshot()) == [7])
        await owner.shutdown()
    }

    @Test func resetRestoringValidatesSavedDataFirst() throws {
        let user = try UserID("kyle")
        let profile = Profile(userID: user, name: "Saved")
        var local = GeneratedProfile.Local(GeneratedProfile.Idle(userID: user))
        try local.send(.load(try ProfileRequest(userID: user)))
        let receipt = try local.reset(restoring: .loaded(profile))
        #expect(receipt.revision == 2)
        guard case .loaded(let loaded) = local.snapshot() else { throw Unexpected() }
        #expect(loaded.value.profile == profile)
        // Saved data cannot resume work, so the interrupted load is rejected and nothing changes.
        let interrupted = try ProfileRequest(userID: user)
        do {
            try local.reset(restoring: .loading(interrupted))
            Issue.record("An interrupted load was restored")
        } catch {
            guard case .restoration(.interruptedLoading) = error else { throw Unexpected() }
        }
        #expect(local.snapshot().revision == 2)
        local.close()
        do {
            try local.reset(restoring: .idle(user))
            Issue.record("A closed owner was reset")
        } catch {
            guard case .commit(.closed) = error else { throw Unexpected() }
        }
    }
}

/// Resets any owner whose schema declares a default initial payload, as generic code such as a harness does.
private func resetToDefault<Owner: DefaultingLocalStateMachine & ~Copyable>(
    _ owner: inout Owner
) throws(CommitRejection) -> Owner.Receipt {
    try owner.reset()
}

/// Resets any defaulting owner only while it still holds the root `expected` observed.
private func resetToDefault<Owner: DefaultingLocalStateMachine & ~Copyable>(
    _ owner: inout Owner,
    expecting expected: Owner.Snapshot
) throws(CommitRejection) -> Owner.Receipt {
    try owner.reset(expecting: expected)
}

extension ResetTests {
    // Generic code reaches the declared default through the protocol, exactly as the concrete call does.
    @Test func genericCodeResetsADefaultingOwnerToItsDeclaredDefault() throws {
        var local = Tally.Local()
        try local.send(.note(4))
        let receipt = try resetToDefault(&local)
        #expect(receipt.revision == 2)
        #expect(accepted(local.snapshot()).isEmpty)
        let reviewed = local.snapshot()
        try local.send(.note(5))
        #expect(throws: CommitRejection.conflict) { try resetToDefault(&local, expecting: reviewed) }
        #expect(try resetToDefault(&local, expecting: local.snapshot()).revision == 4)
        #expect(accepted(local.snapshot()).isEmpty)
    }
}

/// A reset needs a commit-queue slot exactly when it queues a batch.
@Suite struct ResetCapacityTests {
    @Test func aLocalResetNeedsQueueRoomOnlyWhenItRevokesWork() throws {
        var local = GeneratedTransfers.Local(configuration: try GeneratedTransfers.LocalConfiguration(commits: 1))
        // The event's batch fills the only slot; a reset that revokes nothing queues nothing.
        try local.send(.goOffline)
        let reset = try local.reset()
        #expect(reset.revision == 2)
        #expect(local.drainCommands().count == 1)
        // The download's batch fills the slot again; a reset that revokes it must queue its cancellation.
        let started = try local.send(.download(1))
        #expect(throws: CommitRejection.capacityExceeded(.commitQueue)) { try local.reset() }
        #expect(local.snapshot().revision == started.revision)
        let batches = local.drainCommands()
        #expect(batches.count == 1)
        let cancelled = try local.reset()
        #expect(cancelled.revision == started.revision + 1)
        #expect(local.drainCommands().count == 1)
        for batch in batches {
            for command in batch.commands {
                if case .download(let work) = command {
                    #expect(local.acknowledgeExecution(work.execution, disposition: .skippedBeforeStart) == .recorded)
                }
            }
        }
    }

    @MainActor @Test func aManagedResetAlwaysNeedsQueueRoom() async throws {
        let host = GeneratedTransfers.MainActorHost(
            downloadDriver: { _, _ in .success("") },
            onLogged: { _ in },
            configuration: try GeneratedTransfers.Configuration(commits: 1)
        )
        // A managed owner queues every acceptance to publish it, so a reset needs a slot.
        let offline = try host.send(.goOffline)
        #expect(throws: CommitRejection.capacityExceeded(.commitQueue)) { try host.reset() }
        #expect(host.snapshot().revision == offline.revision)
        #expect(await host.flush(through: offline) == .processed)
        #expect(try host.reset().revision == offline.revision + 1)
        await host.shutdown()
    }
}
