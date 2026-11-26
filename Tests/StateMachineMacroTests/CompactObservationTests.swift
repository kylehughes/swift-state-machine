import StateMachine
import Testing
import os

private protocol CompactItem: Sendable {
    var score: Int { get }
}

private struct ScoredItem: CompactItem {
    let score: Int
}

private class HierarchyBase {
    let tag: String
    init(_ tag: String) { self.tag = tag }
}

private final class HierarchySub: HierarchyBase {
    let extra: Int
    init(_ tag: String, extra: Int) {
        self.extra = extra
        super.init(tag)
    }
}

/// Heterogeneous struct and enum phase payloads carrying `Optional.none`, nested optionals (`Int??`),
/// reference inheritance (`HierarchyBase` / `HierarchySub`), tuples, closures, and existentials
/// through both concrete and generic `Observed<Phase>.value` getters.
@StateMachine(mode: .isolated)
nonisolated private enum HeterogeneousFlow {
    struct OptionalPhase {
        let value: Int?
        let nested: Int??
    }
    enum ChoicePhase {
        case empty
        case nested(Int??)
        case reference(HierarchyBase)
    }
    struct BaseHolder {
        let object: HierarchyBase
    }
    struct SubHolder {
        let object: HierarchySub
    }
    struct RichPayload {
        let pair: (Int, String)
        let compute: (Int) -> Int
        let item: any CompactItem
    }

    @Initial case optional(OptionalPhase)
    case choice(ChoicePhase)
    case base(BaseHolder)
    case sub(SubHolder)
    @Terminal case rich(RichPayload)

    enum Input {
        case toChoice(ChoicePhase)
        case toBase(HierarchyBase)
        case toSub(HierarchySub)
        case toRich((Int, String))
    }

    @Transition(on: Input.toChoice)
    fileprivate static func toChoice(_ source: OptionalPhase, _ next: ChoicePhase) -> ChoicePhase { next }

    @Transition(on: Input.toBase)
    fileprivate static func toBase(_ source: ChoicePhase, _ object: HierarchyBase) -> BaseHolder {
        BaseHolder(object: object)
    }

    @Transition(on: Input.toSub)
    fileprivate static func toSub(_ source: BaseHolder, _ object: HierarchySub) -> SubHolder {
        SubHolder(object: object)
    }

    @Transition(on: Input.toRich)
    fileprivate static func toRich(_ source: SubHolder, _ input: (Int, String)) -> RichPayload {
        let offset = input.0 + source.object.extra
        let label = "\(source.object.tag):\(input.1)"
        return RichPayload(
            pair: (offset, label),
            compute: { $0 + offset },
            item: ScoredItem(score: offset * 2)
        )
    }
}

/// Single-phase schema verifying zero unreachable-code diagnostics and exact payload extraction.
@StateMachine(mode: .shared, owners: [.local, .shared])
nonisolated private enum SinglePhaseFlow: Sendable {
    struct Ready: Sendable, Equatable {
        var count: Int
    }
    @Initial case ready(Ready)
    enum Input: Sendable { case step(Int) }

    @Transition(on: Input.step)
    fileprivate static func step(_ source: Ready, _ delta: Int) -> Ready {
        Ready(count: source.count + delta)
    }
}

/// Records source payloads observed by direct edges and async delivery completions,
/// proving retained past observations keep their original payload and reject stale commits.
private final class ObservedAudit: Sendable {
    private let log = OSAllocatedUnfairLock<[String]>(initialState: [])
    func record(_ entry: String) { log.withLock { $0.append(entry) } }
    var entries: [String] { log.withLock { $0 } }
}

