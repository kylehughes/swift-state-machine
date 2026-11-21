import Dispatch
import Foundation
import StateMachine
import StateMachineExamples
import Testing
import os

@testable import StateMachineReferenceModel

/// Finite production evidence.
///
/// Neither these bounds nor the witness search prove
/// universal linearizability, scheduler fairness, or durable effect execution.
@Suite(.serialized, .parksCooperativeThread) struct ProductionHistoryTests {
    private typealias Flow = ReferenceProfile

    private static func root(_ snapshot: Flow.Snapshot) -> ReferenceRoot {
        let phase: ReferencePhase
        switch snapshot.model {
        case .idle: phase = .idle(1)
        case .loading: phase = .loading(1)
        case .loaded(let loaded): phase = .loaded(Int(loaded.profile.name) ?? 0)
        case .failed: phase = .failed(request: 1, failure: 1)
        }
        return .init(phase, presentation: Int(snapshot.presentation) ?? 0)
    }

    // Public facade snapshots seal owner/incarnation identities. Normalize those
    // abstract symbols; foreign/obsolete admission traces test their behavior.
    private static func snapshot(_ actual: Flow.Snapshot, like expected: ReferenceSnapshot) -> ReferenceSnapshot {
        .init(
            stamp: .init(
                owner: expected.stamp.owner,
                incarnation: expected.stamp.incarnation,
                revision: actual.revision
            ),
            root: root(actual),
            closed: actual.isClosed
        )
    }

    private static func rejection(_ reason: Flow.CommitRejection) -> ReferenceRejection {
        switch reason {
        case .plan(.invalidPlan): .invalidPlan
        case .plan(.planTooLarge): .planTooLarge
        case .foreignOwner: .foreignOwner
        case .closed: .closed
        case .obsoleteIncarnation: .obsoleteIncarnation
        case .inactiveAuthority: .inactiveAuthority
        case .conflict: .conflict
        case .operationPolicy(.alreadyActive): .alreadyActive
        case .operationPolicy(.parallelLimit): .parallelLimit
        case .revisionExhausted: .revisionExhausted
        case .capacityExceeded(.commitQueue): .commitQueue
        case .capacityExceeded(.executionReservations): .executionReservations
        }
    }

    private static func admission(_ actual: Flow.CommitResult, like expected: ReferenceSnapshot) -> ReferenceAdmission {
        switch actual {
        case .committed(let receipt): .committed(snapshot(receipt.snapshot, like: expected))
        case .rejected(let reason, _): .rejected(rejection(reason))
        }
    }

    private static func compare(
        _ actual: Flow.CommitResult,
        _ expected: ReferenceAdmission,
        current: ReferenceSnapshot,
        context: String
    ) {
        #expect(admission(actual, like: current) == expected, "\(context)")
        if case .rejected(_, let observed) = actual {
            #expect(snapshot(observed, like: current) == current, "\(context): rejection changed observation")
        }
    }

    private static func compare(_ actual: Flow.DeliveryResult, _ expected: ReferenceDelivery, context: String) {
        switch (actual, expected) {
        case (.committed(let receipt), .committed(let snapshot)):
            #expect(Self.snapshot(receipt.snapshot, like: snapshot) == snapshot, "\(context)")
        case (.pending(_, let status), .pending(_, let expectedStatus)):
            #expect(ReferencePendingStatus(status) == expectedStatus, "\(context)")
        case (.stale, .discarded(.inactiveAuthority)), (.stale, .discarded(.closed)): break
        default: Issue.record("\(context): production and independent interpreter disagree on delivery")
        }
    }

