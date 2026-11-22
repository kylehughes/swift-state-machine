import StateMachine

/// A noncopyable harness that drives one real `Local` owner step by step and records every accepted change.
///
/// The harness consumes a generated `Local` and offers the same verbs, including `send`, `commit`,
/// `drainCommands`, `deliver`, `acknowledgeExecution`, `retryAdmission`, `reconcile`,
/// `discardPending`, `reset(to:)` and `reset(to:expecting:)`, `reset()` and `reset(expecting:)` when
/// the schema declares a default initial payload, the restoring resets of a schema with a
/// `@Restoration` function, and `close`. Each one calls the owner's own method and returns the
/// owner's own result, so the test sees real receipts, real command batches with real work, and
/// real rejections. A completion reaches the owner only through `deliver`, sealed by work the owner
/// issued, and the harness cannot construct a ticket, an observation, or a completion.
///
/// Every call that the owner accepts appends a ``Step`` to ``history`` containing the accepted
/// snapshot, the phase it left, the phase it holds, and the graph edge the owner's receipt names. A
/// ``GraphCoverage`` combines histories to report the edges and phases that no test exercised.
///
/// ```swift
/// var test = ManualMachineTest(GeneratedTransfers.Local())
/// try test.send(.download(1))
/// let batch = try test.drainBatch()
/// guard case .download(let work) = batch.commands.last else { return }
/// guard case .committed = test.deliver(.download(work.succeeded("bytes"))) else { return }
/// #expect(test.acknowledgeExecution(work.execution) == .recorded)
/// #expect(test.history.map(\.edge) == [nil, "browsing.download", "browsing.downloaded"])
/// ```
///
/// Helpers that expect an outcome, such as ``send(_:fileID:filePath:line:column:)`` and
/// ``drainBatch(fileID:filePath:line:column:)``, throw ``StateMachineTestFailure`` at the caller's
/// location when the owner does something else.
public struct ManualMachineTest<Owner: LocalStateMachine & ~Copyable>: ~Copyable {
    /// One accepted change, or the owner's state when the harness took it.
    public struct Step {
        /// What the test did to produce this step.
        public enum Kind: Sendable, Hashable {
            /// The owner's state when the harness took it.
            case initial
            /// `send` admitted an input.
            case send
            /// `commit` admitted a proposal.
            case commit
            /// `deliver` admitted a completion.
            case delivery
            /// `reconcile` admitted a retained completion after preparing it again.
            case reconciliation
            /// `retryAdmission` admitted a retained completion without preparing it again.
            case retry
            /// `discardPending` revoked a retained completion's operation.
            case discard
            /// `reset` replaced the model in a fresh incarnation.
            case reset
            /// `close` ended admission.
            case close
            /// The owner changed inside `withOwner`, which reports no receipt, so the step names no
            /// edge. When it changed more than once, only the last change is recorded, and a step
            /// that follows a replaced owner records the replacement's state.
            case unattributed
        }

        /// What the test did to produce this step.
        public let kind: Kind
        /// The identifier of the graph edge the owner's receipt names, or `nil` for a step that takes
        /// no edge, such as the initial step, a reset, closure, a discard, or an unattributed change.
        public let edge: String?
        /// What took the edge when the step went through one, either an input or an operation's
        /// success or failure.
        public let trigger: StateMachineGraph.Trigger?
        /// The phase the owner held before the step, or for the initial step, the phase it holds.
        public let source: String
        /// The phase the owner holds after the step.
        public let phase: String
        /// The accepted snapshot, which is the snapshot of the step's receipt.
        public let snapshot: Owner.Snapshot
        /// The accepted revision.
        public var revision: UInt64 { snapshot.revision }
    }

    /// A named condition every accepted snapshot must satisfy.
    public struct Invariant {
        /// The name a violation reports.
        public let name: String
        fileprivate let holds: (Owner.Snapshot) -> Bool

        /// Names a condition over complete snapshots.
        public init(_ name: String, _ holds: @escaping (Owner.Snapshot) -> Bool) {
            self.name = name
            self.holds = holds
        }
    }

