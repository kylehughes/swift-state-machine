import StateMachine
import Testing

@Suite(.timeLimit(.minutes(1))) struct SharedShutdownTests {
    private typealias Host = RuntimeSharedHost<Int, Int, RuntimeTicket, Never>
    private enum Failure: Error { case unexpected }

    @Test func workThatSettlesBeforeTheDeadlineIsObservedIsReportedQuiescent() async throws {
        let scope = RuntimeScopeID(kind: 1)
        let (started, issued) = AsyncStream<RuntimeTicket>.makeStream()
        let host = Host(
            manual: 0,
            scopes: [scope],
            limits: try Limits(),
            start: { works in for work in works { issued.yield(work.ticket) } },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let candidate = try Host.Engine.prepare(
            on: host.snapshot(),
            next: 1,
            plan: .init(starts: [.init(.init(kind: 1, scope: scope), descriptor: 1)])
        )
        guard case .committed = host.commit(candidate) else { throw Failure.unexpected }
        var iterator = started.makeAsyncIterator()
        let ticket = try #require(await iterator.next())
        let closed = host.close()
        #expect(await host.flush(through: closed))
        // The issued execution is the one obligation left. The clock reading is where it
        // terminates: after the load that found it outstanding, before expiry is observed.
        // The deadline bounds only the wait for the drainer to finish its last turn.
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        let diagnostics = await host.shutdown(
            deadline: deadline,
            now: {
                guard !host.diagnostics().isDraining else { return ContinuousClock.now }
                _ = host.acknowledge(ticket, skipped: false)
                return deadline
            }
        )
        #expect(diagnostics == nil)
        #expect(host.isQuiescent)
    }
}
