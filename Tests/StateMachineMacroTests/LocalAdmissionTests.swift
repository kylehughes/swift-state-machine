import StateMachine
import StateMachineExamples
import Testing

/// A `Local` owner admits a retained completion only when its caller asks.
@Suite struct LocalAdmissionTests {
    private struct Waiting: ~Copyable {
        var machine: GeneratedProfile.Local
        let pending: GeneratedProfile.PendingCompletionID
        let profile: Profile
    }

    /// A one-batch queue holds the audit start, so the fetch completion waits for capacity at revision 2.
    private func waiting() throws -> Waiting {
        let user = try UserID("taylor")
        let request = try ProfileRequest(userID: user)
        let profile = Profile(userID: user, name: "Taylor")
        var machine = GeneratedProfile.Local(.init(userID: user), configuration: try .init(commits: 1))
        try machine.send(.load(request))
        guard case .fetch(let work)? = machine.drainCommands(limit: 1).first?.commands.first else {
            throw Unexpected()
        }
        try machine.send(.audit("trace"))
        guard case .pending(let id, .waitingForCapacity) = machine.deliver(work.succeeded(profile)) else {
            throw Unexpected()
        }
        return Waiting(machine: machine, pending: id, profile: profile)
    }
    private struct Unexpected: Error {}

    @Test func drainingDoesNotAdmitARetainedCompletion() throws {
        var state = try waiting()
        let batches = state.machine.drainCommands(limit: 1)
        #expect(batches.map(\.receipt.revision) == [2])
        #expect(state.machine.snapshot().revision == 2)
        guard case .loading = state.machine.snapshot() else {
            Issue.record("draining advanced the model")
            return
        }
        #expect(state.machine.pendingCompletions().map(\.status) == [.waitingForCapacity])
    }

    @Test func acknowledgingDoesNotAdmitARetainedCompletion() throws {
        var state = try waiting()
        guard case .audit(let audit)? = state.machine.drainCommands(limit: 1).first?.commands.first else {
            throw Unexpected()
        }
        #expect(state.machine.acknowledgeExecution(audit.execution, disposition: .terminated) == .recorded)
        #expect(state.machine.snapshot().revision == 2)
        #expect(state.machine.pendingCompletions().map(\.status) == [.waitingForCapacity])
    }

    @Test func retryingAdmissionCommitsTheRetainedCandidateOnceCapacityIsFree() throws {
        var state = try waiting()
        // The queue is still full, so the retained candidate keeps waiting.
        guard case .pending(_, .waitingForCapacity) = state.machine.retryAdmission(id: state.pending) else {
            Issue.record("a full queue admitted the candidate")
            return
        }
        _ = state.machine.drainCommands(limit: 1)
        guard case .committed(let receipt) = state.machine.retryAdmission(id: state.pending) else {
            Issue.record("the retained candidate was not admitted")
            return
        }
        #expect(receipt.revision == 3)
        guard case .loaded(let loaded) = state.machine.snapshot() else {
            Issue.record("the model did not reach loaded")
            return
        }
        #expect(loaded.value.profile == state.profile)
        guard case .notPending = state.machine.retryAdmission(id: state.pending) else {
            Issue.record("a settled completion was still pending")
            return
        }
    }
}
