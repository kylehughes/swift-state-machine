import StateMachine
import Testing

@Suite struct RuntimeCompletionGateTests {
    private struct Root {
        var allowsCompletion = false
        var completedValue: Int?
    }
    private enum DomainFailure: Error { case completionNotAllowed }
    private typealias Core = RuntimeState<Root, Int>
    // The test domain issues a terminal envelope only through its committed work.
    private struct Work {
        let raw: RuntimeWork<Int>
        func succeeded(_ value: Int) -> Outcome { Outcome(value: value, ticket: raw.ticket) }
    }
    private struct Outcome {
        let value: Int
        let ticket: RuntimeTicket
        fileprivate init(value: Int, ticket: RuntimeTicket) {
            self.value = value
            self.ticket = ticket
        }
    }
    private func prepare(
        _ outcome: Outcome,
        on observation: Core.Snapshot
    ) throws(PreparationFailure<DomainFailure>) -> Core.Candidate {
        guard observation.model.allowsCompletion else { throw .domain(.completionNotAllowed) }
        var next = observation.model
        next.completedValue = outcome.value
        do {
            return try Core.prepare(
                on: observation,
                next: next,
                requiring: [outcome.ticket],
                plan: .init(retire: [outcome.ticket])
            )
        } catch { throw .plan(error) }
    }

    @Test func rejectedCompletionPreservesAuthorityForSameEnvelopeAfterCorrection_RT006() throws {
        let scope = RuntimeScopeID(kind: 0)
        var core = Core(Root(), scopes: [scope], limits: try .init())
        let start = try Core.prepare(
            on: core.snapshot,
            next: Root(),
            plan: .init(starts: [.init(.init(kind: 0, scope: scope), descriptor: 7)])
        )
        guard case .committed = core.commit(start),
            let batch = core.drain(limit: 1).first,
            case .start(let rawWork) = batch.commands.first
        else {
            Issue.record("Expected committed work")
            return
        }
        let work = Work(raw: rawWork)
        let envelope = work.succeeded(42)
        let before = core.snapshot
        do {
            _ = try prepare(envelope, on: before)
            Issue.record("Completion domain precondition did not reject")
        } catch {
            guard case .domain(.completionNotAllowed) = error else {
                Issue.record("Wrong completion preparation rejection")
                return
            }
        }
        #expect(core.snapshot.revision == before.revision)
        #expect(core.snapshot.model.completedValue == nil)
        #expect(core.isActive(rawWork.ticket))
        #expect(core.executionReservations.count == 1)
        #expect(!core.hasQueuedBatches)

        var corrected = core.snapshot.model
        corrected.allowsCompletion = true
        let correction = try Core.prepare(on: core.snapshot, next: corrected)
        guard case .committed = core.commit(correction) else {
            Issue.record("Corrective root edit rejected")
            return
        }
        #expect(core.isActive(rawWork.ticket))
        let retried = try prepare(envelope, on: core.snapshot)
        guard case .committed(let receipt) = core.commit(retried) else {
            Issue.record("Same retained envelope failed after correction")
            return
        }
        #expect(receipt.revision == before.revision + 2)
        #expect(receipt.model.completedValue == 42)
        #expect(!core.isActive(rawWork.ticket))
        #expect(core.drain(limit: 10).map(\.snapshot.revision) == [2, 3])
        // Acceptance settles delivery but cannot impersonate physical termination.
        #expect(core.executionReservations.count == 1)
        #expect(core.acknowledge(rawWork.ticket) == .recorded)
        #expect(core.executionReservations.isEmpty)
    }
}
