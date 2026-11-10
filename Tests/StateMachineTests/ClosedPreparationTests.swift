import StateMachine
import StateMachineExamples
import Testing

@Suite struct ClosedPreparationTests {
    private enum Phase: CaseIterable, Sendable { case idle, loading, loaded, failed }
    private enum Failure: Error { case unexpected }

    @Test(arguments: Phase.allCases)
    private func startsOnClosedSnapshotsRejectAndHistoricalSnapshotsRemainReadable(phase: Phase) throws {
        let user = try UserID("kyle")
        let request = try ProfileRequest(userID: user)
        var owner = ReferenceProfile.Local(.init(userID: user))
        var execution: ReferenceProfile.ExecutionHandle?
        if phase != .idle {
            guard case .idle(let idle) = owner.snapshot(),
                case .committed = owner.commit(try idle.load(request)),
                case .start(let work) = owner.drainCommands(limit: 1).first?.commands.first
            else { throw Failure.unexpected }
            execution = work.execution
            switch phase {
            case .loaded:
                guard case .committed = owner.deliver(.fetch(work.succeeded(.init(userID: user, name: "Readable"))))
                else { throw Failure.unexpected }
                _ = owner.acknowledgeExecution(work.execution, disposition: .terminated)
                execution = nil
            case .failed:
                guard case .committed = owner.deliver(.fetch(work.failed(.unavailable))) else {
                    throw Failure.unexpected
                }
                _ = owner.acknowledgeExecution(work.execution, disposition: .terminated)
                execution = nil
            case .idle, .loading: break
            }
            _ = owner.drainCommands(limit: 20)
        }
        let historical = owner.snapshot()
        let closed = owner.close().snapshot
        #expect(closed.isClosed)
        #expect(!historical.isClosed)
        #expect(closed.model == historical.model)
        #expect(closed.revision == historical.revision + 1)

        switch (phase, historical, closed) {
        case (.idle, .idle(let original), .idle(let ended)):
            #expect(ended.value.userID == user)
            do {
                _ = try ended.load(request)
                Issue.record("Closed load unexpectedly prepared")
            } catch { guard case .plan(.invalidPlan) = error else { throw Failure.unexpected } }
            guard case .rejected(.closed, _) = owner.commit(try original.load(request)) else {
                throw Failure.unexpected
            }
        case (.loading, .loading(let original), .loading(let ended)):
            #expect(ended.value.request == request)
            do {
                _ = try ended.audit("closed")
                Issue.record("Closed audit unexpectedly prepared")
            } catch { guard case .plan(.invalidPlan) = error else { throw Failure.unexpected } }
            guard case .rejected(.closed, _) = owner.commit(try original.audit("historical")) else {
                throw Failure.unexpected
            }
        case (.loaded, .loaded(let original), .loaded(let ended)):
            #expect(ended.value.profile.name == "Readable")
            do {
                _ = try ended.refresh(request)
                Issue.record("Closed refresh unexpectedly prepared")
            } catch { guard case .plan(.invalidPlan) = error else { throw Failure.unexpected } }
            guard case .rejected(.closed, _) = owner.commit(try original.refresh(request)) else {
                throw Failure.unexpected
            }
        case (.failed, .failed(let original), .failed(let ended)):
            #expect(ended.value.failure == .unavailable)
            do {
                _ = try ended.retry()
                Issue.record("Closed retry unexpectedly prepared")
            } catch { guard case .plan(.invalidPlan) = error else { throw Failure.unexpected } }
            guard case .rejected(.closed, _) = owner.commit(try original.retry()) else { throw Failure.unexpected }
        default: throw Failure.unexpected
        }
        if let execution { _ = owner.acknowledgeExecution(execution, disposition: .skippedBeforeStart) }
        let batches = owner.drainCommands(limit: 20)
        #expect(batches.count == 1)
        #expect(batches.first?.terminal == true)
        #expect(
            batches.allSatisfy { batch in
                batch.commands.allSatisfy { command in
                    switch command {
                    case .cancel: true
                    case .start, .audit: false
                    }
                }
            }
        )
        let quiescent = owner.isQuiescent
        #expect(quiescent)
    }
}
