import Combine
import StateMachine
import StateMachineExamples
import StateMachineUI
import Testing

@testable import StateMachineReferenceModel

@MainActor private final class SnapshotTrace<Value> {
    private struct Waiter {
        let predicate: @MainActor (Value) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }
    private(set) var values: [Value] = []
    private var waiters: [Waiter] = []
    func record(_ value: Value) {
        values.append(value)
        let ready = waiters.filter { $0.predicate(value) }
        waiters.removeAll { $0.predicate(value) }
        for waiter in ready { waiter.continuation.resume() }
    }
    func wait(until predicate: @escaping @MainActor (Value) -> Bool) async -> Value {
        while true {
            if let value = values.last(where: { predicate($0) }) { return value }
            await withCheckedContinuation { waiters.append(Waiter(predicate: predicate, continuation: $0)) }
        }
    }
}

@MainActor private final class NoteStore {
    private struct Request {
        let id: Int
        let draft: IsolatedNote.Draft
        let continuation: CheckedContinuation<Result<String, IsolatedNote.SaveFailure>, Never>
    }
    private var entries: [Request] = []
    private var announced: [Int] = []
    private var listeners: [CheckedContinuation<Int, Never>] = []
    private var nextID = 0
    private var returns = 0
    private var returnWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancelledAtReturn = false
    var drivers: IsolatedNote.MainActorDrivers {
        .init { draft in
            let result = await self.save(draft)
            self.cancelledAtReturn = Task.isCancelled
            self.returns += 1
            let waiters = self.returnWaiters
            self.returnWaiters = []
            for waiter in waiters { waiter.resume() }
            switch result {
            case .success(let text): return .success(.init(text: text, tags: draft.tags))
            case .failure(let reason): return .failure(reason)
            }
        }
    }
    private func save(_ draft: IsolatedNote.Draft) async -> Result<String, IsolatedNote.SaveFailure> {
        await withCheckedContinuation { continuation in
            let id = nextID
            nextID += 1
            entries.append(Request(id: id, draft: draft, continuation: continuation))
            if listeners.isEmpty { announced.append(id) } else { listeners.removeFirst().resume(returning: id) }
        }
    }
    func nextRequest() async -> Int {
        if !announced.isEmpty { return announced.removeFirst() }
        return await withCheckedContinuation { listeners.append($0) }
    }
    @discardableResult func complete(_ id: Int, _ result: Result<String, IsolatedNote.SaveFailure>) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
        entries.remove(at: index).continuation.resume(returning: result)
        return true
    }
    func waitForReturn() async {
        if returns == 0 { await withCheckedContinuation { returnWaiters.append($0) } }
    }
}