    /// Optional external receipts keep invocation/response data and replay commands out of the package.
    ///
    /// The test assertions do not depend on file output.
    private static func evidence(_ name: String, _ value: [String: Any]) throws {
        guard let directory = ProcessInfo.processInfo.environment["STATE_MACHINE_HISTORY_EVIDENCE"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".json"), options: .atomic)
    }

    @Test(.timeLimit(.minutes(1)), arguments: 0 ..< 32)
    func completeVocabularyProductionTrace_RT034(seed: Int) async throws {
        let id = try UserID("kyle")
        let request = try ProfileRequest(userID: id)
        let wrong = try ProfileRequest(userID: UserID("another"))
        let configuration = try Flow.Configuration(commitCapacity: 256, executionCapacity: 256)
        let flow = Flow.Shared(.init(userID: id), configuration: configuration)
        var oracle = SequentialReference(owner: 1)
        var saved = flow.snapshot()
        var savedOracle = oracle.snapshot
        var loading = flow.snapshot()
        var prepared: Flow.Prepared?
        var candidate: ReferenceCandidate?
        var issued: [(Flow.FetchWork, ReferenceTicket)] = []
        var commands: [String] = []
        var published: [UInt64: ReferenceSnapshot] = [0: oracle.snapshot]
        var random = UInt64(seed)
        let (observations, continuation) = AsyncStream<Flow.Snapshot>.makeStream()
        let subscription = try flow.subscribe {
            continuation.yield($0)
        } onFinish: {
            continuation.finish()
        }
        defer { subscription.cancel() }

        func drain() {
            let actual = flow.drainCommands(limit: 256)
            let expected = oracle.drain(limit: 256)
            #expect(actual.count == expected.count)
            for (batch, reference) in zip(actual, expected) {
                #expect(Self.snapshot(batch.receipt.snapshot, like: reference.snapshot) == reference.snapshot)
                #expect(batch.terminal == reference.terminal)
                var starts: [Flow.FetchWork] = []
                var cancels = 0
                for command in batch.commands {
                    switch command {
                    case .start(let work): starts.append(work)
                    case .cancel: cancels += 1
                    default: Issue.record("Fetch-only history emitted a different operation")
                    }
                }
                let tickets = reference.starts.filter { oracle.valid($0) }
                #expect(starts.count == tickets.count)
                #expect(cancels == reference.cancelled.count)
                let actualCancellations = batch.commands.compactMap { command -> Flow.ExecutionHandle? in
                    if case .cancel(let handle) = command { return handle }
                    return nil
                }
                let expectedCancellations = reference.cancelled.compactMap { operation in
                    issued.first { $0.1.operation == operation }?.0.execution
                }
                #expect(actualCancellations == expectedCancellations)
                #expect(
                    batch.commands.map { command in
                        switch command {
                        case .cancel: "cancel"
                        case .start: "start"
                        default: "unexpected"
                        }
                    } == Array(repeating: "cancel", count: reference.cancelled.count)
                        + Array(repeating: "start", count: tickets.count)
                )
                for (work, ticket) in zip(starts, tickets) {
                    #expect(work.input == request)
                    #expect(flow.isExecutionAuthorized(work.execution) == oracle.valid(ticket))
                    issued.append((work, ticket))
                }
            }
        }

        for step in 0 ..< 100 {
            random = random &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let value = Int((random >> 16) % 10_000) + 1
            let context = "seed=\(seed) step=\(step)"
            let slot = step % 25
            commands.append("\(step):\(Self.traceVocabulary[slot]) value=\(value)")
            switch slot {
            case 0:
                saved = flow.snapshot()
                savedOracle = oracle.snapshot
            case 1:
                prepared = saved.presentationChanged(String(value))
                candidate = try oracle.prepare(.presentation(value), on: savedOracle)
            case 2:
                let expected = oracle.commit(try oracle.prepare(.presentation(value)))
                Self.compare(
                    flow.commit(flow.snapshot().presentationChanged(String(value))),
                    expected,
                    current: oracle.snapshot,
                    context: context
                )
            case 3:
                if let proposal = prepared.take(), let reference = candidate {
                    let expected = oracle.commit(reference)
                    Self.compare(flow.commit(proposal), expected, current: oracle.snapshot, context: context)
                } else {
                    Issue.record("Missing prepared stale candidate")
                }
            case 4:
                // Wrong-user validation is a real pure-domain rejection; no proposal
                // or effect is admitted, and the interpreter independently rejects.
                if case .idle(let idle) = flow.snapshot() {
                    do {
                        _ = try idle.load(wrong)
                        Issue.record("Wrong-user domain preparation accepted")
                    } catch {
                        if case .wrongUser = error {
                        } else {
                            Issue.record("Wrong domain preparation rejection")
                        }
                    }
                    #expect(throws: ReferenceRejection.domain) { try oracle.prepare(.load(-1)) }
                } else {
                    Issue.record("Cycle did not return to idle")
                }
            case 5, 15:
                if case .idle(let idle) = flow.snapshot() {
                    let expected = oracle.commit(try oracle.prepare(.load(1)))
                    Self.compare(
                        flow.commit(try idle.load(request)),
                        expected,
                        current: oracle.snapshot,
                        context: context
                    )
                } else {
                    Issue.record("Expected idle load")
                }
            case 6, 16, 20: drain()
            case 7:
                loading = flow.snapshot()
                if (step / 25) % 2 == 1 {
                    commands[commands.count - 1] += " authenticationInvalidationWhileActive"
                    let expected = oracle.commit(try oracle.prepare(.authentication))
                    Self.compare(
                        flow.commit(loading.authenticationChanged()),
                        expected,
                        current: oracle.snapshot,
                        context: context
                    )
                }
            case 8:
                // Outcomes reach the model only through delivery, which prepares on the current root.
                let (work, ticket) = try #require(issued.last)
                guard case .loading = loading else {
                    Issue.record("Missing loading observation")
                    return
                }
                let expected: ReferenceDelivery
                let actual: Flow.DeliveryResult
                if seed % 2 == 0 {
                    expected = oracle.deliver(ticket, outcome: .success(value))
                    actual = flow.deliver(.fetch(work.succeeded(Profile(userID: id, name: String(value)))))
                } else {
                    expected = oracle.deliver(ticket, outcome: .failure(1))
                    actual = flow.deliver(.fetch(work.failed(.unavailable)))
                }
                Self.compare(actual, expected, context: context)
            case 9, 18:
                // A later outcome for settled or revoked work is refused.
                let (work, ticket) = try #require(issued.last)
                let expected = oracle.deliver(ticket, outcome: .success(2))
                Self.compare(
                    flow.deliver(.fetch(work.succeeded(Profile(userID: id, name: "2")))),
                    expected,
                    context: context
                )
            case 10, 19:
                for (work, ticket) in issued {
                    _ = flow.acknowledgeExecution(work.execution, disposition: .terminated)
                    oracle.acknowledge(ticket)
                    #expect(flow.isExecutionAuthorized(work.execution) == oracle.valid(ticket))
                }
            case 11:
                let expected = oracle.commit(try oracle.prepare(.authentication))
                Self.compare(
                    flow.commit(flow.snapshot().authenticationChanged()),
                    expected,
                    current: oracle.snapshot,
                    context: context
                )
            case 12:
                saved = flow.snapshot()
                savedOracle = oracle.snapshot
                let archive = try Flow.Archive(model: .idle(.init(userID: id)))
                let expected = oracle.commit(try oracle.prepareReset(.init()))
                Self.compare(flow.reset(archive, expected: saved), expected, current: oracle.snapshot, context: context)
            case 13:
                let expected = oracle.commit(try oracle.prepare(.presentation(value), on: savedOracle))
                Self.compare(
                    flow.commit(saved.presentationChanged(String(value))),
                    expected,
                    current: oracle.snapshot,
                    context: context
                )
            case 14:
                let foreign = Flow.Shared(.init(userID: id))
                let foreignOracle = SequentialReference(owner: 999)
                let expected = oracle.commit(try foreignOracle.prepare(.presentation(value)))
                Self.compare(
                    flow.commit(foreign.snapshot().presentationChanged(String(value))),
                    expected,
                    current: oracle.snapshot,
                    context: context
                )
                _ = foreign.close()
            case 17:
                loading = flow.snapshot()
                guard case .loading(let observed) = loading else {
                    Issue.record("Missing cancellable loading")
                    return
                }
                let expected = oracle.commit(try oracle.prepare(.cancel))
                Self.compare(flow.commit(observed.cancel()), expected, current: oracle.snapshot, context: context)
            case 21:
                let fork = try flow.fork()
                var forkOracle = try oracle.fork(owner: UInt64(100 + step))
                #expect(Self.snapshot(fork.snapshot(), like: forkOracle.snapshot) == forkOracle.snapshot)
                let expected = forkOracle.commit(try oracle.prepare(.presentation(value)))
                Self.compare(
                    fork.commit(flow.snapshot().presentationChanged(String(value))),
                    expected,
                    current: forkOracle.snapshot,
                    context: context
                )
                _ = fork.close()
            case 22:
                let restored = Flow.Shared.restore(
                    try .init(model: flow.snapshot().model, presentation: flow.snapshot().presentation)
                )
                let restoredOracle = try SequentialReference.restore(owner: UInt64(200 + step), root: oracle.root)
                #expect(Self.snapshot(restored.snapshot(), like: restoredOracle.snapshot) == restoredOracle.snapshot)
                var check = restoredOracle
                let expected = check.commit(try oracle.prepare(.presentation(value)))
                Self.compare(
                    restored.commit(flow.snapshot().presentationChanged(String(value))),
                    expected,
                    current: check.snapshot,
                    context: context
                )
                _ = restored.close()
            case 23:
                let transient = try flow.subscribe { _ in }
                transient.cancel()
            default:
                if step == 99 {
                    let final = oracle.close()
                    #expect(Self.snapshot(flow.close().snapshot, like: final) == final)
                }
                drain()
            }
            #expect(Self.snapshot(flow.snapshot(), like: oracle.snapshot) == oracle.snapshot, "\(context)")
            #expect(Self.snapshot(saved, like: savedOracle) == savedOracle, "\(context): historical snapshot changed")
            published[oracle.snapshot.stamp.revision] = oracle.snapshot
            for (work, ticket) in issued {
                #expect(
                    flow.isExecutionAuthorized(work.execution) == oracle.valid(ticket),
                    "\(context): live authority"
                )
            }
        }
        var delivered: [Flow.Snapshot] = []
        for await observed in observations { delivered.append(observed) }
        for observed in delivered {
            let expected = try #require(published[observed.revision])
            #expect(Self.snapshot(observed, like: expected) == expected)
        }
        #expect(delivered.last?.isClosed == true)
        #expect(delivered.last?.revision == oracle.snapshot.stamp.revision)
        #expect(zip(delivered, delivered.dropFirst()).allSatisfy { $0.revision < $1.revision })
        #expect(delivered.allSatisfy { $0.revision <= oracle.snapshot.stamp.revision })
        try Self.evidence(
            "seed-\(seed)",
            [
                "seed": seed, "steps": commands, "observedRevisions": delivered.map(\.revision),
                "finalRevision": oracle.snapshot.stamp.revision,
            ]
        )
    }

    private static let traceVocabulary = [
        "snapshot", "prepare", "legalCommit", "staleCommit", "domainRejectedPreparation", "start",
        "drain", "retainLoadingObservation", "terminalCompletion", "duplicateCompletion", "acknowledge",
        "scopeAuthentication", "reset", "obsoleteCommit", "foreignCommit", "start", "drain",
        "cancel", "duplicateCancelledCompletion", "acknowledge", "drain", "fork", "restore",
        "subscribeUnsubscribe", "drainOrClose",
    ]
}

