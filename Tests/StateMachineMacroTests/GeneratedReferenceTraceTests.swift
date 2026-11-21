import StateMachine
import StateMachineExamples
import Testing

@testable import StateMachineReferenceModel

@Suite struct GeneratedReferenceTraceTests {
    private enum Failure: Error { case unexpected }
    private func compare(
        _ generated: GeneratedProfile.Snapshot,
        _ handwritten: ReferenceProfile.Snapshot,
        _ expected: ReferenceSnapshot
    ) {
        let generatedPhase: ReferencePhase
        switch generated {
        case .idle: generatedPhase = .idle(1)
        case .loading: generatedPhase = .loading(1)
        case .loaded: generatedPhase = .loaded(2)
        case .failed: generatedPhase = .failed(request: 1, failure: 1)
        }
        let handwrittenPhase: ReferencePhase
        switch handwritten {
        case .idle: handwrittenPhase = .idle(1)
        case .loading: handwrittenPhase = .loading(1)
        case .loaded: handwrittenPhase = .loaded(2)
        case .failed: handwrittenPhase = .failed(request: 1, failure: 1)
        }
        #expect(generatedPhase == expected.root.phase)
        #expect(handwrittenPhase == expected.root.phase)
        #expect(generated.revision == expected.stamp.revision)
        #expect(handwritten.revision == expected.stamp.revision)
        #expect(generated.isClosed == expected.closed)
        #expect(handwritten.isClosed == expected.closed)
    }
    @Test(arguments: [false, true], [false, true])
    func generatedAndHandwrittenExecuteSameIndependentTrace(invalidate: Bool, acknowledgeBefore: Bool) throws {
        let user = try UserID("kyle")
        let request = try ProfileRequest(userID: user)
        var generated = GeneratedProfile.Local(.init(userID: user))
        var handwritten = ReferenceProfile.Local(.init(userID: user))
        var oracle = SequentialReference(owner: 1)
        compare(generated.snapshot(), handwritten.snapshot(), oracle.snapshot)
        guard case .idle(let gIdle) = generated.snapshot(), case .idle(let hIdle) = handwritten.snapshot(),
            case .committed = generated.commit(try gIdle.begin(request)),
            case .committed = handwritten.commit(try hIdle.load(request)),
            case .committed = oracle.commit(try oracle.prepare(.load(1)))
        else { throw Failure.unexpected }
        compare(generated.snapshot(), handwritten.snapshot(), oracle.snapshot)
        guard case .fetch(let gWork) = generated.drainCommands(limit: 1).first?.commands.first,
            case .start(let hWork) = handwritten.drainCommands(limit: 1).first?.commands.first,
            let ticket = oracle.drain(limit: 1).first?.starts.first,
            case .loading(let gLoading) = generated.snapshot()
        else { throw Failure.unexpected }
        let prior = oracle.snapshot
        if acknowledgeBefore {
            _ = generated.acknowledgeExecution(gWork.execution, disposition: .terminated)
            _ = handwritten.acknowledgeExecution(hWork.execution, disposition: .terminated)
            oracle.acknowledge(ticket)
        }
        if invalidate {
            guard case .committed = generated.commit(gLoading.authenticationChanged()),
                case .committed = handwritten.commit(handwritten.snapshot().authenticationChanged()),
                case .committed = oracle.commit(try oracle.prepare(.authentication))
            else { throw Failure.unexpected }
        }
        let gOutcome = gWork.succeeded(Profile(userID: user, name: "2"))
        let hOutcome = ReferenceProfile.Completion.fetch(hWork.succeeded(Profile(userID: user, name: "2")))
        // Every owner admits a completion only through delivery, which retains the outcome first; revoked
        // authority makes it stale.
        let gResult = generated.deliver(gOutcome)
        let hResult = handwritten.deliver(hOutcome)
        if invalidate {
            guard case .discarded(.inactiveAuthority) = oracle.retain(ticket, outcome: .success(2)),
                case .stale = gResult, case .stale = hResult
            else { throw Failure.unexpected }
        } else {
            guard case .pending = oracle.retain(ticket, outcome: .success(2)),
                case .committed = oracle.deliveryTurn(ticket.operation), case .committed = gResult,
                case .committed = hResult
            else { throw Failure.unexpected }
        }
        compare(generated.snapshot(), handwritten.snapshot(), oracle.snapshot)
        // A copied outcome cannot authorize a second admission, even with its original phase observation.
        guard case .stale = generated.deliver(gOutcome),
            case .stale = handwritten.deliver(hOutcome),
            case .rejected(.inactiveAuthority) = oracle.commit(
                try oracle.prepareCompletion(ticket, outcome: .success(2), on: prior)
            )
        else { throw Failure.unexpected }
        if !acknowledgeBefore {
            _ = generated.acknowledgeExecution(gWork.execution, disposition: .terminated)
            _ = handwritten.acknowledgeExecution(hWork.execution, disposition: .terminated)
            oracle.acknowledge(ticket)
        }
        let gBatches = generated.drainCommands(limit: 20)
        let hBatches = handwritten.drainCommands(limit: 20)
        // The reference records every acceptance, and a `Local` queues only those that carry commands. An
        // admitted completion retires its own work without cancelling it, so it carries none.
        let referenceBatches = oracle.drain(limit: 20).filter { !$0.cancelled.isEmpty || !$0.starts.isEmpty }
        #expect(gBatches.map(\.receipt.revision) == referenceBatches.map { $0.snapshot.stamp.revision })
        #expect(hBatches.map(\.receipt.revision) == referenceBatches.map { $0.snapshot.stamp.revision })
        #expect(gBatches.map { $0.commands.count } == referenceBatches.map { $0.cancelled.count + $0.starts.count })
        #expect(hBatches.map { $0.commands.count } == referenceBatches.map { $0.cancelled.count + $0.starts.count })
        _ = generated.close()
        _ = handwritten.close()
        _ = oracle.close()
        _ = generated.drainCommands(limit: 20)
        _ = handwritten.drainCommands(limit: 20)
        _ = oracle.drain(limit: 20)
        compare(generated.snapshot(), handwritten.snapshot(), oracle.snapshot)
        let gQuiescent = generated.isQuiescent
        let hQuiescent = handwritten.isQuiescent
        #expect(gQuiescent)
        #expect(hQuiescent)
    }
}
