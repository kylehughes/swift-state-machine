import StateMachine
import Testing

// A displaced user value can run a destructor that reads the host that displaced it. Each test
// gives such a value the last reference to a sentinel whose destructor reads the host. A host that
// destroyed it during its own mutation would stop the program with an exclusivity violation; a host
// that releases it once the change is complete lets the destructor read that completed change.

/// Runs its action when it is destroyed.
private final class Sentinel {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    deinit { action() }
}

/// Runs its action when it is destroyed, from whichever context releases it.
private final class SendableSentinel: Sendable {
    private let action: @Sendable () -> Void
    init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    deinit { action() }
}

/// A terminal outcome carrying a value whose destructor reads the host.
private struct Parked {
    let ticket: RuntimeTicket
    let sentinel: Sentinel?
}

/// The sentinel the next driver call returns in its outcome.
private final class OutcomeSource {
    var next: (() -> Sentinel)?
    func take() -> Sentinel? {
        defer { next = nil }
        return next?()
    }
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

private enum Failure: Error { case rejected }

private let scope = RuntimeScopeID(kind: 1)
private let operation = RuntimeOperation(kind: 0, scope: scope)

private typealias MainHost = RuntimeMainActorHost<Sentinel?, Sentinel?, Parked, Never>
private typealias Engine = RuntimeState<Sentinel?, Sentinel?>

@MainActor @Suite(.timeLimit(.minutes(1))) struct MainActorDisplacedValueReleaseTests {
    private let outcomes = OutcomeSource()
    private let parked = Signal()

    // Every outcome is refused, so a delivered outcome stays parked until the owner disposes it.
    private func makeHost() -> MainHost {
        let outcomes = outcomes
        let parked = parked
        return MainHost(
            nil,
            scopes: [scope],
            driver: { work in Parked(ticket: work.ticket, sentinel: outcomes.take()) },
            ticket: { $0.ticket },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) },
            reconciliationRequired: { _ in parked.raise() }
        )
    }

    // Starts one operation whose outcome carries `sentinel`, and waits until the outcome is parked.
    // The worker delivers and returns in one main-actor job, so once the signal arrives the parked
    // outcome holds the last reference to the sentinel.
    private func park(on owner: MainHost, _ sentinel: @escaping () -> Sentinel) async throws {
        outcomes.next = sentinel
        let plan = Engine.Plan(starts: [.init(operation, descriptor: nil)])
        _ = owner.commit(try Engine.prepare(on: owner.snapshot(), next: nil, plan: plan))
        await parked.wait()
    }

    // Installs `root` and waits until its batch is processed, so the host holds its only reference.
    private func install(_ root: () -> Sentinel, on owner: MainHost, committing: Bool) async throws {
        let admission =
            committing
            ? owner.commit(try Engine.prepare(on: owner.snapshot(), next: root()))
            : owner.reset(root(), scopes: [scope])
        guard case .committed(let installed) = admission else { throw Failure.rejected }
        #expect(await owner.flush(through: installed))
    }

    @Test func resetReleasesTheReplacedRootAfterInstallingTheNewOne() async throws {
        var observed: UInt64?
        let owner = makeHost()
        weak let host = owner
        try await install({ Sentinel { observed = host?.snapshot().revision } }, on: owner, committing: false)
        guard case .committed(let replacement) = owner.reset(nil, scopes: [scope]) else { throw Failure.rejected }
        #expect(observed == replacement.revision)
        await owner.shutdown()
    }

    @Test func commitReleasesTheReplacedRootAfterInstallingTheNewOne() async throws {
        var observed: UInt64?
        let owner = makeHost()
        weak let host = owner
        try await install({ Sentinel { observed = host?.snapshot().revision } }, on: owner, committing: true)
        guard case .committed(let replacement) = owner.commit(try Engine.prepare(on: owner.snapshot(), next: nil))
        else { throw Failure.rejected }
        #expect(observed == replacement.revision)
        await owner.shutdown()
    }

    @Test func expectedResetReleasesAParkedOutcomeAfterDisposingIt() async throws {
        var observed: Int?
        let owner = makeHost()
        weak let host = owner
        try await park(on: owner) { Sentinel { observed = host?.pendingCompletions().count } }
        #expect(owner.pendingCompletions().count == 1 && observed == nil)
        guard case .committed = owner.reset(nil, scopes: [scope], expecting: owner.snapshot()) else {
            throw Failure.rejected
        }
        #expect(observed == 0)
        await owner.shutdown()
    }

    @Test func closeReleasesAParkedOutcomeAfterDisposingIt() async throws {
        var observed: Int?
        let owner = makeHost()
        weak let host = owner
        try await park(on: owner) { Sentinel { observed = host?.pendingCompletions().count } }
        #expect(owner.pendingCompletions().count == 1 && observed == nil)
        _ = owner.close()
        #expect(observed == 0)
        await owner.shutdown()
    }

    // Commits one start whose descriptor is `descriptor`, keeping no reference to it.
    private func commitStart(on owner: MainHost, _ descriptor: () -> Sentinel) throws {
        let plan = Engine.Plan(starts: [.init(operation, descriptor: descriptor())])
        _ = owner.commit(try Engine.prepare(on: owner.snapshot(), next: nil, plan: plan))
    }

    @Test func drainReleasesASkippedStartAfterProcessingItsBatch() async throws {
        var observed: UInt64?
        let owner = makeHost()
        weak let host = owner
        try commitStart(on: owner) { Sentinel { observed = host?.snapshot().revision } }
        // The reset revokes the start before the drain considers it, so the drain skips it.
        guard case .committed(let reset) = owner.reset(nil, scopes: [scope]) else { throw Failure.rejected }
        #expect(await owner.flush(through: reset))
        #expect(observed == reset.revision)
        await owner.shutdown()
    }

    @Test func cancellingASnapshotRegistrationReleasesItsCallbacksAfterRemovingIt() throws {
        var observed: Int?
        let owner = makeHost()
        weak let host = owner
        var sentinel: Sentinel? = Sentinel { observed = host?.subscriberCount }
        let token = try owner.subscribe { [sentinel] _ in withExtendedLifetime(sentinel) {} }
        sentinel = nil
        #expect(owner.subscriberCount == 1 && observed == nil)
        token.cancel()
        #expect(observed == 0)
        _ = owner.close()
    }

    @Test func cancellingAPendingRegistrationReleasesItsCallbacksAfterRemovingIt() throws {
        var observed: Int?
        let owner = makeHost()
        weak let host = owner
        var sentinel: Sentinel? = Sentinel { observed = host?.subscriberCount }
        let token = try owner.subscribePending { [sentinel] _ in withExtendedLifetime(sentinel) {} }
        sentinel = nil
        #expect(owner.subscriberCount == 1 && observed == nil)
        token.cancel()
        #expect(observed == 0)
        _ = owner.close()
    }
}

