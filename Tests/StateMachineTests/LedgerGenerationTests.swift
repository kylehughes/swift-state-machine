import StateMachine
import Testing

// The ledger's change generation wraps at its limit instead of trapping or stopping, and a
// pending-completion mailbox orders the generations of the images it receives as serial numbers, so an
// image made after the wrap still reaches it as the newest.

@Suite(.timeLimit(.minutes(1))) struct LedgerGenerationTests {
    private typealias Core = RuntimeState<Int, Int>
    private typealias Ledger = RuntimeDeliveryLedger<Int, Int, Int, Refusal>
    private struct Refusal: Error {}
    private let scope = RuntimeScopeID(kind: 1)

    // One retained outcome whose preparation always refuses is reconciled again and again. Each attempt
    // changes the ledger several times; starting a few changes short of the limit, the attempts cross
    // it, and every generation follows the one before.
    @Test func refusedReconciliationsCrossTheGenerationLimitInOrder() throws {
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
            #expect(LatestMailbox<Int>.Order.generation.isNewer(current, than: previous))
            #expect(!LatestMailbox<Int>.Order.generation.isNewer(previous, than: current))
            if current < previous { wrapped = true }
            previous = current
        }
        #expect(wrapped)
        #expect(ledger.pending.first?.attempts == 4)
        #expect(ledger.pending.first?.status == .reconciliationRequired)
    }

    // A mailbox whose last image has the largest generation receives the next image, whose generation
    // wrapped to 0, and then drops a stale image offered with the generation before that.
    @Test func aPendingMailboxTakesTheImageAfterTheWrapAsTheNewest() async {
        let (received, receiving) = AsyncStream<Int>.makeStream()
        let mailbox = LatestMailbox(
            initial: 1,
            revision: .max,
            terminal: false,
            order: .generation,
            receive: { receiving.yield($0) },
            finish: {}
        )
        mailbox.activate()
        var values = received.makeAsyncIterator()
        #expect(await values.next() == 1)
        mailbox.offer(2, revision: 0, terminal: false)
        #expect(await values.next() == 2)
        mailbox.offer(3, revision: .max, terminal: false)
        mailbox.offer(4, revision: 1, terminal: true)
        #expect(await values.next() == 4)
        mailbox.cancel()
        receiving.finish()
    }
}
