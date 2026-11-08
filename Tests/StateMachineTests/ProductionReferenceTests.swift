import StateMachine
import StateMachineExamples
import Testing

@testable import StateMachineReferenceModel

@Suite struct ProductionReferenceTests {
    typealias Flow = ReferenceProfile

    private func root(_ snapshot: Flow.Snapshot) -> ReferenceRoot {
        let phase: ReferencePhase
        switch snapshot.model {
        case .idle: phase = .idle(1)
        case .loading: phase = .loading(1)
        case .loaded: phase = .loaded(2)
        case .failed: phase = .failed(request: 1, failure: 1)
        }
        return ReferenceRoot(phase, presentation: Int(snapshot.presentation) ?? 0)
    }

    private func compare(_ actual: Flow.CommitResult, _ expected: ReferenceAdmission) {
        switch (actual, expected) {
        case (.committed(let receipt), .committed(let snapshot)):
            #expect(receipt.ordinal == snapshot.stamp.revision)
            #expect(root(receipt.snapshot) == snapshot.root)
        case (.rejected(let reason, _), .rejected(let expectedReason)):
            let mapped: ReferenceRejection
            switch reason {
            case .foreignOwner: mapped = .foreignOwner
            case .closed: mapped = .closed
            case .obsoleteIncarnation: mapped = .obsoleteIncarnation
            case .inactiveAuthority: mapped = .inactiveAuthority
            case .conflict: mapped = .conflict
            case .operationPolicy(.alreadyActive): mapped = .alreadyActive
            case .operationPolicy(.parallelLimit): mapped = .parallelLimit
            case .revisionExhausted: mapped = .revisionExhausted
            case .capacityExceeded(.commitQueue): mapped = .commitQueue
            case .capacityExceeded(.executionReservations): mapped = .executionReservations
            }
            #expect(mapped == expectedReason)
        default: Issue.record("Production and independent interpreter disagree on acceptance")
        }
    }

    @Test(arguments: 0 ..< 32)
    func boundedProductionHistoriesMatchIndependentInterpreter_RT034(seed: Int) throws {
        let id = try UserID("kyle")
        let request = try ProfileRequest(userID: id)
        let flow = Flow.Shared(.init(userID: id), configuration: try .init(commitCapacity: 4, executionCapacity: 4))
        var oracle = SequentialReference(owner: 1, configuration: .init(queue: 4, reservations: 4))
        var saved = flow.snapshot()
        var savedOracle = oracle.snapshot
        var issued: [(Flow.FetchWork, ReferenceTicket)] = []
        var random = UInt64(seed + 1)
        for step in 0 ..< 100 {
            random = random &* 6_364_136_223_846_793_005 &+ 1
            switch random % 8 {
            case 0:
                saved = flow.snapshot()
                savedOracle = oracle.snapshot
            case 1:
                let actual = flow.commit(saved.presentationChanged(String(step)))
                let expected = oracle.commit(try oracle.prepare(.presentation(step), on: savedOracle))
                compare(actual, expected)
            case 2:
                let actual = flow.commit(flow.snapshot().presentationChanged(String(step)))
                compare(actual, oracle.commit(try oracle.prepare(.presentation(step))))
            case 3:
                switch flow.snapshot() {
                case .idle(let observed):
                    compare(flow.commit(try observed.load(request)), oracle.commit(try oracle.prepare(.load(1))))
                case .loaded(let observed):
                    compare(flow.commit(try observed.refresh(request)), oracle.commit(try oracle.prepare(.refresh(1))))
                case .failed(let observed):
                    compare(flow.commit(try observed.retry()), oracle.commit(try oracle.prepare(.retry)))
                case .loading(let observed):
                    compare(flow.commit(observed.cancel()), oracle.commit(try oracle.prepare(.cancel)))
                }
            case 4:
                let actual = flow.drainCommands(limit: 2)
                let expected = oracle.drain(limit: 2)
                #expect(actual.map(\.receipt.ordinal) == expected.map { $0.snapshot.stamp.revision })
                #expect(actual.map(\.terminal) == expected.map(\.terminal))
                for (batch, reference) in zip(actual, expected) {
                    let starts = batch.commands.compactMap { command -> Flow.FetchWork? in
                        if case .start(let work) = command { return work }
                        return nil
                    }
                    let tickets = reference.starts.filter { oracle.valid($0) }
                    #expect(starts.count == tickets.count)
                    issued.append(contentsOf: zip(starts, tickets).map { ($0, $1) })
                    let cancels = batch.commands.filter { if case .cancel = $0 { true } else { false } }
                    #expect(cancels.count == reference.revoked.count)
                }
            case 5:
                if case .loading(let loading) = flow.snapshot(), let (work, ticket) = issued.last,
                    case .success(let completion) = work.succeeded(Profile(userID: id, name: "2"))
                {
                    let actual = flow.commit(try loading.received(completion))
                    let expected = oracle.commit(try oracle.prepareCompletion(ticket, outcome: .success(2)))
                    compare(actual, expected)
                }
            case 6:
                if !issued.isEmpty {
                    let (work, ticket) = issued.removeFirst()
                    _ = flow.acknowledgeExecution(work.execution, disposition: .terminated)
                    oracle.acknowledge(ticket)
                }
            default:
                let actual = flow.commit(flow.snapshot().authenticationChanged())
                compare(actual, oracle.commit(try oracle.prepare(.authentication)))
            }
            #expect(flow.snapshot().ordinal == oracle.snapshot.stamp.revision)
            #expect(root(flow.snapshot()) == oracle.snapshot.root)
        }
        let receipt = flow.close()
        let final = oracle.close()
        #expect(receipt.ordinal == final.stamp.revision)
        #expect(receipt.snapshot.isClosed == final.closed)
        #expect(
            flow.drainCommands(limit: 256).map(\.receipt.ordinal)
                == oracle.drain(limit: 256).map { $0.snapshot.stamp.revision }
        )
    }
}
