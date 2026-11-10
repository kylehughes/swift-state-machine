import Dispatch
import StateMachine
import StateMachineSchema
import Testing
import os

@StateMachine(mode: .shared)
nonisolated private enum DeliveryFlow: Sendable {
    struct Idle: Sendable { let presentation: Int }
    struct Loading: Sendable {
        let request: Int
        let presentation: Int
    }
    struct Loaded: Sendable {
        let result: Int
        let presentation: Int
    }
    @Initial case idle(Idle)
    case loading(Loading)
    case loaded(Loaded)
    enum Scope { case load }
    enum Input: Sendable {
        case begin(Int)
        case edit(Int)
        case audit(Int)
    }
    enum Effect: Sendable {
        case fetch(Fetch.Input)
        case audit(Audit.Input)
    }
    @Operation(scope: Scope.load, activeIn: [Loading.self], admission: .latest)
    enum Fetch {
        typealias Input = Int
        typealias Output = Int
        typealias Failure = Never
    }
    @Operation(scope: Scope.load, activeIn: [Loading.self], admission: .latest)
    enum Audit {
        typealias Input = Int
        typealias Output = Int
        typealias Failure = Never
    }
    @Transition(on: Input.audit, starts: [Audit.self])
    fileprivate static func audit(_ source: borrowing Loading, _ value: Int) -> Change<Loading, Effect> {
        Change(copy source, effects: [.audit(value)])
    }
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: borrowing Loading, _ value: Audit.Output) -> Change<Loading, Effect> {
        Change(copy source)
    }
    @Transition(on: Input.begin, starts: [Fetch.self])
    fileprivate static func begin(_ source: borrowing Idle, _ request: Int) -> Change<Loading, Effect> {
        Change(Loading(request: request, presentation: source.presentation), effects: [.fetch(request)])
    }
    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: borrowing Loading, _ presentation: Int) -> Change<Loading, Effect> {
        Change(Loading(request: source.request, presentation: presentation))
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: borrowing Loading, _ value: Fetch.Output) -> Change<Loaded, Effect> {
        Change(Loaded(result: value, presentation: source.presentation))
    }
    @Route(onSuccess: Fetch.self)
    fileprivate static func route(
        _ source: Observed<Loading>,
        _ completion: FetchSuccessCompletion
    ) -> PreparationResult {
        guard gate.enter(completion) else { return .rejected(.invalidPhase) }
        do {
            switch gate.choice {
            case .valid: return .prepared(try source.received(completion))
            case .input: return .prepared(try source.edit(source.value.presentation + 1))
            case .anotherOperation:
                guard let alternate = gate.alternate else { return .rejected(.invalidPhase) }
                return .prepared(try source.audited(alternate))
            }
        } catch {
            switch error {
            case .plan(let reason): return .rejected(.plan(reason))
            case .domain(let never): switch never {}
            }
        }
    }
    enum Choice: Sendable { case valid, input, anotherOperation }
    static let gate = Gate()
    final class Gate: Sendable {
        struct State: Sendable {
            var blocks = 0
            var choice: Choice = .valid
            var alternate: AuditSuccessCompletion?
            var preparations = 0
            var executions = 0
            var completion: FetchSuccessCompletion?
            var events: AsyncStream<Int>.Continuation?
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        private let permits = DispatchSemaphore(value: 0)
        func configure(blocks: Int) -> AsyncStream<Int> {
            let (stream, events) = AsyncStream<Int>.makeStream()
            state.withLock { $0 = State(blocks: blocks, events: events) }
            return stream
        }
        func enter(_ completion: FetchSuccessCompletion) -> Bool {
            let (count, blocks, events) = state.withLock { value in
                value.preparations += 1
                if value.completion == nil { value.completion = completion }
                return (value.preparations, value.blocks, value.events)
            }
            guard count <= blocks else { return true }
            events?.yield(count)
            guard permits.wait(timeout: .now() + 30) == .success else {
                Issue.record("Preparation gate timed out")
                return false
            }
            return true
        }
        var choice: Choice { state.withLock { $0.choice } }
        var alternate: AuditSuccessCompletion? { state.withLock { $0.alternate } }
        func select(_ choice: Choice, alternate: AuditSuccessCompletion? = nil) {
            state.withLock {
                $0.choice = choice
                $0.alternate = alternate
            }
        }
        func release() { permits.signal() }
        func execute(_ value: Int) -> Result<Int, Never> {
            state.withLock { $0.executions += 1 }
            return .success(value)
        }
        var captured: Completion? { state.withLock { $0.completion.map { .fetch(.success($0)) } } }
        var counts: (Int, Int) { state.withLock { ($0.preparations, $0.executions) } }
    }
}

