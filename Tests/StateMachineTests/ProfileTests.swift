import Foundation
import StateMachine
import StateMachineExamples
import Testing
import os

@Suite struct ProfileTests {
    typealias Flow = ReferenceProfile
    func inputs() throws -> (UserID, ProfileRequest) {
        let id = try UserID("kyle")
        return (id, try ProfileRequest(userID: id))
    }

    @Test func validatedDecoding() throws {
        #expect(throws: UserID.ValidationFailure.self) { try UserID(" ") }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(UserID.self, from: Data("\"bad id\"".utf8)) }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ProfileRequest.self, from: Data("{\"userID\":\"kyle\",\"attempts\":0}".utf8))
        }
    }

    @Test func ownedPreservesCompleteSuccessAndRecovery_RT037() throws {
        let (id, request) = try inputs()
        let owner = Flow.owned(.init(userID: id))
        let result = owner.load(try ProfileRequest(userID: UserID("other")))
        switch consume result {
        case .rejected(.wrongUser, let recovered):
            let success = recovered.load(request)
            switch consume success {
            case .advanced(let loading, let effects):
                #expect(effects == [.fetch(request)])
                #expect(loading.withValue { $0.request } == request)
                let received = loading.received(Profile(userID: id, name: "Kyle"))
                #expect(received.effects.isEmpty)
                #expect(received.next.withValue { $0.profile.name } == "Kyle")
            case .rejected: Issue.record("Valid request rejected")
            }
        case .advanced: Issue.record("Invalid request accepted")
        }
    }

    @Test(arguments: [10, Int.max]) func valueSuccessPreservesTwoEffects_RT037(value: Int) {
        let owner = ValueWorkflow.start(.init(value: value))
        let result = owner.finish(label: "complete")
        #expect(result.next.withValue { $0.value } == value)
        #expect(result.next.withValue { $0.label } == "complete")
        #expect(result.effects == [.audit(value), .publish("complete")])
    }

    @Test func resourceRecoveryAndDisposal_RT009_RT037() {
        let count = OSAllocatedUnfairLock(initialState: [Int]())
        do {
            let resource = ResourceWorkflow.Resource(identifier: 7) { id in count.withLock { $0.append(id) } }
            let owner = ResourceWorkflow.start(resource)
            let rejected = owner.finish(label: "")
            switch consume rejected {
            case .rejected(.emptyLabel, let recovered):
                #expect(recovered.withValue { $0.identifier } == 7)
                let accepted = recovered.finish(label: "done")
                switch consume accepted {
                case .advanced(let finished, let effects):
                    #expect(finished.withValue { $0.identifier } == 7)
                    #expect(finished.withValue { $0.label } == "done")
                    #expect(effects == [.audit(7), .publish("done")])
                    #expect(count.withLock { $0 }.isEmpty)
                case .rejected: Issue.record("Valid finish rejected")
                }
            case .advanced: Issue.record("Empty label accepted")
            }
        }
        #expect(count.withLock { $0 } == [7])
        do {
            let resource = ResourceWorkflow.Resource(identifier: 8) { id in count.withLock { $0.append(id) } }
            let unused = ResourceWorkflow.start(resource)
            #expect(unused.withValue { $0.identifier } == 8)
        }
        #expect(count.withLock { $0 } == [7, 8])
    }

    @Test func preparedIsInertAndOnlyAcceptedWorkIsIssued_RT010() throws {
        let (id, request) = try inputs()
        var local = Flow.Local(.init(userID: id))
        guard case .idle(let observed) = local.snapshot() else {
            Issue.record("Wrong initial phase")
            return
        }
        do {
            let abandoned = try observed.load(request)
            _ = consume abandoned
        }
        #expect(local.drainCommands(limit: 10).isEmpty)
        let winner = try observed.load(request)
        let loser = try observed.load(request)
        let accepted = local.commit(winner)
        guard case .committed(let receipt) = accepted else {
            Issue.record("Commit rejected")
            return
        }
        #expect(receipt.revision == 1)
        let rejected = local.commit(loser)
        guard case .rejected(.conflict, _) = rejected else {
            Issue.record("Missing conflict")
            return
        }
        let batches = local.drainCommands(limit: 10)
        #expect(batches.count == 1)
        #expect(batches[0].commands.count == 1)
        guard case .start(let work) = batches[0].commands[0] else {
            Issue.record("Missing work")
            return
        }
        #expect(work.input == request)
    }

    @Test func completionPreservesPresentationAndRetiresAuthority() throws {
        let (id, request) = try inputs()
        var local = Flow.Local(.init(userID: id))
        guard case .idle(let idle) = local.snapshot() else { return }
        let started = local.commit(try idle.load(request))
        guard case .committed = started else {
            Issue.record("Start rejected")
            return
        }
        let batches = local.drainCommands(limit: 1)
        guard case .start(let work) = batches[0].commands[0] else { return }
        let presentation = local.commit(local.snapshot().presentationChanged("new"))
        guard case .committed = presentation else {
            Issue.record("Edit rejected")
            return
        }
        guard case .loading(let loading) = local.snapshot(),
            case .success(let completion) = work.succeeded(Profile(userID: id, name: "Kyle"))
        else { return }
        let candidate = try loading.received(completion)
        let duplicate = try loading.received(completion)
        let result = local.commit(candidate)
        guard case .committed(let receipt) = result else {
            Issue.record("Completion rejected")
            return
        }
        #expect(receipt.snapshot.presentation == "new")
        let rejected = local.commit(duplicate)
        guard case .rejected(.inactiveAuthority, _) = rejected else {
            Issue.record("Duplicate admitted")
            return
        }
        let closed = local.close()
        #expect(closed.snapshot.isClosed)
        _ = local.drainCommands(limit: 10)
        let beforeAcknowledgment = local.isQuiescent
        #expect(!beforeAcknowledgment)
        #expect(local.acknowledgeExecution(work.execution, disposition: .terminated) == .recorded)
        #expect(local.acknowledgeExecution(work.execution, disposition: .terminated) == .duplicate)
        let quiescent = local.isQuiescent
        #expect(quiescent)
    }

    @Test func cancellationBeforeDrainSkipsWorkAndCloseHasReservedSlot() throws {
        let (id, request) = try inputs()
        var local = Flow.Local(.init(userID: id), configuration: try .init(commitCapacity: 1))
        guard case .idle(let idle) = local.snapshot() else { return }
        let result = local.commit(try idle.load(request))
        guard case .committed = result else {
            Issue.record("Start rejected")
            return
        }
        let close = local.close()
        let repeated = local.close()
        #expect(close.revision == repeated.revision)
        let batches = local.drainCommands(limit: 10)
        #expect(batches.map(\.receipt.revision) == [1, 2])
        #expect(batches[0].commands.isEmpty)
        #expect(batches[1].terminal)
        let quiescent = local.isQuiescent
        #expect(quiescent)
    }

    @Test func resetAndForkHaveFreshAuthority() throws {
        let (id, _) = try inputs()
        var local = Flow.Local(.init(userID: id))
        let old = local.snapshot()
        let archive = try Flow.Archive(model: old.model)
        let result = local.reset(archive, expected: old)
        guard case .committed(let receipt) = result else {
            Issue.record("Reset rejected")
            return
        }
        #expect(receipt.revision == 1)
        let stale = local.commit(old.presentationChanged("stale"))
        guard case .rejected(.obsoleteIncarnation, _) = stale else {
            Issue.record("Old incarnation admitted")
            return
        }
        var fork = try local.fork()
        let foreign = fork.commit(local.snapshot().presentationChanged("foreign"))
        guard case .rejected(.foreignOwner, _) = foreign else {
            Issue.record("Foreign admitted")
            return
        }
        #expect(fork.snapshot().revision == 0)
    }

    @Test func isolatedSnapshotIsIndependentValue() throws {
        var local = IsolatedNote.Local(.init(text: "before"))
        let observed = local.snapshot()
        guard case .committed = try local.replaceText("after") else {
            Issue.record("Text replacement rejected")
            return
        }
        #expect(observed.value.text == "before")
        #expect(local.snapshot().value.text == "after")
        let owned = IsolatedNote.owned(.init(text: "saved"))
        let result = owned.save()
        #expect(result.next.withValue { $0.text } == "saved")
        #expect(result.effects.isEmpty)
    }

    @Test func isolatedTextReplacementReportsAdmissionFailure() throws {
        var local = IsolatedNote.Local(.init(text: "before", tags: ["retained"]), configuration: try .init(commits: 1))
        guard case .committed(let first) = try local.replaceText("first") else {
            Issue.record("First replacement rejected")
            return
        }
        #expect(first.revision == 1)
        guard case .rejected(.capacityExceeded, let current) = try local.replaceText("second") else {
            Issue.record("Full queue did not report capacity rejection")
            return
        }
        #expect(current.revision == 1)
        #expect(current.value.text == "first")
        #expect(local.snapshot().value.tags == ["retained"])
        #expect(local.drainCommands(limit: 1).count == 1)
        guard case .committed(let second) = try local.replaceText("second") else {
            Issue.record("Replacement rejected after draining")
            return
        }
        #expect(second.revision == 2)
        #expect(second.snapshot.value.text == "second")
        #expect(second.snapshot.value.tags == ["retained"])
        _ = local.close()
        guard case .rejected(.closed, let closed) = try local.replaceText("third") else {
            Issue.record("Closed owner did not report rejection")
            return
        }
        #expect(closed.isClosed)
        #expect(closed.value.text == "second")
        _ = local.drainCommands(limit: 2)
        let quiescent = local.isQuiescent
        #expect(quiescent)
    }
}
