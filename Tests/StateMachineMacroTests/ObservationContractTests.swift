import Dispatch
import StateMachine
import StateMachineSchema
import Testing

@StateMachine(mode: .shared)
nonisolated private enum ObservationValueFlow: Sendable, Equatable {
    struct Before: Sendable, Equatable {
        let left: Int
        let right: Int
        let history: [String: [[Int]]]
    }
    struct After: Sendable, Equatable {
        let left: Int
        let right: Int
        let history: [String: [[Int]]]
    }
    @Initial case before(Before)
    case after(After)
    enum Input: Sendable {
        case advance
        case append(Int)
    }

    @Transition(on: Input.advance)
    fileprivate static func advance(_ source: Before) -> After {
        After(left: source.left + 1, right: source.right + 10, history: source.history)
    }

    @Transition(on: Input.append)
    fileprivate static func append(_ source: After, _ value: Int) -> After {
        var history = source.history
        history["rows", default: []].append([value, value + 1])
        return After(left: source.left, right: source.right, history: history)
    }
}

@StateMachine(mode: .isolated)
nonisolated private enum IsolatedObservationValueFlow {
    struct Value { let history: [String: [[Int]]] }
    @Initial case value(Value)
    enum Input { case append(Int) }

    @Transition(on: Input.append)
    fileprivate static func append(_ source: Value, _ value: Int) -> Value {
        var history = source.history
        history["rows", default: []].append([value, value + 1])
        return Value(history: history)
    }
}

// One-shot broadcast barriers coordinate readers without assuming executor order.
private actor ObservationReadGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@Suite(.timeLimit(.minutes(1)))
struct ObservationContractTests {
    private enum Failure: Error { case unexpected }
    private enum Description: Sendable, Equatable {
        case audit(Int)
        case publish(String)
    }

