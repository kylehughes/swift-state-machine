import StateMachine
import Testing
import os

@Suite struct DeliveryRetirementTests {
    private final class Token: Sendable {
        let release: @Sendable () -> Void
        init(_ release: @escaping @Sendable () -> Void) { self.release = release }
        deinit { release() }
    }
    private typealias Core = RuntimeState<Int, Int>
    private typealias Ledger = RuntimeDeliveryLedger<Int, Int, Token, Never>
    private struct State: Sendable {
        var core: Core
        var ledger = Ledger()
    }
    private enum Path: CaseIterable, Sendable { case cancel, reset, discard, close, accepted }
    private func update<Result>(
        _ storage: AtomicRecordStorage<State>,
        _ body: (inout State) throws -> Result
    ) rethrows -> Result {
        while true {
            let before = storage.load()
            var after = before.value
            let result = try body(&after)
            if storage.install(.init(after), replacing: before) { return result }
        }
    }
    private func start(_ storage: AtomicRecordStorage<State>, scope: RuntimeScopeID) throws -> RuntimeTicket {
        try update(storage) { state in
            let candidate = try Core.prepare(
                on: state.core.snapshot,
                next: 1,
                plan: .init(starts: [.init(.init(kind: 0, scope: scope), descriptor: 0)])
            )
            guard case .committed = state.core.commit(candidate),
                case .start(let work) = state.core.drain(limit: 1)[0].commands[0]
            else { throw Failure.start }
            _ = state.core.acknowledge(work.ticket)
            return work.ticket
        }
    }
    private enum Failure: Error { case start, retain, claim, candidate }
    private func retain(
        _ storage: AtomicRecordStorage<State>,
        ticket: RuntimeTicket,
        count: OSAllocatedUnfairLock<Int>
    ) throws -> RuntimePendingID {
        try update(storage) { state in
            let token = Token { [weak storage] in
                // A final payload release must be able to reacquire this exact storage.
                _ = storage?.load().value.core.snapshot
                count.withLock { $0 += 1 }
            }
            guard case .pending(let id) = state.ledger.retain(token, for: ticket, in: &state.core) else {
                throw Failure.retain
            }
            return id
        }
    }
    private func retire(
        _ path: Path,
        storage: AtomicRecordStorage<State>,
        ticket: RuntimeTicket,
        id: RuntimePendingID
    ) throws {
        try update(storage) { state in
            switch path {
            case .cancel, .reset:
                let plan = Core.Plan(retire: path == .cancel ? [ticket] : [], reset: path == .reset)
                let candidate = try Core.prepare(on: state.core.snapshot, next: 2, plan: plan)
                guard case .committed = state.core.commit(candidate) else { throw Failure.candidate }
                state.ledger.prune(in: state.core)
            case .discard:
                guard case .committed = state.ledger.discard(id, in: &state.core) else { throw Failure.candidate }
            case .close:
                _ = state.core.close()
                state.ledger.prune(in: state.core)
            case .accepted:
                guard case .claimed(let attempt) = state.ledger.claim(id, in: &state.core) else { throw Failure.claim }
                let candidate = try Core.prepare(
                    on: attempt.snapshot,
                    next: 2,
                    requiring: [ticket],
                    plan: .init(retire: [ticket], finishingClaims: [attempt.claim])
                )
                guard case .committed = state.ledger.finish(attempt, preparation: .success(candidate), in: &state.core)
                else { throw Failure.candidate }
            }
        }
    }
    @Test func pendingRetirementMatrixReentersStorageOutsideLock_RT024() throws {
        for path in Path.allCases {
            let scope = RuntimeScopeID(kind: 0)
            let storage = AtomicRecordStorage(State(core: Core(0, scopes: [scope], limits: try .init())))
            let releases = OSAllocatedUnfairLock(initialState: 0)
            let ticket = try start(storage, scope: scope)
            let id = try retain(storage, ticket: ticket, count: releases)
            #expect(releases.withLock { $0 } == 0)
            try retire(path, storage: storage, ticket: ticket, id: id)
            #expect(storage.load().value.ledger.pending.isEmpty)
            #expect(releases.withLock { $0 } == 1)
        }
    }
    @Test func duplicateEnvelopeAndInvalidatedClaimReleaseOutsideLock_RT024_RT041() throws {
        let scope = RuntimeScopeID(kind: 0)
        let storage = AtomicRecordStorage(State(core: Core(0, scopes: [scope], limits: try .init())))
        let releases = OSAllocatedUnfairLock(initialState: 0)
        let ticket = try start(storage, scope: scope)
        let id = try retain(storage, ticket: ticket, count: releases)
        #expect(try retain(storage, ticket: ticket, count: releases) == id)
        #expect(releases.withLock { $0 } == 1)
        func holdClaimThroughClose() throws {
            let attempt = try update(storage) { state in
                guard case .claimed(let attempt) = state.ledger.claim(id, in: &state.core) else { throw Failure.claim }
                return attempt
            }
            try retire(.close, storage: storage, ticket: ticket, id: id)
            #expect(releases.withLock { $0 } == 1)
            #expect(storage.load().value.core.executionReservations.first?.isPreparing == true)
            update(storage) { state in
                _ = state.ledger.finish(attempt, preparation: .failure(.plan(.invalidPlan)), in: &state.core)
            }
            #expect(storage.load().value.core.executionReservations.isEmpty)
        }
        try holdClaimThroughClose()
        #expect(releases.withLock { $0 } == 2)
    }
}