@StateMachine(mode: .shared, owners: [.local, .shared])
nonisolated private enum RetentionFlow: Sendable {
    struct Draft: Sendable, Equatable {
        let version: String
        let audit: ObservedAudit
        static func == (lhs: Draft, rhs: Draft) -> Bool { lhs.version == rhs.version }
    }
    struct Syncing: Sendable, Equatable {
        let version: String
        let audit: ObservedAudit
        static func == (lhs: Syncing, rhs: Syncing) -> Bool { lhs.version == rhs.version }
    }
    @Initial case draft(Draft)
    case syncing(Syncing)

    enum Scope {
        @Active(in: [Syncing.self]) case sync
    }
    enum Input: Sendable {
        case edit(String)
        case beginSync
        case cancelSync
    }
    enum SyncFailure: Error, Sendable, Equatable { case refused(String) }

    @Operation(scope: Scope.sync)
    enum Sync {
        typealias Input = String
        typealias Output = String
        typealias Failure = SyncFailure
    }

    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: Draft, _ next: String) -> Draft {
        source.audit.record("edit:\(source.version)->\(next)")
        return Draft(version: next, audit: source.audit)
    }

    @Transition(on: Input.beginSync, starts: [Sync.self])
    fileprivate static func beginSync(_ source: Draft) -> Change<Syncing, Effect.BeginSync> {
        source.audit.record("beginSync:\(source.version)")
        return Change(Syncing(version: source.version, audit: source.audit), effects: [.sync(source.version)])
    }

    @Transition(on: Input.cancelSync)
    fileprivate static func cancelSync(_ source: Syncing) -> Draft {
        source.audit.record("cancelSync:\(source.version)")
        return Draft(version: source.version, audit: source.audit)
    }

    @Transition(onSuccess: Sync.self)
    fileprivate static func synced(_ source: Syncing, _ result: Sync.Output) throws(SyncFailure) -> Draft {
        source.audit.record("synced:\(source.version):\(result)")
        if result == "reject" { throw .refused(source.version) }
        return Draft(version: result, audit: source.audit)
    }

    @Transition(onFailure: Sync.self)
    fileprivate static func syncFailed(_ source: Syncing, _ error: Sync.Failure) -> Draft {
        source.audit.record("syncFailed:\(source.version)")
        return Draft(version: "failed", audit: source.audit)
    }
}

/// Nested schema declaring user types named `Exact`, `Value`, `Payload`, and `_StateMachineExact`,
/// plus a zero-argument transition named `payload()`, proving zero newly reserved schema-level names.
private enum OuterHost {
    @StateMachine(mode: .shared, owners: [.local])
    nonisolated enum Aliased: Sendable {
        struct _StateMachineExact: Sendable, Equatable { let n: Int }
        struct Exact: Sendable, Equatable { let n: Int }
        struct Value: Sendable, Equatable { let n: Int }
        struct Payload: Sendable, Equatable { let n: Int }
        @Initial case exact(Exact)
        case value(Value)
        case custom(_StateMachineExact)
        @Terminal case done(Payload)
        enum Input: Sendable { case payload, custom, finish }

        @Transition(on: Input.payload)
        fileprivate static func payload(_ source: Exact) -> Value { Value(n: source.n + 1) }

        @Transition(on: Input.custom)
        fileprivate static func toCustom(_ source: Value) -> _StateMachineExact {
            _StateMachineExact(n: source.n + 5)
        }

        @Transition(on: Input.finish)
        fileprivate static func finish(_ source: _StateMachineExact) -> Payload { Payload(n: source.n + 10) }
    }
}

private func readGeneric<Phase>(_ observed: HeterogeneousFlow.Observed<Phase>) -> Phase {
    observed.value
}

private func readSingleGeneric<Phase: Sendable>(_ observed: SinglePhaseFlow.Observed<Phase>) -> Phase {
    observed.value
}

@Suite struct CompactObservationTests {
    private struct Unexpected: Error {}