extension ProductionHistoryTests {
    private final class HistoryRecorder: Sendable {
        struct State: Sendable {
            var tick = 0
            var calls: [ReferenceHistoryCall] = []
            var preparations: [String] = []
        }
        let state = OSAllocatedUnfairLock(initialState: State())
        func event() -> Int {
            state.withLock { state in
                state.tick += 1
                return state.tick
            }
        }
        func prepared(slot: Int) {
            state.withLock { state in
                state.tick += 1
                state.preparations.append("slot=\(slot) event=\(state.tick)")
            }
        }
        var preparations: [String] { state.withLock { $0.preparations } }
        func response(client: Int, invocation: Int, response: Int, command: ReferenceCommand, result: ReferenceResponse)
        {
            state.withLock { state in
                state.calls.append(
                    .init(
                        client: client,
                        invocation: invocation,
                        response: response,
                        command: command,
                        result: result
                    )
                )
            }
        }
        var calls: [ReferenceHistoryCall] { state.withLock { $0.calls.sorted { $0.invocation < $1.invocation } } }
    }

    // Dispatch worker coordination is synchronous and bounded; the async test
    // awaits managed shutdown only after every worker has responded.
    //
    // Each client records its invocation, then waits at a rendezvous until both clients have recorded
    // theirs, and only then calls the facade and records the response. Both invocations therefore
    // precede both responses, so the wave's two calls overlap in every schedule and on every machine,
    // however loaded: their intervals overlap by construction, and the two calls then run against the
    // production implementation concurrently, in whatever order the threads reach it.
    private static func runWave(
        _ wave: Int,
        schedule: Int,
        flow: Flow.Shared,
        initial: Flow.Snapshot,
        template: ReferenceSnapshot,
        recorder: HistoryRecorder
    ) {
        let ready = DispatchSemaphore(value: 0)
        let invoked = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let permits = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
        let calls = [DispatchSemaphore(value: 0), DispatchSemaphore(value: 0)]
        let first = (schedule >> (wave * 2)) & 1
        for client in [first, 1 - first] {
            DispatchQueue.global()
                .async {
                    var proposal: Flow.Prepared?
                    if client == 0 {
                        proposal =
                            wave == 0 ? initial.presentationChanged("1") : initial.authenticationChanged()
                        recorder.prepared(slot: wave)
                    }
                    ready.signal()
                    guard permits[client].wait(timeout: .now() + 10) == .success else {
                        Issue.record("Schedule permit timed out")
                        finished.signal()
                        return
                    }
                    // Recorded before the rendezvous, so each call's interval contains the other's
                    // invocation.
                    let invocation = recorder.event()
                    invoked.signal()
                    guard calls[client].wait(timeout: .now() + 10) == .success else {
                        Issue.record("Rendezvous timed out")
                        finished.signal()
                        return
                    }
                    if let prepared = proposal.take() {
                        let actual = flow.commit(prepared)
                        let response = recorder.event()
                        recorder.response(
                            client: client,
                            invocation: invocation,
                            response: response,
                            command: .commit(wave),
                            result: .admission(Self.admission(actual, like: template))
                        )
                    } else {
                        let actual = flow.snapshot()
                        let response = recorder.event()
                        recorder.response(
                            client: client,
                            invocation: invocation,
                            response: response,
                            command: .snapshot(wave),
                            result: .snapshot(Self.snapshot(actual, like: template))
                        )
                    }
                    finished.signal()
                }
        }
        #expect(ready.wait(timeout: .now() + 10) == .success)
        #expect(ready.wait(timeout: .now() + 10) == .success)
        let releaseFirst = (schedule >> (wave * 2 + 1)) & 1
        permits[releaseFirst].signal()
        permits[1 - releaseFirst].signal()
        // Both invocations are recorded before either call begins.
        #expect(invoked.wait(timeout: .now() + 10) == .success)
        #expect(invoked.wait(timeout: .now() + 10) == .success)
        calls[releaseFirst].signal()
        calls[1 - releaseFirst].signal()
        #expect(finished.wait(timeout: .now() + 10) == .success)
        #expect(finished.wait(timeout: .now() + 10) == .success)
    }