/// The actor that owns an isolated host whose refused outcomes stay parked.
private actor IsolatedBench {
    typealias Host = RuntimeIsolatedHost<IsolatedBench, Sentinel?, Sentinel?, Parked, Never>
    private var host: Host!
    private var outcome: (() -> Sentinel)?
    private let parked = Signal()
    private(set) var observed: UInt64?

    init() async {
        let parked = parked
        host = Host(
            nil,
            scopes: [scope],
            isolation: self,
            driver: { bench, work in Parked(ticket: work.ticket, sentinel: bench.takeOutcome()) },
            ticket: { $0.ticket },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) },
            reconciliationRequired: { _ in parked.raise() }
        )
    }

    private func takeOutcome() -> Sentinel? {
        defer { outcome = nil }
        return outcome?()
    }

    /// Installs a root whose destructor records the revision it reads, then replaces it.
    func replaceRoot() async throws -> UInt64 {
        try await install { Sentinel { self.observed = self.host.snapshot(isolation: self).revision } }
        guard case .committed(let replacement) = host.reset(nil, scopes: [scope], isolation: self) else {
            throw Failure.rejected
        }
        return replacement.revision
    }

    // Installs `root` and waits until its batch is processed, so the host holds its only reference.
    private func install(_ root: () -> Sentinel) async throws {
        guard case .committed(let installed) = host.reset(root(), scopes: [scope], isolation: self) else {
            throw Failure.rejected
        }
        _ = await host.flush(through: installed, isolation: self)
    }

    /// Parks an outcome whose destructor records the retained count it reads, then closes.
    func closeWithParkedOutcome() async throws -> (before: Int, observed: UInt64?) {
        outcome = { Sentinel { self.observed = UInt64(self.host.pendingCompletions(isolation: self).count) } }
        let plan = Engine.Plan(starts: [.init(operation, descriptor: nil)])
        _ = host.commit(try Engine.prepare(on: host.snapshot(isolation: self), next: nil, plan: plan), isolation: self)
        await parked.wait()
        let before = host.pendingCompletions(isolation: self).count
        _ = host.close(isolation: self)
        return (before, observed)
    }

    /// Registers a pending-completion observer whose callback holds a sentinel, then cancels it.
    func cancelPendingRegistration() throws -> (before: Int, observed: UInt64?) {
        var sentinel: Sentinel? = Sentinel { self.observed = UInt64(self.host.subscriberCount(isolation: self)) }
        let token = try host.subscribePending({ [sentinel] _ in withExtendedLifetime(sentinel) {} }, isolation: self)
        sentinel = nil
        let before = host.subscriberCount(isolation: self)
        token.cancel()
        return (before, observed)
    }

    func shutdown() async { await host.shutdown(isolation: self) }
}