    /// An input the owner's `send` rejected.
    public struct Rejection {
        /// The phase the owner held when it rejected the input.
        public let phase: String
        /// The identifier of the router or edge whose authored function refused the input, as the
        /// owner reports it, or `nil` when no authored function refused it.
        public let route: String?
        /// The typed rejection the owner's `send` threw.
        public let reason: Owner.SendRejection
        /// The owner's snapshot when it rejected the input.
        public let snapshot: Owner.Snapshot
    }

    /// A terminal outcome that a router or completion edge refused while `deliver` or `reconcile`
    /// prepared it, so the owner retained it for reconciliation.
    public struct CompletionRejection {
        /// The call that prepared the outcome, either ``Step/Kind/delivery`` or ``Step/Kind/reconciliation``.
        public let kind: Step.Kind
        /// The phase the owner held when it refused the outcome.
        public let phase: String
        /// The identifier of the router or completion edge whose authored function refused the
        /// outcome, as the owner names it.
        public let route: String
        /// The owner's snapshot when it refused the outcome.
        public let snapshot: Owner.Snapshot
    }

    /// An accepted snapshot that did not satisfy an invariant.
    public struct Violation {
        /// The name of the invariant.
        public let invariant: String
        /// The step whose snapshot violated it.
        public let step: Step
    }

    private var owner: Owner
    private let invariants: [Invariant]
    /// Every accepted change in order, beginning with the owner's state when the harness took it.
    public private(set) var history: [Step]
    /// Every accepted snapshot that did not satisfy an invariant, in order.
    public private(set) var violations: [Violation] = []
    /// Every input that `send` or ``rejection(of:fileID:filePath:line:column:)`` made the owner reject,
    /// in order, with the route the owner says refused it.
    public private(set) var rejections: [Rejection] = []
    /// Every terminal outcome whose router or completion edge refused it in a `deliver` or `reconcile`
    /// call, in order, with the route that call's result names.
    ///
    /// A result that names no route, such as one that found the outcome already retained, records none.
    public private(set) var completionRejections: [CompletionRejection] = []
    /// How many accepted changes the harness never observed because `withOwner` made them before the
    /// last change of its body.
    ///
    /// Their snapshots were not checked against any invariant.
    public private(set) var unobservedChanges = 0
    /// How many times a `withOwner` body replaced the owner with another, so that ``history`` no
    /// longer describes one owner.
    public private(set) var replacedOwners = 0

    /// Takes a fresh or restored `Local` and records its current state as the first step.
    ///
    /// Each invariant is checked against that state and every snapshot the owner accepts later.
    public init(_ owner: consuming Owner, invariants: [Invariant] = []) {
        let snapshot = owner.snapshot()
        let phase = Owner.phase(of: snapshot)
        self.owner = owner
        self.invariants = invariants
        history = []
        append(Step(kind: .initial, edge: nil, trigger: nil, source: phase, phase: phase, snapshot: snapshot))
    }

    /// The owner's current snapshot.
    public borrowing func snapshot() -> Owner.Snapshot { owner.snapshot() }

    /// The identifier of the phase the owner currently holds.
    public var phase: String { Owner.phase(of: owner.snapshot()) }

    /// Whether the harness observed every change one owner accepted so ``history`` holds every
    /// accepted snapshot.
    ///
    /// Becomes `false` once `withOwner` makes more than one change or replaces the owner.
    public var isHistoryComplete: Bool { unobservedChanges == 0 && replacedOwners == 0 }

    /// The graph edges that this run exercised, in the order it first exercised them.
    public var exercisedEdges: [String] {
        var seen = Set<String>()
        return history.compactMap(\.edge).filter { seen.insert($0).inserted }
    }