    @Test func heterogeneousConcreteAndGenericObservationGettersHandleOptionalsAndHierarchy() throws {
        // Optional.none and nested Optional.none
        var local = HeterogeneousFlow.Local(.init(value: nil, nested: nil))
        guard case .optional(let noneObs) = local.snapshot() else { throw Unexpected() }
        #expect(noneObs.value.value == nil && noneObs.value.nested == nil)
        let genericNone = readGeneric(noneObs)
        #expect(genericNone.value == nil && genericNone.nested == nil)

        // Nested optional: .some(.none)
        let innerNil: Int?? = .some(nil)
        try local.reset(to: .init(value: 7, nested: innerNil))
        guard case .optional(let innerObs) = local.snapshot() else { throw Unexpected() }
        #expect(innerObs.value.value == 7)
        #expect(innerObs.value.nested != nil && innerObs.value.nested! == nil)
        let genericInner = readGeneric(innerObs)
        #expect(genericInner.value == 7 && genericInner.nested != nil && genericInner.nested! == nil)

        // Enum phase payload carrying nested optional .some(.none)
        try local.send(.toChoice(.nested(.some(nil))))
        guard case .choice(let choiceObs) = local.snapshot() else { throw Unexpected() }
        guard case .nested(let concreteNested) = choiceObs.value,
            case .nested(let genericNested) = readGeneric(choiceObs)
        else { throw Unexpected() }
        #expect(concreteNested != nil && concreteNested! == nil)
        #expect(genericNested != nil && genericNested! == nil)

        // Reference hierarchy: BaseHolder holding a HierarchySub instance stays typed as HierarchyBase
        let subAsBase: HierarchyBase = HierarchySub("as-base", extra: 99)
        try local.send(.toBase(subAsBase))
        guard case .base(let baseObs) = local.snapshot() else { throw Unexpected() }
        #expect(baseObs.value.object === subAsBase)
        #expect(readGeneric(baseObs).object === subAsBase)

        // Reference hierarchy: SubHolder returns exact HierarchySub instance
        let sub = HierarchySub("exact-sub", extra: 5)
        try local.send(.toSub(sub))
        guard case .sub(let subObs) = local.snapshot() else { throw Unexpected() }
        #expect(subObs.value.object === sub && subObs.value.object.extra == 5)
        #expect(readGeneric(subObs).object === sub && readGeneric(subObs).object.extra == 5)

        // Tuple, closure, and existential fields in terminal struct payload
        let terminalReceipt = try local.send(.toRich((10, "ok")))
        #expect(terminalReceipt.edgeID == "sub.toRich")
        guard case .rich(let richObs) = terminalReceipt.snapshot else { throw Unexpected() }
        #expect(richObs.value.pair == (15, "exact-sub:ok"))
        #expect(richObs.value.compute(4) == 19)
        #expect(richObs.value.item.score == 30)
        let genericRich = readGeneric(richObs)
        #expect(genericRich.pair == (15, "exact-sub:ok"))
        #expect(genericRich.compute(4) == 19)
        #expect(genericRich.item.score == 30)
    }

    @Test func singlePhaseConcreteAndGenericObservationGetters() throws {
        var local = SinglePhaseFlow.Local(.init(count: 1))
        let receipt = try local.send(.step(4))
        #expect(receipt.edgeID == "ready.step" && receipt.revision == 1)
        guard case .ready(let obs) = receipt.snapshot else { throw Unexpected() }
        #expect(obs.value == .init(count: 5))
        #expect(readSingleGeneric(obs) == .init(count: 5))
    }