@Suite(.serialized, .parksCooperativeThread) struct GeneratedDeliveryTests {
    private enum Failure: Error { case unexpected }
    @Test func generatedManualConflictRetainsFirstOutcomeAndReconcilesOnce() async throws {
        let gate = DeliveryFlow.gate
        let entries = gate.configure(blocks: 1)
        let (pendingEvents, event) = AsyncStream<DeliveryFlow.PendingCompletion>.makeStream()
        let owner = DeliveryFlow.Shared(
            .init(presentation: 0),
            drivers: .init(fetch: { gate.execute($0) }, audit: { gate.execute($0) }),
            onReconciliationRequired: { event.yield($0) }
        )
        guard case .idle(let idle) = owner.snapshot(), case .committed = owner.commit(try idle.begin(7)) else {
            throw Failure.unexpected
        }
        var starts = entries.makeAsyncIterator()
        #expect(await starts.next() == 1)
        let completion = try #require(gate.captured)
        let beforeDuplicates = owner.snapshot()
        guard case .loading(let beforeLoading) = beforeDuplicates else { throw Failure.unexpected }
        #expect(beforeLoading.value.request == 7)
        #expect(beforeLoading.value.presentation == 0)
        #expect(beforeDuplicates.revision == 1)
        let duplicates = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if case .pending(_, .preparing) = owner.deliver(completion) { duplicates.withLock { $0 += 1 } }
        }
        #expect(duplicates.withLock { $0 } == 16)
        guard case .loading(let afterDuplicates) = owner.snapshot() else { throw Failure.unexpected }
        #expect(afterDuplicates.value.request == beforeLoading.value.request)
        #expect(afterDuplicates.value.presentation == beforeLoading.value.presentation)
        #expect(owner.snapshot().revision == beforeDuplicates.revision)
        guard case .loading(let loading) = owner.snapshot(), case .committed = owner.commit(try loading.edit(9)) else {
            throw Failure.unexpected
        }
        gate.release()
        var notifications = pendingEvents.makeAsyncIterator()
        let pending = try #require(await notifications.next())
        #expect(pending.status == .reconciliationRequired)
        #expect(pending.attempts == 1)
        guard case .admission(.conflict) = pending.lastRejection else { throw Failure.unexpected }
        #expect(owner.pendingCompletions().count == 1)
        guard case .pending(let sameID, .reconciliationRequired) = owner.deliver(completion) else {
            throw Failure.unexpected
        }
        #expect(sameID == pending.id)
        guard case .loading(let beforeReconciliation) = owner.snapshot() else { throw Failure.unexpected }
        #expect(beforeReconciliation.value.request == 7)
        #expect(beforeReconciliation.value.presentation == 9)
        #expect(owner.snapshot().revision == 2)
        #expect(gate.counts.0 == 1)
        guard case .committed = owner.reconcile(id: pending.id), case .loaded(let loaded) = owner.snapshot() else {
            throw Failure.unexpected
        }
        #expect(loaded.value.result == 7)
        #expect(loaded.value.presentation == 9)
        #expect(owner.snapshot().revision == 3)
        let terminalDuplicates = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            if case .stale = owner.deliver(completion) { terminalDuplicates.withLock { $0 += 1 } }
        }
        #expect(terminalDuplicates.withLock { $0 } == 16)
        guard case .loaded(let afterTerminalDuplicates) = owner.snapshot() else { throw Failure.unexpected }
        #expect(afterTerminalDuplicates.value.result == 7)
        #expect(afterTerminalDuplicates.value.presentation == 9)
        #expect(owner.snapshot().revision == 3)
        guard case .notPending = owner.reconcile(id: pending.id) else { throw Failure.unexpected }
        #expect(owner.snapshot().revision == 3)
        #expect(gate.counts.0 == 2)
        #expect(gate.counts.1 == 1)
        #expect(owner.pendingCompletions().isEmpty)
        guard case .stale = owner.deliver(completion) else { throw Failure.unexpected }
        event.finish()
        await owner.shutdown()
        #expect(owner.isQuiescent)
    }
    @Test func generatedRetryPureReevaluatesAfterConflictsWithoutRepeatingDriver() async throws {
        let gate = DeliveryFlow.gate
        let entries = gate.configure(blocks: 6)
        let owner = DeliveryFlow.Shared(
            .init(presentation: 0),
            drivers: .init(fetch: { gate.execute($0) }, audit: { gate.execute($0) }),
            completionPolicy: .retryPure
        )
        let (snapshots, events) = AsyncStream<DeliveryFlow.Snapshot>.makeStream()
        let token = try owner.subscribe { events.yield($0) }
        defer {
            token.cancel()
            events.finish()
        }
        guard case .idle(let idle) = owner.snapshot(), case .committed = owner.commit(try idle.begin(7)) else {
            throw Failure.unexpected
        }
        var starts = entries.makeAsyncIterator()
        for expected in 1 ... 6 {
            #expect(await starts.next() == expected)
            guard case .loading(let loading) = owner.snapshot(),
                case .committed = owner.commit(try loading.edit(expected))
            else { throw Failure.unexpected }
            gate.release()
        }
        var values = snapshots.makeAsyncIterator()
        while let snapshot = await values.next() {
            if case .loaded(let loaded) = snapshot {
                #expect(loaded.value.result == 7)
                #expect(loaded.value.presentation == 6)
                break
            }
        }
        #expect(gate.counts.0 == 7)
        #expect(gate.counts.1 == 1)
        #expect(owner.pendingCompletions().isEmpty)
        await owner.shutdown()
        #expect(owner.isQuiescent)
    }
}