    /// Sends an input and returns its receipt, or throws a failure that describes the rejection.
    @discardableResult public mutating func send(
        _ input: Owner.Input,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) throws(StateMachineTestFailure) -> Owner.Receipt {
        let before = owner.snapshot()
        do {
            let receipt = try owner.send(input)
            record(.send, from: before, receipt: receipt)
            return receipt
        } catch {
            recordRejection(error, from: before)
            throw StateMachineTestFailure(
                "The owner rejected \(input) in \(before): \(error)",
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
    }

    /// Sends an input that the owner must reject and returns the typed rejection.
    ///
    /// It throws a failure when the owner admits the input, after recording the accepted step.
    public mutating func rejection(
        of input: Owner.Input,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) throws(StateMachineTestFailure) -> Owner.SendRejection {
        let before = owner.snapshot()
        let receipt: Owner.Receipt
        do {
            receipt = try owner.send(input)
        } catch {
            recordRejection(error, from: before)
            return error
        }
        record(.send, from: before, receipt: receipt)
        throw StateMachineTestFailure(
            "The owner admitted \(input) in \(before) at revision \(receipt.snapshot.revision)",
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    /// Consumes a proposal from an observation and returns the owner's commit result.
    public mutating func commit(_ prepared: consuming Owner.Prepared) -> Owner.CommitResult {
        let before = owner.snapshot()
        let result = owner.commit(prepared)
        record(.commit, from: before, receipt: Owner.receipt(of: result))
        return result
    }

    /// Replaces the model with `initial` in a fresh incarnation, revoking outstanding work.
    @discardableResult public mutating func reset(
        to initial: Owner.InitialPhase
    ) throws(CommitRejection) -> Owner.Receipt {
        let before = owner.snapshot()
        let receipt = try owner.reset(to: initial)
        record(.reset, from: before, receipt: receipt)
        return receipt
    }

    /// Resets as `reset(to:)` does, but only while the owner still holds the root `expected` observed.
    @discardableResult public mutating func reset(
        to initial: Owner.InitialPhase,
        expecting expected: Owner.Snapshot
    ) throws(CommitRejection) -> Owner.Receipt {
        let before = owner.snapshot()
        let receipt = try owner.reset(to: initial, expecting: expected)
        record(.reset, from: before, receipt: receipt)
        return receipt
    }

    /// Ends admission while retaining historical read access.
    @discardableResult public mutating func close() -> Owner.Receipt {
        let before = owner.snapshot()
        let receipt = owner.close()
        record(.close, from: before, receipt: receipt)
        return receipt
    }

    /// Runs `body` with the owner, for a member the harness does not offer.
    ///
    /// The owner reports no receipt to the harness, so a change it accepts inside `body` is recorded as
    /// an ``Step/Kind/unattributed`` step with no edge. When `body` makes several changes, the harness
    /// sees only the last. Each earlier one counts toward ``unobservedChanges``, the history is no
    /// longer complete, and ``requireInvariants(fileID:filePath:line:column:)`` and
    /// ``GraphCoverage/requireCoverage(excluding:includingRejectingRouters:fileID:filePath:line:column:)``
    /// fail because they can no longer vouch for every accepted snapshot.
    ///
    /// The harness compares the owner `body` leaves with the one it lent. When `body` assigns another
    /// owner, even a fresh one with an equal model at the same revision, the harness counts it in
    /// ``replacedOwners``, records the replacement's state as an unattributed step, and treats the
    /// history as incomplete from then on, because nothing it records describes one owner.
    public mutating func withOwner<Result, Failure: Error>(
        _ body: (inout Owner) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        let before = owner.snapshot()
        defer {
            let after = owner.snapshot()
            if owner.owns(before) {
                record(.unattributed, from: before, receipt: nil)
            } else {
                replacedOwners += 1
                append(
                    Step(
                        kind: .unattributed,
                        edge: nil,
                        trigger: nil,
                        source: Owner.phase(of: before),
                        phase: Owner.phase(of: after),
                        snapshot: after
                    )
                )
            }
        }
        return try body(&owner)
    }

    /// Requires that the harness observed every accepted snapshot and each satisfied every invariant.
    public func requireInvariants(
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) throws(StateMachineTestFailure) {
        var parts: [String] = []
        if !violations.isEmpty {
            parts.append(
                "Accepted snapshots violated invariants: "
                    + violations.map { "\($0.invariant) at revision \($0.step.revision) in \($0.step.phase)" }
                    .joined(separator: "; ")
            )
        }
        if unobservedChanges > 0 {
            parts.append(
                "\(unobservedChanges) accepted changes made inside withOwner were never observed, so their snapshots were not checked"
            )
        }
        if replacedOwners > 0 {
            parts.append(
                "withOwner replaced the owner \(replacedOwners) times, so the history does not describe one owner"
            )
        }
        guard !parts.isEmpty else { return }
        throw StateMachineTestFailure(
            parts.joined(separator: "; "),
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    /// Ends the harness and returns the owner it drove.
    ///
    /// The harness holds nothing of its own. Every batch it has not handed to the test is still
    /// queued in the owner, so the returned owner keeps all of its work.
    public consuming func finish() -> Owner { owner }

    /// Records the change a call made, if the owner accepted one, with the edge its receipt names.
    fileprivate mutating func record(_ kind: Step.Kind, from before: Owner.Snapshot, receipt: Owner.Receipt?) {
        let after = owner.snapshot()
        guard after.revision > before.revision else { return }
        let changes = after.revision - before.revision
        // Revisions count acceptances, so a call that advanced it more than once made changes the
        // harness never saw, leaving only the last snapshot available.
        if changes > 1 { unobservedChanges += Int(changes - 1) }
        let observed = receipt.flatMap { $0.snapshot.revision == after.revision ? $0 : nil }
        let edge = observed?.edgeID
        append(
            Step(
                kind: kind,
                edge: edge,
                trigger: edge.flatMap { edge in Owner.graph.edges.first { $0.id == edge }?.trigger },
                source: Owner.phase(of: before),
                phase: Owner.phase(of: after),
                snapshot: observed?.snapshot ?? after
            )
        )
    }

    /// Records a rejection the owner's `send` returned, with the route the owner names for it.
    private mutating func recordRejection(_ rejection: Owner.SendRejection, from before: Owner.Snapshot) {
        let phase = Owner.phase(of: before)
        rejections.append(
            Rejection(
                phase: phase,
                route: Owner.rejectingRoute(of: rejection, in: phase),
                reason: rejection,
                snapshot: before
            )
        )
    }

    /// Records the refusal of a completion that a call prepared from `before`, when the result of that
    /// call names the route that refused it.
    fileprivate mutating func recordRefusal(_ kind: Step.Kind, from before: Owner.Snapshot, route: String?) {
        guard let route else { return }
        completionRejections.append(
            CompletionRejection(kind: kind, phase: Owner.phase(of: before), route: route, snapshot: before)
        )
    }

    private mutating func append(_ step: Step) {
        history.append(step)
        for invariant in invariants where !invariant.holds(step.snapshot) {
            violations.append(Violation(invariant: invariant.name, step: step))
        }
    }
}

extension ManualMachineTest where Owner: DefaultingLocalStateMachine & ~Copyable {
    /// Replaces the model with the schema's declared default initial payload in a fresh incarnation,
    /// as the owner's own `reset()` does.
    @discardableResult public mutating func reset() throws(CommitRejection) -> Owner.Receipt {
        try reset(to: Owner.defaultInitialPhase())
    }

    /// Resets as `reset()` does, but only while the owner still holds the root `expected` observed.
    @discardableResult public mutating func reset(
        expecting expected: Owner.Snapshot
    ) throws(CommitRejection)
        -> Owner.Receipt
    {
        try reset(to: Owner.defaultInitialPhase(), expecting: expected)
    }
}

extension ManualMachineTest where Owner: RestoringLocalStateMachine & ~Copyable {
    /// Replaces the model with the phase restored from saved data in a fresh incarnation.
    @discardableResult public mutating func reset(
        restoring saved: sending Owner.RestorationArchive
    ) throws(Owner.RestorationRejection) -> Owner.Receipt {
        let before = owner.snapshot()
        let receipt = try owner.reset(restoring: saved)
        record(.reset, from: before, receipt: receipt)
        return receipt
    }

    /// Resets as `reset(restoring:)` does, but only while the owner still holds the root `expected` observed.
    @discardableResult public mutating func reset(
        restoring saved: sending Owner.RestorationArchive,
        expecting expected: Owner.Snapshot
    ) throws(Owner.RestorationRejection) -> Owner.Receipt {
        let before = owner.snapshot()
        let receipt = try owner.reset(restoring: saved, expecting: expected)
        record(.reset, from: before, receipt: receipt)
        return receipt
    }
}

extension ManualMachineTest where Owner: DrainingLocalStateMachine & ~Copyable {
    /// Transfers whole FIFO batches from the owner, at most `limit` of them.
    public mutating func drainCommands(limit: Int = .max) -> [Owner.CommandBatch] {
        owner.drainCommands(limit: limit)
    }

    /// How many whole batches the owner has queued, without transferring any.
    public var queuedBatchCount: Int { owner.queuedBatchCount }

    /// Transfers the one queued batch, or throws a failure when no batch or several are queued.
    ///
    /// It counts the queued batches before transferring any, so a failed expectation transfers
    /// nothing and every batch stays queued in the owner for the next ``drainCommands(limit:)``,
    /// ``drainFlattenedCommands()``, or the owner ``finish()`` returns.
    public mutating func drainBatch(
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) throws(StateMachineTestFailure) -> Owner.CommandBatch {
        let queued = owner.queuedBatchCount
        guard queued == 1 else {
            throw StateMachineTestFailure(
                "Expected one queued command batch, found \(queued)"
                    + (queued == 0 ? "" : "; they stay queued in the owner"),
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
        return owner.drainCommands(limit: 1)[0]
    }

    /// Transfers every queued batch and returns their commands as one flattened list, in order.
    ///
    /// ``drainCommands(limit:)`` transfers the same batches and returns them whole.
    public mutating func drainFlattenedCommands() -> [Owner.Command] {
        drainCommands().flatMap(\.commands)
    }

    /// Whether closure, the transfer of every batch to the test, and every execution obligation have settled.
    public var isQuiescent: Bool { owner.isQuiescent }
}

extension ManualMachineTest where Owner: DeliveringLocalStateMachine & ~Copyable {
    /// Delivers a completion of work the owner issued and returns the owner's decision.
    public mutating func deliver(_ completion: Owner.Completion) -> Owner.DeliveryResult {
        let before = owner.snapshot()
        let result = owner.deliver(completion)
        record(.delivery, from: before, receipt: Owner.receipt(of: result))
        recordRefusal(.delivery, from: before, route: Owner.rejectingRoute(of: result))
        return result
    }

    /// Records actual termination independently of cancellation and completion delivery.
    public mutating func acknowledgeExecution(
        _ execution: Owner.ExecutionHandle,
        disposition: ExecutionDisposition = .terminated
    ) -> AcknowledgmentResult {
        owner.acknowledgeExecution(execution, disposition: disposition)
    }

    /// Claims one fresh preparation attempt for a retained outcome.
    public mutating func reconcile(id: Owner.PendingCompletionID) -> Owner.ReconcileResult {
        let before = owner.snapshot()
        let result = owner.reconcile(id: id)
        record(.reconciliation, from: before, receipt: Owner.receipt(of: result))
        recordRefusal(.reconciliation, from: before, route: Owner.rejectingRoute(of: result))
        return result
    }

    /// Retries admission of a retained candidate that was waiting for capacity, without preparing it again.
    public mutating func retryAdmission(id: Owner.PendingCompletionID) -> Owner.ReconcileResult {
        let before = owner.snapshot()
        let result = owner.retryAdmission(id: id)
        record(.retry, from: before, receipt: Owner.receipt(of: result))
        return result
    }

    /// Revokes one retained operation using an atomic authority-only commit.
    public mutating func discardPending(id: Owner.PendingCompletionID) -> Owner.DiscardResult {
        let before = owner.snapshot()
        let result = owner.discardPending(id: id)
        record(.discard, from: before, receipt: Owner.receipt(of: result))
        return result
    }

    /// Reads immutable retained first-outcome records without claiming preparation.
    public borrowing func pendingCompletions() -> [Owner.PendingCompletion] { owner.pendingCompletions() }
}