    @Test func retainedPastObservationKeepsOriginalPayloadAndEnforcesAdmissionAuthority() throws {
        let audit = ObservedAudit()
        var owner = RetentionFlow.Local(.init(version: "v0", audit: audit))
        var other = RetentionFlow.Local(.init(version: "other", audit: audit))

        let pastSnapshot = owner.snapshot()
        guard case .draft(let pastObserved) = pastSnapshot else { throw Unexpected() }

        // Advance owner to v1 while pastSnapshot / pastObserved remain retained.
        let r1 = try owner.send(.edit("v1"))
        #expect(r1.edgeID == "draft.edit" && r1.revision == 1)
        #expect(pastObserved.value.version == "v0")
        #expect(pastSnapshot.revision == 0)

        // Direct typed edge on pastObserved must run against v0 (not v1) and be rejected as stale conflict.
        let stalePrepared = pastObserved.edit("from-v0")
        #expect(audit.entries.last == "edit:v0->from-v0")
        guard case .rejected(.conflict, let current) = owner.commit(stalePrepared) else {
            Issue.record("Stale commit from retained past observation was not rejected as conflict")
            return
        }
        guard case .draft(let currentDraft) = current else { throw Unexpected() }
        #expect(currentDraft.value.version == "v1" && current.revision == 1)

        // Foreign owner rejects a proposal prepared from owner's past observation.
        guard case .rejected(.foreignOwner, _) = other.commit(pastObserved.edit("cross-owner")) else {
            Issue.record("Foreign owner accepted another owner's observation")
            return
        }

        // Reset invalidates prior incarnation.
        let resetReceipt = try owner.reset(to: .init(version: "v-reset", audit: audit))
        #expect(resetReceipt.edgeID == nil && resetReceipt.revision == 2)
        guard case .rejected(.obsoleteIncarnation, _) = owner.commit(pastObserved.edit("post-reset")) else {
            Issue.record("Post-reset commit did not report obsoleteIncarnation")
            return
        }

        // Close rejects any further commit.
        let closedReceipt = owner.close()
        #expect(closedReceipt.edgeID == nil && closedReceipt.snapshot.isClosed)
        guard case .rejected(.closed, _) = owner.commit(pastObserved.edit("post-close")) else {
            Issue.record("Post-close commit did not report closed")
            return
        }
    }

    @Test func asyncDeliveryPreservesRetentionRefusalAndStaleAuthoritySemantics() async throws {
        let audit = ObservedAudit()
        let owner = RetentionFlow.Shared(
            .init(version: "v0", audit: audit),
            syncDriver: { _ in .success("reject") },
            completionPolicy: .manual
        )
        let beginReceipt = try owner.send(.beginSync)
        #expect(beginReceipt.edgeID == "draft.beginSync")
        _ = await owner.flush(through: beginReceipt)

        // Wait for manual-policy refused completion to be retained in pendingCompletions().
        var pendingID: RetentionFlow.PendingCompletionID?
        let updates = try owner.pendingCompletionUpdates()
        defer { updates.cancel() }
        for await list in updates {
            if let first = list.first, first.status == .reconciliationRequired {
                pendingID = first.id
                break
            }
        }
        let id = try #require(pendingID)
        // Reconcile still runs against the retained syncing payload ("v0") and refuses cleanly.
        guard case .refused(_, .synced(.refused(let seenVersion)), let routeID) = owner.reconcile(id: id) else {
            Issue.record("Expected retained completion refusal on reconcile")
            await owner.shutdown()
            return
        }
        #expect(seenVersion == "v0" && routeID == "syncing.synced")

        // Leaving Syncing revokes the operation and prunes the retained completion.
        let cancelReceipt = try owner.send(.cancelSync)
        #expect(cancelReceipt.edgeID == "syncing.cancelSync")
        guard case .notPending = owner.reconcile(id: id) else {
            Issue.record("Revoked completion remained pending")
            await owner.shutdown()
            return
        }
        await owner.shutdown()
    }

    @Test func nestedAliasedSchemaAndPayloadTransitionAvoidHelperCollisions() throws {
        var local = OuterHost.Aliased.Local(.init(n: 3))
        guard case .exact(let obs) = local.snapshot() else { throw Unexpected() }
        guard case .committed(let r1) = local.commit(obs.payload()) else { throw Unexpected() }
        #expect(r1.edgeID == "exact.payload")
        guard case .value(let mid) = r1.snapshot else { throw Unexpected() }
        #expect(mid.value == .init(n: 4))
        let r2 = try local.send(.custom)
        #expect(r2.edgeID == "value.toCustom")
        guard case .custom(let custom) = r2.snapshot else { throw Unexpected() }
        #expect(custom.value == .init(n: 9))
        let r3 = try local.send(.finish)
        #expect(r3.edgeID == "custom.finish")
        guard case .done(let done) = r3.snapshot else { throw Unexpected() }
        #expect(done.value == .init(n: 19))
    }
}
