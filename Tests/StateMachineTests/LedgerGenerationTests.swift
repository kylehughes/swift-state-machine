import Dispatch
import StateMachine
import StateMachineTestSupport
import Testing
import os

// The ledger's change generation wraps at its limit instead of trapping or stopping, and tells each
// image from the one before it. A `Shared` owner delivers its images of the retained completions
// through its one report queue, in the order of the installations that made them, so an image held
// behind a reconciliation handler never reaches a registration after a newer one, however far the
// generation has advanced meanwhile.

@Suite(.timeLimit(.minutes(2))) struct LedgerGenerationTests {
    private typealias Core = RuntimeState<Int, Int>
    private typealias Ledger = RuntimeDeliveryLedger<Int, Int, Int, Refusal>
    private struct Refusal: Error {}
    private let scope = RuntimeScopeID(kind: 1)

    // One retained outcome whose preparation always refuses is reconciled again and again. Each attempt
    // changes the ledger several times; starting a few changes short of the limit, the attempts cross
    // it, and every generation differs from the one before.
    @Test func refusedReconciliationsCrossTheGenerationLimit() throws {
        var core = Core(0, scopes: [scope], limits: try .init())
        let candidate = try Core.prepare(
            on: core.snapshot,
            next: 1,
            plan: .init(starts: [.init(.init(kind: 1, scope: scope), descriptor: 1)])
        )
        guard case .committed = core.commit(candidate) else {
            Issue.record("Expected admission")
            return
        }
        let work = try #require(
            core.drain(limit: 1).flatMap(\.commands)
                .compactMap { command -> RuntimeWork<Int>? in
                    if case .start(let work) = command { return work }
                    return nil
                }
                .first
        )
        var ledger = Ledger(generation: .max - 3)
        guard case .pending(let id) = ledger.retain(7, for: work.ticket, in: &core) else {
            Issue.record("Expected a retained outcome")
            return
        }
        var previous = ledger.generation
        var wrapped = false
        for _ in 0 ..< 4 {
            guard case .claimed(let attempt) = ledger.claim(id, in: &core) else {
                Issue.record("Expected a claim")
                return
            }
            _ = ledger.finish(attempt, preparation: .failure(.preparation(Refusal())), in: &core)
            let current = ledger.generation
            #expect(current != previous)
            if current < previous { wrapped = true }
            previous = current
        }
        #expect(wrapped)
        #expect(ledger.pending.first?.attempts == 4)
        #expect(ledger.pending.first?.status == .reconciliationRequired)
    }

    // A mailbox without revisions takes every offer as newer than the last: its owner offers them in
    // order.
    @Test func aMailboxWithoutRevisionsTakesEachOfferInOrder() async {
        let (received, receiving) = AsyncStream<Int>.makeStream()
        let mailbox = LatestMailbox(
            initial: 1,
            revision: nil,
            terminal: false,
            receive: { receiving.yield($0) },
            finish: {}
        )
        mailbox.activate()
        var values = received.makeAsyncIterator()
        #expect(await values.next() == 1)
        mailbox.offer(2, revision: nil, terminal: false)
        #expect(await values.next() == 2)
        mailbox.offer(3, revision: nil, terminal: false)
        mailbox.offer(4, revision: nil, terminal: true)
        #expect(await values.next() == 4)
        mailbox.cancel()
        receiving.finish()
    }

    // A returning worker's refusal is reported to a handler that holds its thread, after the
    // installation that queued the image showing A refused. Meanwhile the generation advances by more than half its range, and A
    // is discarded. Once the handler returns, the registration receives the held image before the
    // newer ones, so its last image is the empty collection.
    @Test(.parksCooperativeThread) func anImageHeldBehindAHandlerNeverFollowsANewerOne() async throws {
        typealias Host = RuntimeSharedHost<Int, Int, RuntimeTicket, Refusal>
        let hold = Hold()
        // A failed requirement returns before the step that lets the handler go.
        defer { hold.proceed() }
        let owner = Host(
            0,
            scopes: [scope],
            limits: try .init(),
            policy: .manual,
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.preparation(Refusal())) },
            reconciliationRequired: { _ in hold.hold() }
        )
        let images = Images()
        let subscription = try owner.subscribePending { images.append($0.count) }
        _ = owner.commit(
            try Core.prepare(
                on: owner.snapshot(),
                next: 1,
                plan: .init(starts: [.init(.init(kind: 1, scope: scope), descriptor: 1)])
            )
        )
        // The returning worker's delivery reports A's refusal, and the handler holds its thread.
        await hold.reached()
        let id = try #require(owner.pendingCompletions().first?.id)
        owner.advancePendingGeneration(by: 1 << 63 + 1)
        guard case .discarded = owner.discardPending(id: id) else {
            Issue.record("Expected the discard to commit")
            return
        }
        hold.proceed()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while images.last != 0, !images.regressed, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!images.regressed)
        #expect(images.last == 0)
        subscription.cancel()
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(10))) == nil)
    }
}

/// The sizes of the images a pending-completion registration received, and whether one that held A
/// arrived after one that no longer did.
private final class Images: Sendable {
    private struct State {
        var last: Int?
        var held = false
        var released = false
        var regressed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var last: Int? { state.withLock { $0.last } }
    var regressed: Bool { state.withLock { $0.regressed } }
    func append(_ size: Int) {
        state.withLock { state in
            if size > 0 {
                if state.released { state.regressed = true }
                state.held = true
            } else if state.held {
                state.released = true
            }
            state.last = size
        }
    }
}

/// Holds the thread of the first handler call that reaches it until the test lets it go.
private final class Hold: Sendable {
    private let held = ThreadGate()
    private let entered = AsyncStream<Void>.makeStream()
    private let first = OSAllocatedUnfairLock(initialState: true)
    func hold() {
        guard first.withLock({ exchange(&$0, with: false) }) else { return }
        entered.continuation.yield(())
        held.wait()
    }
    func reached() async {
        var iterator = entered.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
    func proceed() { held.open() }
}