    @Test func correlatedFieldsAndPhaseAreOneSharedObservation_RT001() async throws {
        typealias Host = RuntimeSharedHost<ObservationValueFlow, Never, RuntimeTicket, Never>
        typealias Core = Host.Engine
        let initial = ObservationValueFlow.Before(left: 1, right: 10, history: ["rows": [[1, 2]]])
        let owner = Host(
            manual: .before(initial),
            scopes: [],
            limits: try RuntimeLimits(),
            ticket: { $0 },
            prepare: { _ in .failure(.plan(.invalidPlan)) }
        )
        let old = owner.snapshot()
        // This raw host exercises real shared storage and FIFO batches. The test
        // invokes the declared domain edge itself; it does not claim raw candidate
        // construction enforces a generated facade's sealed transition boundary.
        let successor = ObservationValueFlow.after(ObservationValueFlow.advance(initial))
        let candidate = try Core.prepare(on: old, next: successor)
        let start = ObservationReadGate()
        let committed = ObservationReadGate()
        let (ready, readiness) = AsyncStream<Void>.makeStream()
        defer { readiness.finish() }
        let samples = await withTaskGroup(of: [Core.Snapshot].self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    var observations = [owner.snapshot()]
                    readiness.yield(())
                    await start.wait()
                    for _ in 0 ..< 64 { observations.append(owner.snapshot()) }
                    await committed.wait()
                    observations.append(owner.snapshot())
                    return observations
                }
            }
            var entries = ready.makeAsyncIterator()
            for _ in 0 ..< 8 { _ = await entries.next() }
            await start.open()
            let admission = owner.commit(candidate)
            await committed.open()
            guard case .committed(let receipt) = admission else {
                Issue.record("Correlated transition rejected")
                var observations: [[Core.Snapshot]] = []
                for await values in group { observations.append(values) }
                return observations
            }
            #expect(receipt.revision == 1)
            #expect(receipt.model == successor)
            #expect(!receipt.isClosed)
            var observations: [[Core.Snapshot]] = []
            for await values in group { observations.append(values) }
            return observations
        }
        #expect(samples.count == 8)
        for reader in samples {
            #expect(reader.first?.model == .before(initial))
            #expect(reader.first?.revision == 0)
            #expect(reader.last?.model == successor)
            #expect(reader.last?.revision == 1)
            #expect(
                reader.allSatisfy { snapshot in
                    (snapshot.revision == 0 && snapshot.model == .before(initial))
                        || (snapshot.revision == 1 && snapshot.model == successor)
                }
            )
        }
        let batches = owner.drainCommands(limit: 10)
        #expect(batches.count == 1)
        #expect(batches.first?.snapshot.revision == 1)
        #expect(batches.first?.snapshot.model == successor)
        #expect(batches.allSatisfy { !$0.terminal && $0.commands.isEmpty })
        #expect(owner.drainCommands(limit: 10).isEmpty)
        _ = owner.close()
        #expect(owner.drainCommands(limit: 10).map(\.terminal) == [true])
        #expect(owner.isQuiescent)
    }

    @Test func sharedNestedSnapshotsAndProjectedCopyRemainIndependent_RT008() async throws {
        let original = ["rows": [[1, 2], [3, 4]]]
        let owner = ObservationValueFlow.Shared(.init(left: 1, right: 10, history: original), drivers: .init())
        do {
            let before = owner.snapshot()
            guard case .before(let initial) = before,
                case .committed(let first) = owner.commit(try initial.advance()),
                case .after(let after) = first.snapshot,
                case .committed(let second) = owner.commit(try after.append(5)),
                case .after(let middle) = second.snapshot,
                case .committed(let third) = owner.commit(try middle.append(7)),
                case .after(let current) = owner.snapshot()
            else { throw Failure.unexpected }
            var projected = middle.value.history
            projected["rows"]?[0][0] = 999
            projected["rows", default: []].append([1000])
            projected["independent"] = [[42]]
            #expect(projected != middle.value.history)
            #expect(initial.value.history == original)
            #expect(after.value.history == original)
            #expect(middle.value.history == ["rows": [[1, 2], [3, 4], [5, 6]]])
            #expect(current.value.history == ["rows": [[1, 2], [3, 4], [5, 6], [7, 8]]])
            #expect([before.revision, first.revision, second.revision, third.revision] == [0, 1, 2, 3])
            guard case .after(let reread) = owner.snapshot() else { throw Failure.unexpected }
            #expect(reread.value.history == current.value.history)
        } catch {
            await owner.shutdown()
            throw error
        }
        await owner.shutdown()
        #expect(owner.isQuiescent)
    }

    @Test func isolatedNestedSnapshotsAndProjectedCopyRemainIndependent_RT008() throws {
        let original = ["rows": [[1, 2], [3, 4]]]
        var owner = IsolatedObservationValueFlow.Local(.init(history: original))
        let before = owner.snapshot()
        guard case .value(let initial) = before,
            case .committed(let first) = owner.commit(try initial.append(5)),
            case .value(let middle) = first.snapshot,
            case .committed(let second) = owner.commit(try middle.append(7)),
            case .value(let current) = owner.snapshot()
        else { throw Failure.unexpected }
        var projected = middle.value.history
        projected["rows"]?[0][0] = 999
        projected["rows", default: []].append([1000])
        projected["independent"] = [[42]]
        #expect(projected != middle.value.history)
        #expect(initial.value.history == original)
        #expect(middle.value.history == ["rows": [[1, 2], [3, 4], [5, 6]]])
        #expect(current.value.history == ["rows": [[1, 2], [3, 4], [5, 6], [7, 8]]])
        #expect([before.revision, first.revision, second.revision] == [0, 1, 2])
        guard case .value(let reread) = owner.snapshot() else { throw Failure.unexpected }
        #expect(reread.value.history == current.value.history)
        _ = owner.close()
        #expect(owner.drainCommands(limit: 10).map(\.receipt.revision) == [1, 2, 3])
        let quiescent = owner.isQuiescent
        #expect(quiescent)
    }

    @Test(.parksCooperativeThread) func slowSubscriberCoalescesSnapshotsWithoutCoalescingCommands_RT026() async throws {
        typealias Host = RuntimeSharedHost<Int, Description, RuntimeTicket, Never>
        typealias Core = Host.Engine
        let scope = RuntimeScopeID(kind: 1)
        let operation = RuntimeOperation(kind: 1, scope: scope, policy: .parallel(40))
        let owner = Host(
            manual: 0,
            scopes: [scope],
            limits: try RuntimeLimits(),
            ticket: { $0 },
            prepare: { _ in .failure(.plan(.invalidPlan)) }
        )
        let release = DispatchSemaphore(value: 0)
        let (entered, entry) = AsyncStream<Void>.makeStream()
        let (events, observations) = AsyncStream<Core.Snapshot>.makeStream()
        let subscription = try owner.subscribe { snapshot in
            observations.yield(snapshot)
            if snapshot.revision == 0 {
                entry.yield(())
                entry.finish()
                // The synchronous production callback remains claimed while all
                // effectful commits occur. This deadline only bounds a failure.
                #expect(release.wait(timeout: .now() + 10) == .success)
            }
        } onFinish: {
            observations.finish()
        }
        defer {
            release.signal()
            subscription.cancel()
            entry.finish()
            observations.finish()
        }
        do {
            var readiness = entered.makeAsyncIterator()
            _ = try #require(await readiness.next())
            for index in 1 ... 20 {
                let plan = Core.Plan(starts: [
                    .init(operation, descriptor: .audit(index)),
                    .init(operation, descriptor: .publish("value \(index)")),
                ])
                let candidate = try Core.prepare(on: owner.snapshot(), next: index, plan: plan)
                guard case .committed(let receipt) = owner.commit(candidate) else { throw Failure.unexpected }
                #expect(receipt.revision == UInt64(index))
                #expect(receipt.model == index)
            }
            // Draining before close preserves every accepted start decision. This
            // manual host grants no automatic driver execution: acknowledge each
            // issued description explicitly as skipped after inspecting its batch.
            let batches = owner.drainCommands(limit: 100)
            #expect(batches.map(\.snapshot.revision) == Array(UInt64(1) ... UInt64(20)))
            #expect(batches.allSatisfy { !$0.terminal && $0.commands.count == 2 })
            var works: [RuntimeWork<Description>] = []
            for (index, batch) in batches.enumerated() {
                let starts = batch.commands.compactMap { command -> RuntimeWork<Description>? in
                    guard case .start(let work) = command else { return nil }
                    return work
                }
                #expect(starts.map(\.descriptor) == [.audit(index + 1), .publish("value \(index + 1)")])
                works.append(contentsOf: starts)
            }
            #expect(works.count == 40)
            #expect(owner.drainCommands(limit: 100).isEmpty)
            for work in works {
                #expect(owner.acknowledge(work.ticket, skipped: true) == .recorded)
                #expect(owner.acknowledge(work.ticket, skipped: true) == .duplicate)
            }
            let closed = owner.close()
            let terminal = owner.drainCommands(limit: 100)
            #expect(terminal.count == 1)
            #expect(terminal.first?.terminal == true)
            #expect(terminal.first?.snapshot.revision == 21)
            #expect(owner.drainCommands(limit: 100).isEmpty)
            release.signal()
            var delivered: [Core.Snapshot] = []
            for await snapshot in events { delivered.append(snapshot) }
            // onFinish is the terminal callback barrier; all reader tasks above are
            // structured, and this host has no unjoined physical driver tasks.
            #expect(delivered.map(\.revision) == [0, closed.revision])
            #expect(delivered.map(\.model) == [0, 20])
            #expect(delivered.last?.isClosed == true)
            #expect(zip(delivered, delivered.dropFirst()).allSatisfy { $0.revision < $1.revision })
            #expect(owner.diagnostics().outstandingExecutions.isEmpty)
            #expect(owner.isQuiescent)
        } catch {
            _ = owner.close()
            _ = owner.drainCommands(limit: 100)
            release.signal()
            // Join the terminal callback even when preparation or readiness fails.
            for await _ in events {}
            #expect(owner.isQuiescent)
            throw error
        }
    }
}