@Suite(.timeLimit(.minutes(1))) struct IsolatedDisplacedValueReleaseTests {
    @Test func resetReleasesTheReplacedRootAfterInstallingTheNewOne() async throws {
        let bench = await IsolatedBench()
        let replacement = try await bench.replaceRoot()
        #expect(await bench.observed == replacement)
        await bench.shutdown()
    }

    @Test func closeReleasesAParkedOutcomeAfterDisposingIt() async throws {
        let bench = await IsolatedBench()
        let (before, observed) = try await bench.closeWithParkedOutcome()
        #expect(before == 1 && observed == 0)
        await bench.shutdown()
    }

    @Test func cancellingAPendingRegistrationReleasesItsCallbacksAfterRemovingIt() async throws {
        let bench = await IsolatedBench()
        let (before, observed) = try await bench.cancelPendingRegistration()
        #expect(before == 1 && observed == 0)
        await bench.shutdown()
    }
}

private typealias ActorHost = RuntimeActorHost<SendableSentinel?, Int, RuntimeTicket, Never>

@Suite(.timeLimit(.minutes(1))) struct ActorDisplacedValueReleaseTests {
    private func install(on owner: ActorHost, _ root: @Sendable () -> SendableSentinel) async throws {
        guard case .committed(let installed) = await owner.reset(root(), scopes: []) else { throw Failure.rejected }
        #expect(await owner.flush(through: installed))
    }

    // A destructor that runs on the host's executor can read it synchronously through `assumeIsolated`.
    @Test func resetReleasesTheReplacedRootAfterInstallingTheNewOne() async throws {
        let owner = ActorHost(
            nil,
            scopes: [],
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let observed = AtomicRecordStorage<UInt64?>(nil)
        try await install(on: owner) {
            SendableSentinel { [weak owner] in
                guard let owner else { return }
                let revision = owner.assumeIsolated { $0.snapshot().revision }
                _ = observed.install(.init(revision), replacing: observed.load())
            }
        }
        guard case .committed(let replacement) = await owner.reset(nil, scopes: []) else { throw Failure.rejected }
        #expect(observed.load().value == replacement.revision)
        await owner.shutdown()
    }
}