extension GeneratedDeliveryTests {
    @Test func completionRouterCannotSubstituteInputOrAnotherOperationCandidate() throws {
        let gate = DeliveryFlow.gate
        _ = gate.configure(blocks: 0)
        var owner = DeliveryFlow.Local(.init(presentation: 0))
        guard case .idle(let idle) = owner.snapshot(), case .committed = owner.commit(try idle.begin(7)),
            case .fetch(let fetch) = owner.drainCommands(limit: 1).first?.commands.first,
            case .loading(let loading) = owner.snapshot(), case .committed = owner.commit(try loading.audit(9)),
            case .audit(let audit) = owner.drainCommands(limit: 1).first?.commands.first,
            case .success(let alternate) = audit.succeeded(9)
        else { throw Failure.unexpected }
        let before = owner.snapshot().revision
        gate.select(.input)
        guard case .pending(let id, .reconciliationRequired) = owner.deliver(.fetch(fetch.succeeded(7))) else {
            throw Failure.unexpected
        }
        #expect(owner.snapshot().revision == before)
        let first = try #require(owner.pendingCompletions().first)
        guard case .preparation(.plan(.invalidPlan)) = first.lastRejection,
            case .fetch(.success(let retained)) = first.outcome
        else { throw Failure.unexpected }
        #expect(retained.value == 7)
        #expect(first.attempts == 1)
        let emptyAfterInput = owner.drainCommands(limit: 10).isEmpty
        #expect(emptyAfterInput)
        gate.select(.anotherOperation, alternate: alternate)
        guard case .pending(let sameID, .reconciliationRequired) = owner.reconcile(id: id) else {
            throw Failure.unexpected
        }
        #expect(sameID == id)
        #expect(owner.snapshot().revision == before)
        let second = try #require(owner.pendingCompletions().first)
        guard case .preparation(.plan(.invalidPlan)) = second.lastRejection else { throw Failure.unexpected }
        #expect(second.attempts == 2)
        let emptyAfterOther = owner.drainCommands(limit: 10).isEmpty
        #expect(emptyAfterOther)
        // The rejected candidate did not consume the other operation's authority.
        guard case .committed = owner.deliver(.audit(audit.succeeded(9))) else { throw Failure.unexpected }
        gate.select(.valid)
        guard case .committed = owner.reconcile(id: id), case .loaded(let loaded) = owner.snapshot() else {
            throw Failure.unexpected
        }
        #expect(loaded.value.result == 7)
        #expect(loaded.value.presentation == 0)
        #expect(owner.pendingCompletions().isEmpty)
        _ = owner.acknowledgeExecution(fetch.execution, disposition: .terminated)
        _ = owner.acknowledgeExecution(audit.execution, disposition: .terminated)
        _ = owner.close()
        _ = owner.drainCommands(limit: 20)
        let quiescent = owner.isQuiescent
        #expect(quiescent)
    }
}