    @Test(.timeLimit(.minutes(1)), arguments: 0 ..< 16)
    func fourCallTwoClientProductionWitness_RT034(schedule: Int) async throws {
        // Two waves preserve each client's program order and establish real-time
        // edges from wave one to wave two. Four bits choose launch order and the
        // order in which the permits and the rendezvous release the clients in
        // each wave. The rendezvous makes the two calls of each wave overlap in
        // every attempt, so each attempt is a genuinely concurrent history of the
        // production facade, and every attempt must have a witness. The first is
        // retained as evidence.
        var selected: [ReferenceHistoryCall] = []
        var selectedAttempt = 0
        var selectedPreparations: [String] = []
        var attemptedHistories: [[String: Any]] = []
        var selectedInitial = ReferenceReplay(.init(owner: 1))
        for attempt in 0 ..< 8 {
            let id = try UserID("kyle")
            let flow = Flow.Shared(
                .init(userID: id),
                drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
            )
            let initial = flow.snapshot()
            let template = SequentialReference(owner: 1).snapshot
            var replay = ReferenceReplay(.init(owner: 1))
            #expect(replay.execute(.prepare(0, .presentation(1), observation: nil)) == .prepared)
            #expect(replay.execute(.prepare(1, .authentication, observation: nil)) == .prepared)
            let recorder = HistoryRecorder()
            for wave in 0 ..< 2 {
                Self.runWave(
                    wave,
                    schedule: schedule,
                    flow: flow,
                    initial: initial,
                    template: template,
                    recorder: recorder
                )
            }
            let calls = recorder.calls
            _ = flow.close()
            #expect(await flow.shutdown(deadline: ContinuousClock.now.advanced(by: .seconds(10))) == .quiescent)
            let overlap = calls.indices.contains { first in
                calls.indices.contains { second in
                    first < second && calls[first].client != calls[second].client
                        && calls[first].invocation < calls[second].response
                        && calls[second].invocation < calls[first].response
                }
            }
            let attemptVerdict = ReferenceHistoryChecker.check(calls, initial: replay)
            guard case .witness(let attemptWitness) = attemptVerdict else {
                let minimal = Self.minimize(calls, initial: replay)
                try Self.evidence(
                    "failure-schedule-\(schedule)",
                    [
                        "schedule": schedule, "attempt": attempt,
                        "calls": calls.map { String(reflecting: $0) },
                        "minimal": minimal.map { String(reflecting: $0) },
                    ]
                )
                Issue.record(
                    "No production witness: schedule=\(schedule) attempt=\(attempt) minimal=\(String(reflecting: minimal))"
                )
                return
            }
            attemptedHistories.append([
                "attempt": attempt, "overlap": overlap,
                "preparations": recorder.preparations, "witness": attemptWitness,
                "calls": calls.map {
                    [
                        "client": $0.client, "invocation": $0.invocation, "response": $0.response,
                        "command": String(reflecting: $0.command), "result": String(reflecting: $0.result),
                    ]
                },
            ])
            #expect(overlap, "The calls of attempt \(attempt) did not overlap, schedule=\(schedule)")
            if overlap, selected.isEmpty {
                selected = calls
                selectedAttempt = attempt
                selectedPreparations = recorder.preparations
                selectedInitial = replay
            }
        }
        #expect(selected.count == 4, "No overlapping production history, schedule=\(schedule)")
        guard selected.count == 4 else { return }
        let verdict = ReferenceHistoryChecker.check(selected, initial: selectedInitial)
        guard case .witness(let witness) = verdict else {
            try Self.evidence(
                "failure-schedule-\(schedule)",
                [
                    "schedule": schedule,
                    "calls": selected.map { String(reflecting: $0) },
                ]
            )
            // Four calls permit an exhaustive smallest failing subsequence search.
            // Keep initial prepared slots fixed while minimizing recorded calls.
            let minimal = Self.minimize(selected, initial: selectedInitial)
            Issue.record("No production witness: schedule=\(schedule), minimal=\(String(reflecting: minimal))")
            return
        }
        for first in selected.indices {
            for second in selected.indices where selected[first].response < selected[second].invocation {
                #expect(try #require(witness.firstIndex(of: first)) < #require(witness.firstIndex(of: second)))
            }
        }
        try Self.evidence(
            "schedule-\(schedule)",
            [
                "schedule": schedule, "attempt": selectedAttempt,
                "preparations": selectedPreparations,
                "attemptedHistories": attemptedHistories,
                "calls": selected.map {
                    [
                        "client": $0.client, "invocation": $0.invocation, "response": $0.response,
                        "command": String(reflecting: $0.command), "result": String(reflecting: $0.result),
                    ]
                },
                "witness": witness,
            ]
        )
    }

    private static func minimize(_ calls: [ReferenceHistoryCall], initial: ReferenceReplay) -> [ReferenceHistoryCall] {
        guard !calls.isEmpty else { return [] }
        for size in 1 ... calls.count {
            for mask in 1 ..< (1 << calls.count) where mask.nonzeroBitCount == size {
                let subset = calls.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? $0.element : nil }
                if ReferenceHistoryChecker.check(subset, initial: initial) == .noWitness { return subset }
            }
        }
        return calls
    }
}