@Suite(.timeLimit(.minutes(1))) struct ConfinedHostTests {
    private enum Failure: Error { case unexpected }

    @MainActor @Test func mainActorInitialObservationSkipsQueuedHistoryAndAllowsReentry_RT031() async throws {
        typealias Engine = RuntimeState<Int, Int>
        let owner = RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>(
            0,
            scopes: [],
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        for value in 1 ... 2 { _ = owner.commit(try Engine.prepare(on: owner.snapshot(), next: value)) }
        var revisions: [UInt64] = []
        var finishes = 0
        let token = try owner.subscribe(
            { snapshot in
                revisions.append(snapshot.revision)
                if snapshot.revision == 2 {
                    _ = owner.commit(try! Engine.prepare(on: owner.snapshot(), next: 3))
                }
            },
            onFinish: { finishes += 1 }
        )
        #expect(revisions == [2])
        let closed = owner.close()
        #expect(await owner.flush(through: closed))
        #expect(revisions == [2, 3, 4])
        #expect(finishes == 1 && owner.subscriberCount == 0)
        var terminal: [UInt64] = []
        var terminalFinishes = 0
        let closedToken = try owner.subscribe({ terminal.append($0.revision) }, onFinish: { terminalFinishes += 1 })
        #expect(await owner.flush(through: owner.close()))
        #expect(terminal == [4] && terminalFinishes == 1)
        token.cancel()
        closedToken.cancel()
        await owner.shutdown()
    }

    @MainActor @Test func preparationReentryRechecksFreshnessWithoutStoredInout_RT031() throws {
        typealias Engine = RuntimeState<Int, Int>
        let owner = RuntimeMainActorHost<Int, Int, RuntimeTicket, Never>(
            0,
            scopes: [],
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let result: Result<Engine.Admission, PlanRejection> = owner.prepareAndCommit { old in
            _ = owner.commit(try! Engine.prepare(on: owner.snapshot(), next: 10))
            return Result { () throws(PlanRejection) in try Engine.prepare(on: old, next: 20) }
        }
        guard case .success(.rejected(.conflict, let current)) = result else { throw Failure.unexpected }
        #expect(current.model == 10 && current.revision == 1)
        _ = owner.close()
    }

    @MainActor @Test func editorPublishesSameTurnThenFailureRetryAndDisposesWork_RT031_RT035() async throws {
        let user = try UserID("editor")
        let network = ControlledProfileNetwork()
        let driver = network.drivers
        let editor = try ProfileEditor(
            request: ProfileRequest(userID: user),
            drivers: .init(fetch: driver.fetch, audit: driver.audit)
        )
        let trace = SnapshotTrace<GeneratedProfile.Snapshot>()
        let observation = editor.presentation.presentedSnapshots.sink { trace.record($0) }
        defer { observation.cancel() }
        _ = try editor.load()
        guard case .loading = editor.presentation.snapshot else { throw Failure.unexpected }
        #expect(editor.presentation.snapshot.revision == 1)
        let first = await network.nextRequest()
        #expect(await network.complete(first.id, with: .failure(.unavailable)))
        let failure = await trace.wait { if case .failed = $0 { true } else { false } }
        #expect(failure.revision == 2)
        _ = try editor.retry()
        guard case .loading = editor.presentation.snapshot else { throw Failure.unexpected }
        let retry = await network.nextRequest()
        #expect(await network.complete(retry.id, with: .success(Profile(userID: user, name: "Saved"))))
        let loaded = await trace.wait { if case .loaded = $0 { true } else { false } }
        #expect(loaded.revision == 4)
        _ = try editor.refresh(ProfileRequest(userID: user, attempts: 2))
        let late = await network.nextRequest()
        editor.dispose()
        #expect(!editor.presentation.isObserving && editor.presentation.snapshot.isClosed)
        let disposed = editor.presentation.snapshot.revision
        #expect(await network.complete(late.id, with: .success(Profile(userID: user, name: "Too late"))))
        await editor.shutdown()
        #expect(editor.isQuiescent && editor.presentation.snapshot.revision == disposed)
        #expect(trace.values.map(\.revision) == trace.values.map(\.revision).sorted())
    }

    @MainActor @Test func rapidBackgroundIngressCoalescesAndNeverRegresses_RT031() async {
        let trace = SnapshotTrace<Int>()
        let ingress = MainActorSnapshotIngress<Int> { trace.record($0) }
        // No suspension until all offers are staged: one responsible task receives only the latest.
        for value in 0 ..< 10_000 { ingress.offer(value, revision: UInt64(value)) }
        ingress.offer(-1, revision: 1)
        let latest = await trace.wait { $0 == 9_999 }
        #expect(latest == 9_999 && trace.values == [9_999])
        ingress.cancel()
        ingress.offer(10_000, revision: 10_000)
        #expect(trace.values == [9_999])
    }

    @MainActor @Test func navigationReturnCreatesFreshHistoryAndDoesNotResurrectDisposedWork_RT035() async throws {
        let user = try UserID("navigation")
        let request = try ProfileRequest(userID: user)
        let network = ControlledProfileNetwork()
        let drivers = network.drivers
        let first = ProfileEditor(request: request, drivers: .init(fetch: drivers.fetch, audit: drivers.audit))
        _ = try first.load()
        let oldRequest = await network.nextRequest()
        first.dispose()
        #expect(await network.complete(oldRequest.id, with: .success(.init(userID: user, name: "Old screen"))))
        await first.shutdown()
        #expect(first.presentation.snapshot.isClosed && first.isQuiescent)

        let returned = ProfileEditor(request: request, drivers: .init(fetch: drivers.fetch, audit: drivers.audit))
        guard case .idle = returned.presentation.snapshot else { throw Failure.unexpected }
        #expect(returned.presentation.snapshot.revision == 0 && returned.presentation.isObserving)
        let trace = SnapshotTrace<GeneratedProfile.Snapshot>()
        let observation = returned.presentation.presentedSnapshots.sink { trace.record($0) }
        _ = try returned.load()
        let newRequest = await network.nextRequest()
        #expect(newRequest.id != oldRequest.id)
        #expect(await network.complete(newRequest.id, with: .success(.init(userID: user, name: "Returned screen"))))
        let loaded = await trace.wait { if case .loaded = $0 { true } else { false } }
        guard case .loaded(let value) = loaded else { throw Failure.unexpected }
        #expect(value.value.profile.name == "Returned screen" && loaded.revision == 2)
        observation.cancel()
        await returned.shutdown()
        #expect(returned.isQuiescent && first.presentation.snapshot.isClosed)
    }

    @MainActor @Test func isolatedOwnedLocalAndManagedHaveMatchingValues_RT032() async throws {
        let draft = IsolatedNote.Draft(text: "Value semantics", tags: ["draft", "local"])
        let owned = IsolatedNote.owned(draft).save()
        let expected = owned.next.withValue { ($0.text, $0.tags) }
        var local = IsolatedNote.Local(draft)
        guard case .committed = try local.send(.save) else { throw Failure.unexpected }
        #expect(local.drainCommands(limit: 0).isEmpty && local.drainCommands(limit: -1).isEmpty)
        let batches = local.drainCommands(limit: 1)
        guard batches.count == 1, case .save(let work) = batches[0].commands.last else { throw Failure.unexpected }
        // Work is an owned copy, and Local's mutable access has ended before execution.
        let outcome = work.succeeded(.init(text: work.input.text, tags: work.input.tags))
        guard case .committed = local.deliver(outcome) else { throw Failure.unexpected }
        #expect(local.acknowledgeExecution(work.execution, disposition: .terminated) == .recorded)
        #expect(local.acknowledgeExecution(work.execution, disposition: .terminated) == .duplicate)
        #expect(local.snapshot().value.text == expected.0 && local.snapshot().value.tags == expected.1)
        _ = local.close()
        _ = local.drainCommands(limit: 100)
        let localIsQuiescent = local.isQuiescent
        #expect(localIsQuiescent)

        let owner = IsolatedNote.MainActorHost(
            draft,
            drivers: .init(save: { .success(.init(text: $0.text, tags: $0.tags)) })
        )
        let trace = SnapshotTrace<IsolatedNote.Snapshot>()
        let token = try owner.subscribe { trace.record($0) }
        _ = try owner.send(.save)
        let saved = await trace.wait { if case .saved = $0 { true } else { false } }
        #expect(saved.value.text == expected.0 && saved.value.tags == expected.1)
        token.cancel()
        await owner.shutdown()
        #expect(owner.runningCount == 0 && owner.isQuiescent)
    }

    @MainActor @Test func isolatedReentryRevokesOldSaveButRetainsCancelledHandleUntilJoin_RT032() async throws {
        let store = NoteStore()
        let owner = IsolatedNote.MainActorHost(.init(text: "First"), drivers: store.drivers)
        _ = try owner.send(.save)
        let first = await store.nextRequest()
        _ = try owner.send(.edit(.init(text: "Second", tags: ["replacement"])))
        let receipt = owner.close()
        #expect(await owner.flush(through: receipt) == .processed)
        #expect(owner.runningCount == 1 && !owner.isQuiescent)
        guard case .timedOut(let diagnostics) = await owner.shutdown(deadline: .now) else {
            throw Failure.unexpected
        }
        #expect(diagnostics.outstandingExecutions.count == 1)
        #expect(store.complete(first, .success("Obsolete")))
        #expect(!store.complete(first, .success("Duplicate")))
        await owner.shutdown()
        #expect(store.cancelledAtReturn)
        #expect(owner.snapshot().value.text == "Second")
        #expect(owner.snapshot().isClosed && owner.runningCount == 0 && owner.pendingCompletions().isEmpty)
    }

    @Test func nativeActorReentersDuringDriverSuspensionAndRejectsRevokedOutcome_RT032() async throws {
        let user = try UserID("actor")
        let network = ControlledProfileNetwork()
        let drivers = network.drivers
        let owner = GeneratedProfile.ActorHost(
            .init(userID: user),
            drivers: .init(fetch: drivers.fetch, audit: drivers.audit)
        )
        let (stream, continuation) = AsyncStream<GeneratedProfile.Snapshot>.makeStream()
        let token = try await owner.subscribe { continuation.yield($0) }
        _ = try await owner.send(.load(ProfileRequest(userID: user)))
        let first = await network.nextRequest()
        _ = try await owner.send(.authenticationChanged)
        let closed = await owner.close()
        #expect(await owner.flush(through: closed) == .processed)
        #expect(await owner.runningCount == 1)
        if case .quiescent = await owner.shutdown(deadline: .now) {
            Issue.record("Shutdown reported quiescence while a driver was still running")
        }
        #expect(await network.complete(first.id, with: .success(Profile(userID: user, name: "Revoked"))))
        await owner.shutdown()
        let final = await owner.snapshot()
        guard case .loading = final else { throw Failure.unexpected }
        let running = await owner.runningCount
        #expect(final.isClosed && running == 0)
        token.cancel()
        continuation.finish()
        var revisions: [UInt64] = []
        for await snapshot in stream { revisions.append(snapshot.revision) }
        #expect(revisions == revisions.sorted() && Set(revisions).count == revisions.count)
        #expect(revisions.first == 0 && revisions.last == final.revision)
    }

    @MainActor @Test func isolatedSnapshotAndTokenDoNotRetainSuspendedOwner_RT032() async throws {
        let store = NoteStore()
        var owner: IsolatedNote.MainActorHost? = IsolatedNote.MainActorHost(
            .init(text: "release"),
            drivers: store.drivers
        )
        weak var marker: IsolatedNote.MainActorHost?
        marker = owner
        let historical = owner?.snapshot()
        let token = try owner?.subscribe { _ in }
        _ = try owner?.send(.save)
        let request = await store.nextRequest()
        owner = nil
        #expect(marker == nil)
        #expect(historical?.value.text == "release")
        #expect(store.complete(request, .success("late")))
        await store.waitForReturn()
        #expect(store.cancelledAtReturn)
        token?.cancel()
    }

    @MainActor @Test func generatedIsolatedDriverKeepsNonSendableOutcomeOnMainActor_RT032() async throws {
        let owner = GeneratedNote.MainActorHost(
            .init(text: "generated value"),
            drivers: .init(save: { input in
                .init(text: input.text)
            })
        )
        let trace = SnapshotTrace<GeneratedNote.Snapshot>()
        let token = try owner.subscribe { trace.record($0) }
        _ = try owner.send(.save)
        let saved = await trace.wait { if case .saved = $0 { true } else { false } }
        guard case .saved(let value) = saved else { throw Failure.unexpected }
        #expect(value.value.text == "generated value")
        token.cancel()
        await owner.shutdown()
        #expect(owner.runningCount == 0 && owner.isQuiescent)
    }

    @Test func nativeActorSubscriptionRevisionsAndClosedInitialRemainMonotonic_RT032() async throws {
        typealias Engine = RuntimeState<Int, Int>
        let owner = RuntimeActorHost<Int, Int, RuntimeTicket, Never>(
            0,
            scopes: [],
            driver: { $0.ticket },
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        for value in 1 ... 64 {
            let result: Result<Engine.Admission, PlanRejection> = await owner.prepareAndCommit { observation in
                Result { () throws(PlanRejection) in try Engine.prepare(on: observation, next: value) }
            }
            guard case .success(.committed) = result else { throw Failure.unexpected }
        }
        let (stream, events) = AsyncStream<Engine.Snapshot>.makeStream()
        let token = try await owner.subscribe({ events.yield($0) }, onFinish: { events.finish() })
        _ = await owner.prepareAndCommit { observation -> Result<Engine.Candidate, PlanRejection> in
            Result { () throws(PlanRejection) in try Engine.prepare(on: observation, next: 65) }
        }
        let closed = await owner.close()
        #expect(await owner.flush(through: closed))
        var observed: [UInt64] = []
        for await value in stream { observed.append(value.revision) }
        #expect(observed == [64, 65, 66])
        let (terminalStream, terminalEvents) = AsyncStream<Engine.Snapshot>.makeStream()
        let terminalToken = try await owner.subscribe(
            { terminalEvents.yield($0) },
            onFinish: { terminalEvents.finish() }
        )
        var terminal: [UInt64] = []
        for await value in terminalStream { terminal.append(value.revision) }
        #expect(terminal == [66])
        token.cancel()
        terminalToken.cancel()
        await owner.shutdown()
    }

    @MainActor @Test func ownedLocalActorAndIndependentReferenceAgreeOnLegalTrace_RT032() async throws {
        let user = try UserID("trace")
        let request = try ProfileRequest(userID: user)
        let profile = Profile(userID: user, name: "Trace value")
        let owned = GeneratedProfile.owned(.init(userID: user))
        let ownedName: String
        switch owned.begin(request) {
        case .advanced(let loading, let effects):
            guard effects.count == 1, case .fetch(let input) = effects[0] else { throw Failure.unexpected }
            #expect(input == request)
            let completed = loading.received(profile)
            ownedName = completed.withValue { $0.profile.name }
        case .rejected: throw Failure.unexpected
        }

        var local = GeneratedProfile.Local(.init(userID: user))
        let loading = try GeneratedProfile.prepare(.load(request), on: local.snapshot())
        guard case .committed(let loadingReceipt) = local.commit(loading),
            case .fetch(let work) = local.drainCommands(limit: 1).first?.commands.first,
            case .committed(let loadedReceipt) = local.deliver(.fetch(work.succeeded(profile))),
            case .loaded(let localLoaded) = local.snapshot()
        else { throw Failure.unexpected }
        #expect(local.acknowledgeExecution(work.execution, disposition: .terminated) == .recorded)
        #expect(loadingReceipt.revision == 1 && loadedReceipt.revision == 2)

        var reference = SequentialReference(owner: 1)
        guard case .committed = reference.commit(try reference.prepare(.load(1))),
            let referenceWork = reference.drain(limit: 1).first?.starts.first
        else { throw Failure.unexpected }
        _ = reference.retain(referenceWork, outcome: .success(2))
        guard case .committed(let referenceLoaded) = reference.reconcile(referenceWork.operation) else {
            throw Failure.unexpected
        }
        reference.acknowledge(referenceWork)
        #expect(referenceLoaded.root.phase == .loaded(2) && referenceLoaded.stamp.revision == loadedReceipt.revision)

        let actor = GeneratedProfile.ActorHost(
            .init(userID: user),
            drivers: .init(fetch: { _ in .success(profile) }, audit: { _ in .failure(.unavailable) })
        )
        let (stream, events) = AsyncStream<GeneratedProfile.Snapshot>.makeStream()
        let token = try await actor.subscribe { events.yield($0) }
        _ = try await actor.send(.load(request))
        var actorName: String?
        var actorRevisions: [UInt64] = []
        for await snapshot in stream {
            actorRevisions.append(snapshot.revision)
            if case .loaded(let value) = snapshot {
                actorName = value.value.profile.name
                break
            }
        }
        #expect(actorRevisions == [0, 1, 2])
        #expect(actorName == ownedName && localLoaded.value.profile.name == ownedName)
        token.cancel()
        events.finish()
        await actor.shutdown()
        _ = local.close()
        _ = local.drainCommands(limit: 100)
    }
}
