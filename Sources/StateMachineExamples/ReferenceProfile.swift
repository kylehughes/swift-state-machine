import StateMachine

/// A handwritten shared-value graph with sealed manual ownership and operation authority.
///
/// Domain definitions are trusted to validate data and describe pure transitions.
/// A snapshot is historical evidence, and constructing model data grants no authority.
nonisolated public enum ReferenceProfile {
    /// The initial profile phase.
    public struct Idle: Codable, Equatable, Sendable {
        /// The validated user identifier.
        public let userID: UserID
        /// Creates a value from the supplied data; authority-bearing construction remains private.
        public init(userID: UserID) { self.userID = userID }
    }
    /// The in-flight request payload.
    public struct Loading: Codable, Equatable, Sendable {
        /// The immutable validated request.
        public let request: ProfileRequest
        /// Creates a value from the supplied data; authority-bearing construction remains private.
        public init(request: ProfileRequest) { self.request = request }
    }
    /// The successful profile payload.
    public struct Loaded: Codable, Equatable, Sendable {
        /// The immutable profile data.
        public let profile: Profile
        /// Creates a value from the supplied data; authority-bearing construction remains private.
        public init(profile: Profile) { self.profile = profile }
    }
    /// The failed request and its typed reason.
    public struct Failed: Codable, Equatable, Sendable {
        /// The immutable validated request.
        public let request: ProfileRequest
        /// The typed failure reason.
        public let failure: ProfileFailure
        /// Creates a value from the supplied data; authority-bearing construction remains private.
        public init(request: ProfileRequest, failure: ProfileFailure) {
            self.request = request
            self.failure = failure
        }
    }
    /// Persistable profile data without live authority.
    public enum Model: Codable, Equatable, Sendable {
        case idle(Idle)
        case loading(Loading)
        case loaded(Loaded)
        case failed(Failed)
    }
    /// Ordered inert descriptions for explicit caller execution.
    public enum Effect: Equatable, Sendable {
        case fetch(ProfileRequest)
        case audit(String)
    }
    /// A recoverable request rejection.
    public enum LoadRejection: Error, Sendable { case wrongUser }
    /// The typed fetch operation vocabulary.
    public enum Fetch {
        /// The operation input type.
        public typealias Input = ProfileRequest
        /// The operation success type.
        public typealias Output = Profile
        /// The operation failure type.
        public typealias Failure = ProfileFailure
    }
    /// An independent audit operation with distinct work and completion types.
    public enum Audit {
        /// The immutable audit message.
        public typealias Input = String
        /// The successful audit profile.
        public typealias Output = Profile
        /// The typed audit failure.
        public typealias Failure = ProfileFailure
    }
    /// Audit work issued only after its start command is accepted.
    public struct AuditWork: Sendable {
        /// The immutable audit input.
        public let input: Audit.Input
        fileprivate let authority: Authority
        /// The sealed execution acknowledgment capability.
        public var execution: ExecutionHandle { ExecutionHandle(authority: authority) }
        /// Seals a successful result for this exact audit operation.
        public func succeeded(_ output: Audit.Output) -> AuditCompletion {
            .success(AuditSuccessCompletion(value: output, authority: authority))
        }
        /// Seals a failed result for this exact audit operation.
        public func failed(_ failure: Audit.Failure) -> AuditCompletion {
            .failure(AuditFailureCompletion(value: failure, authority: authority))
        }
    }
    /// The closed terminal vocabulary of the audit operation.
    public enum AuditCompletion: Sendable {
        case success(AuditSuccessCompletion)
        case failure(AuditFailureCompletion)
    }
    /// A sealed successful audit outcome.
    public struct AuditSuccessCompletion: Sendable {
        /// The successful audit value.
        public let value: Audit.Output
        fileprivate let authority: Authority
    }
    /// A sealed failed audit outcome.
    public struct AuditFailureCompletion: Sendable {
        /// The typed audit failure.
        public let value: Audit.Failure
        fileprivate let authority: Authority
    }
    /// Unique authority over one workflow phase.
    public struct Owned<Phase: ~Copyable>: ~Copyable {
        fileprivate let phase: Phase
        fileprivate init(_ phase: consuming Phase) { self.phase = phase }
        /// Borrows the payload for a nonescaping synchronous read.
        public borrowing func withValue<Result>(_ body: (borrowing Phase) -> Result) -> Result { body(phase) }
    }
    /// Creates authority only for the declared initial phase.
    public static func owned(_ initial: Idle) -> Owned<Idle> { Owned(initial) }
    /// A historical phase value whose provenance is sealed.
    public struct Observed<Phase: Sendable>: Sendable {
        fileprivate let payload: Phase
        fileprivate let record: Record
        fileprivate let stamp: Stamp
        fileprivate let configuration: Configuration
        /// The observed phase payload.
        public var value: Phase { payload }
        /// The owner-lifetime commit revision.
        public var revision: UInt64 { stamp.revision }
    }
    /// A copyable historical observation of the complete root.
    public enum Snapshot: Sendable {
        case idle(Observed<Idle>)
        case loading(Observed<Loading>)
        case loaded(Observed<Loaded>)
        case failed(Observed<Failed>)
        /// The owner-lifetime commit revision.
        public var revision: UInt64 { stamp.revision }
        /// An unrelated presentation field.
        public var presentation: String { record.presentation }
        /// The ordinary model projection.
        public var model: Model { record.model }
        /// Whether this historical observation records closure.
        public var isClosed: Bool { record.closed }
        fileprivate var stamp: Stamp {
            switch self {
            case .idle(let value): value.stamp
            case .loading(let value): value.stamp
            case .loaded(let value): value.stamp
            case .failed(let value): value.stamp
            }
        }
        fileprivate var record: Record {
            switch self {
            case .idle(let value): value.record
            case .loading(let value): value.record
            case .loaded(let value): value.record
            case .failed(let value): value.record
            }
        }
        /// Prepares a whole-root presentation edit without changing operation authority.
        public func presentationChanged(_ text: String) -> Prepared {
            var next = record
            next.presentation = text
            return Prepared(Payload(stamp: stamp, record: next, action: .preserve))
        }
        /// Prepares explicit authentication invalidation.
        public func authenticationChanged() -> Prepared {
            Prepared(Payload(stamp: stamp, record: record, action: .invalidateAuthentication))
        }
    }
    /// A sealed, inert proposal consumed by admission, or the plan defect admission reports.
    public struct Prepared: ~Copyable, Sendable {
        fileprivate enum Proposal: Sendable {
            case payload(Payload)
            case defective(Engine.DefectivePlan)
        }
        fileprivate let payload: Proposal
        fileprivate init(_ payload: Payload) { self.payload = .payload(payload) }
        fileprivate init(defect: Engine.DefectivePlan) { payload = .defective(defect) }
    }
    /// A committed fetch capability issued by draining accepted commands.
    public struct FetchWork: Sendable {
        /// The input.
        public let input: Fetch.Input
        /// The sealed handle for reporting actual execution termination.
        public var execution: ExecutionHandle { ExecutionHandle(authority: authority) }
        fileprivate let authority: Authority
        /// Seals a success outcome using this committed work capability.
        public func succeeded(_ output: Fetch.Output) -> FetchCompletion {
            .success(FetchSuccessCompletion(value: output, authority: authority))
        }
        /// Seals a failed outcome using this committed work capability.
        public func failed(_ failure: Fetch.Failure) -> FetchCompletion {
            .failure(FetchFailureCompletion(value: failure, authority: authority))
        }
    }
    /// Immutable driver selection for one managed owner.
    public struct Drivers: Sendable {
        /// Executes one request and returns its typed terminal outcome.
        public let fetch: @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>
        /// Executes an independent audit request.
        public let audit: @Sendable (Audit.Input) async -> Result<Audit.Output, Audit.Failure>
        /// Selects drivers for the owner's entire lifetime.
        public init(
            fetch: @escaping @Sendable (Fetch.Input) async -> Result<Fetch.Output, Fetch.Failure>,
            audit: @escaping @Sendable (Audit.Input) async -> Result<Audit.Output, Audit.Failure>
        ) {
            self.fetch = fetch
            self.audit = audit
        }
    }
    /// The opaque owner-bound identity of a retained completion.
    public typealias PendingCompletionID = RuntimePendingID
    /// Whether completion preparation requires explicit reconciliation after conflict.
    public typealias CompletionConflictPolicy = RuntimeCompletionPolicy
    /// The historical delivery status of a retained completion.
    public typealias PendingStatus = StateMachine.PendingStatus
    /// A typed routing failure for a retained fetch completion.
    public enum CompletionPreparationRejection: Error, Equatable, Sendable { case wrongPhase }
    /// The actionable preparation or commit failure from the last attempt.
    public enum CompletionRejection: Equatable, Sendable {
        case preparation(CompletionPreparationRejection)
        case commit(CommitRejection)
    }
    /// The declared managed operation vocabulary.
    public enum OperationKind: Equatable, Sendable { case fetch, audit }
    /// A typed historical pending record, independent of physical worker lifetime.
    public struct PendingCompletion: Sendable {
        /// The declared operation that produced this outcome.
        public var operation: OperationKind {
            switch outcome {
            case .fetch: .fetch
            case .audit: .audit
            }
        }
        /// The opaque identity accepted by reconciliation and discard.
        public let id: PendingCompletionID
        /// The first immutable terminal outcome retained for the operation.
        public let outcome: Completion
        /// The delivery state when this record was captured.
        public let status: PendingStatus
        /// The last typed preparation or admission failure, when present.
        public let lastRejection: CompletionRejection?
        /// The saturating number of preparations; admission-only retries do not increment it.
        public let attemptCount: UInt64
        /// Whether the preparation count has reached its representable limit.
        public let attemptsSaturated: Bool
    }
    /// A completion admission decision; pending results remain queryable.
    public enum DeliveryResult: Sendable {
        case committed(Receipt)
        case pending(PendingCompletionID, PendingStatus)
        case inProgress
        case notPending
        case stale
        case foreignOwner
        case discarded(Receipt)
        case rejected(CommitRejection)
    }
    /// Whether this owner processed all offers and launch decisions through the receipt.
    public enum FlushResult: Equatable, Sendable { case processed, foreignOwner }
    /// An opaque identity for one preparation still executing during shutdown.
    public struct PreparationHandle: Equatable, Sendable {
        fileprivate let claim: RuntimeDeliveryClaim
    }
    /// A historical execution and delivery obligation retained at a shutdown deadline.
    public struct OutstandingExecution: Equatable, Sendable {
        /// The exact sealed operation whose physical termination is still tracked.
        public let execution: ExecutionHandle
        /// The execution disposition at the diagnostic observation.
        public let disposition: StateMachine.ShutdownDiagnostics.ExecutionDisposition
        /// The separate delivery disposition at the diagnostic observation.
        public let delivery: StateMachine.ShutdownDiagnostics.DeliveryDisposition
        /// The exclusive preparation still executing, when present.
        public let preparation: PreparationHandle?
    }
    /// Outstanding tracked obligations when a shutdown deadline expires.
    public struct ShutdownDiagnostics: Equatable, Sendable {
        /// The owner's final accepted revision at the diagnostic observation.
        public let acceptedRevision: UInt64
        /// The last receipt whose offers and launch decisions were processed.
        public let processedThrough: UInt64
        /// Whether accepted ordinary or terminal batches still await processing.
        public let hasQueuedBatches: Bool
        /// Whether a FIFO processing turn still owns responsibility.
        public let isDraining: Bool
        /// Whether an automatic retry of a retained completion is still scheduled.
        public let isRetrying: Bool
        /// The retained envelope identities at the diagnostic observation.
        public let pending: [PendingCompletionID]
        /// Execution and preparation identities that remain tracked after timeout.
        public let outstanding: [OutstandingExecution]
    }
    /// Whether shutdown joined all obligations or reached its reporting deadline.
    public enum ShutdownResult: Equatable, Sendable {
        case quiescent
        case timedOut(ShutdownDiagnostics)
    }
    /// A typed terminal fetch outcome carrying sealed authority.
    public enum FetchCompletion: Sendable {
        case success(FetchSuccessCompletion)
        case failure(FetchFailureCompletion)
    }
    /// The closed domain completion vocabulary.
    public enum Completion: Sendable {
        case fetch(FetchCompletion)
        case audit(AuditCompletion)
    }
    /// A successful fetch outcome bound to its issued operation.
    public struct FetchSuccessCompletion: Sendable {
        /// The successful fetch value.
        public let value: Fetch.Output
        fileprivate let authority: Authority
    }
    /// A failed fetch outcome bound to its issued operation.
    public struct FetchFailureCompletion: Sendable {
        /// The typed fetch failure.
        public let value: Fetch.Failure
        fileprivate let authority: Authority
    }
    /// An owner-bound execution acknowledgment capability.
    public struct ExecutionHandle: Equatable, Sendable { fileprivate let authority: Authority }
    /// The caller assertion that execution terminated or definitely never started.
    public enum ExecutionDisposition: Equatable, Sendable {
        case terminated
        case skippedBeforeStart
    }
    /// The result of an identity-checked execution acknowledgment.
    public enum AcknowledgmentResult: Equatable, Sendable {
        case recorded
        case duplicate
        case foreignOwner
    }
    /// Validated capacity bounds for shared and local ownership.
    public struct Configuration: Sendable {
        /// The maximum queued ordinary batch count.
        public let commitCapacity: Int
        /// The maximum descriptors in one plan.
        public let planCapacity: Int
        /// The maximum outstanding execution reservations.
        public let executionCapacity: Int
        /// The maximum live observation registrations.
        public let subscriberCapacity: Int
        /// Validates positive admission, plan, execution, and subscription capacities.
        public init(
            commitCapacity: Int = 256,
            planCapacity: Int = 64,
            executionCapacity: Int = 256,
            subscriberCapacity: Int = 128
        ) throws(ConfigurationFailure) {
            guard commitCapacity > 0, planCapacity > 0, executionCapacity > 0, subscriberCapacity > 0 else {
                throw .nonpositiveCapacity
            }
            self.commitCapacity = commitCapacity
            self.planCapacity = planCapacity
            self.executionCapacity = executionCapacity
            self.subscriberCapacity = subscriberCapacity
        }
        /// The default capacity bounds.
        public static var `default`: Self { try! Self() }
    }
    /// An invalid capacity configuration.
    public enum ConfigurationFailure: Error, Sendable { case nonpositiveCapacity }
    /// A temporal or transient admission rejection, in precedence order.
    public enum CommitRejection: Equatable, Sendable {
        case foreignOwner
        case closed
        /// The proposal's effect plan is defective, which preparation found before admission.
        case plan(PlanRejection)
        case obsoleteIncarnation
        case inactiveAuthority
        case conflict
        case operationPolicy(OperationPolicyFailure)
        case revisionExhausted
        case capacityExceeded(Capacity)
    }
    /// A schema-declared active-authority policy rejection.
    public enum OperationPolicyFailure: Equatable, Sendable {
        case alreadyActive
        case parallelLimit
    }
    /// The exhausted count bound.
    public enum Capacity: Equatable, Sendable {
        case commitQueue
        case executionReservations
    }
    /// Historical evidence that one root was admitted.
    public struct Receipt: Sendable {
        /// Copies the current historical observation.
        public let snapshot: Snapshot
        /// The owner-lifetime commit revision.
        public var revision: UInt64 { snapshot.revision }
    }
    /// Historical acceptance or a rejection with current observation.
    public enum CommitResult: Sendable {
        case committed(Receipt)
        case rejected(CommitRejection, current: Snapshot)
    }
    /// A typed start or cancellation command issued after admission.
    public enum Command: Sendable {
        case start(FetchWork)
        /// Starts a distinct accepted audit operation.
        case audit(AuditWork)
        case cancel(ExecutionHandle)
    }
    /// A complete FIFO batch for one accepted receipt.
    public struct CommandBatch: Sendable {
        /// The batch acceptance receipt.
        public let receipt: Receipt
        /// Commands in committed order.
        public let commands: [Command]
        /// Whether this is the reserved final lifecycle batch.
        public let terminal: Bool
    }
    /// A subscription request exceeding the configured live registration count.
    public enum SubscriptionFailure: Error, Sendable { case capacityExceeded }

    /// Explicit ownership of a callback registration.
    public struct Subscription: Sendable {
        fileprivate let cancellation: SubscriptionCancellation
        /// Unsubscribes; a callback already claimed by its delivery loop may finish.
        public func cancel() { cancellation.cancel() }
    }

    /// A synchronous, thread-safe managed owner.
    ///
    /// Copies alias one history. Typed drivers execute outside its atomic storage;
    /// a coordinator retains cancelled tasks until their actual termination.
    public struct Shared: Sendable {
        private typealias Host = RuntimeSharedHost<Record, Descriptor, Completion, CompletionPreparationRejection>
        private let host: Host
        private let configuration: Configuration
        private let drivers: Drivers?
        private let completionPolicy: CompletionConflictPolicy
        private let onReconciliationRequired: @Sendable (PendingCompletion) -> Void

        /// Creates a managed owner with immutable typed drivers and an explicit conflict policy.
        ///
        /// Reconciliation callbacks receive historical records after pending installation,
        /// outside the core lock. Driver and callback selections remain fixed for this history.
        public init(
            _ initial: Idle,
            drivers: Drivers,
            configuration: Configuration = .default,
            completionPolicy: CompletionConflictPolicy = .manualOnConflict,
            onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void = { _ in }
        ) {
            self.init(
                record: Record(model: .idle(initial)),
                drivers: drivers,
                configuration: configuration,
                completionPolicy: completionPolicy,
                onReconciliationRequired: onReconciliationRequired
            )
        }
        private init(
            record: Record,
            drivers: Drivers,
            configuration: Configuration,
            completionPolicy: CompletionConflictPolicy,
            onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void
        ) {
            self.configuration = configuration
            self.drivers = drivers
            self.completionPolicy = completionPolicy
            self.onReconciliationRequired = onReconciliationRequired
            host = Host(
                record,
                scopes: [RuntimeScopeID(kind: 1)],
                limits: Self.limits(configuration),
                subscriberCapacity: configuration.subscriberCapacity,
                policy: completionPolicy,
                driver: { raw in
                    switch raw.descriptor {
                    case .fetch(let input):
                        let work = FetchWork(input: input, authority: raw.ticket)
                        switch await drivers.fetch(input) {
                        case .success(let value): return .fetch(work.succeeded(value))
                        case .failure(let value): return .fetch(work.failed(value))
                        }
                    case .audit(let input):
                        let work = AuditWork(input: input, authority: raw.ticket)
                        switch await drivers.audit(input) {
                        case .success(let value): return .audit(work.succeeded(value))
                        case .failure(let value): return .audit(work.failed(value))
                        }
                    }
                },
                ticket: { ReferenceProfile.authority(of: $0) },
                prepare: { ReferenceProfile.prepareDelivery($0) },
                reconciliationRequired: { pending in onReconciliationRequired(Self.projectPending(pending)) }
            )
        }
        private static func limits(_ configuration: Configuration) -> Limits {
            // Configuration has already checked every capacity is positive.
            try! Limits(
                commits: configuration.commitCapacity,
                descriptors: configuration.planCapacity,
                executions: configuration.executionCapacity
            )
        }
        package init(_ initial: Idle, configuration: Configuration = .default) {
            self.configuration = configuration
            drivers = nil
            completionPolicy = .manualOnConflict
            onReconciliationRequired = { _ in }
            host = Host(
                manual: Record(model: .idle(initial)),
                scopes: [RuntimeScopeID(kind: 1)],
                limits: Self.limits(configuration),
                subscriberCapacity: configuration.subscriberCapacity,
                ticket: { ReferenceProfile.authority(of: $0) },
                prepare: { ReferenceProfile.prepareDelivery($0) }
            )
        }
        package init(
            _ initial: Idle,
            configuration: Configuration = .default,
            consumeBatch: @escaping @Sendable (CommandBatch) -> Void
        ) {
            self.init(
                initial,
                configuration: configuration,
                cancel: { _ in },
                start: { _ in },
                processed: { consumeBatch($0) }
            )
        }
        package init(
            _ initial: Idle,
            configuration: Configuration = .default,
            cancel: @escaping @Sendable ([ExecutionHandle]) async -> Void,
            start: @escaping @Sendable ([Command]) async -> Void,
            processed: @escaping @Sendable (CommandBatch) async -> Void
        ) {
            self.configuration = configuration
            drivers = nil
            completionPolicy = .manualOnConflict
            onReconciliationRequired = { _ in }
            host = Host(
                manual: Record(model: .idle(initial)),
                scopes: [RuntimeScopeID(kind: 1)],
                limits: Self.limits(configuration),
                subscriberCapacity: configuration.subscriberCapacity,
                cancel: { await cancel($0.map { ExecutionHandle(authority: $0) }) },
                start: { await start($0.map { Self.start($0) }) },
                processed: { await processed(Self.batch($0, configuration: configuration)) },
                ticket: { ReferenceProfile.authority(of: $0) },
                prepare: { ReferenceProfile.prepareDelivery($0) }
            )
        }
        private init(archive: Archive, configuration: Configuration) {
            self.configuration = configuration
            drivers = nil
            completionPolicy = .manualOnConflict
            onReconciliationRequired = { _ in }
            host = Host(
                manual: Record(model: archive.model, presentation: archive.presentation),
                scopes: [RuntimeScopeID(kind: 1)],
                limits: Self.limits(configuration),
                subscriberCapacity: configuration.subscriberCapacity,
                ticket: { ReferenceProfile.authority(of: $0) },
                prepare: { ReferenceProfile.prepareDelivery($0) }
            )
        }
        /// Restores validated data with fresh owner identity and operation authority.
        public static func restore(
            _ archive: Archive,
            drivers: Drivers,
            configuration: Configuration = .default,
            completionPolicy: CompletionConflictPolicy = .manualOnConflict,
            onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void = { _ in }
        ) -> Shared {
            Shared(
                record: Record(model: archive.model, presentation: archive.presentation),
                drivers: drivers,
                configuration: configuration,
                completionPolicy: completionPolicy,
                onReconciliationRequired: onReconciliationRequired
            )
        }
        package static func restore(_ archive: Archive, configuration: Configuration = .default) -> Shared {
            Shared(archive: archive, configuration: configuration)
        }
        /// Captures one coherent historical observation.
        public func snapshot() -> Snapshot { State.project(host.snapshot(), configuration: configuration) }
        /// Creates an independent history from validated ordinary model data.
        public func fork() throws(RestoreRejection) -> Shared {
            let current = host.snapshot().model
            let archive = try Archive(model: current.model, presentation: current.presentation)
            if let drivers {
                return Shared.restore(
                    archive,
                    drivers: drivers,
                    configuration: configuration,
                    completionPolicy: completionPolicy,
                    onReconciliationRequired: onReconciliationRequired
                )
            }
            return Shared(archive: archive, configuration: configuration)
        }
        /// Consumes an inert candidate into one atomic admission attempt.
        public func commit(_ prepared: consuming Prepared) -> CommitResult {
            switch prepared.payload {
            case .payload(let payload): return project(host.commit(payload.candidate))
            case .defective(let defect): return project(host.reject(defect))
            }
        }
        /// Registers a capacity-one serial latest-value callback outside host locks.
        public func subscribe(
            _ receive: @escaping @Sendable (Snapshot) -> Void,
            onFinish: @escaping @Sendable () -> Void = {}
        ) throws(SubscriptionFailure) -> Subscription {
            do {
                let subscription = try host.subscribe(
                    { [configuration] in receive(State.project($0, configuration: configuration)) },
                    onFinish: onFinish
                )
                return Subscription(cancellation: SubscriptionCancellation { subscription.cancel() })
            } catch { throw .capacityExceeded }
        }
        /// Registers a single-pass sequence of the latest complete observations.
        public func snapshots() throws(SubscriptionFailure) -> SnapshotSequence<Snapshot> {
            do {
                return try host.snapshots { [configuration] in State.project($0, configuration: configuration) }
            } catch { throw .capacityExceeded }
        }
        /// Installs validated data with fresh incarnation and monotonically increasing revision.
        public func reset(_ archive: Archive, expected: Snapshot) -> CommitResult {
            project(
                host.commit(
                    Payload(
                        stamp: expected.stamp,
                        record: Record(model: archive.model, presentation: archive.presentation),
                        action: .reset
                    )
                    .candidate
                )
            )
        }
        /// Ends admission with the reserved terminal slot while retaining read access.
        @discardableResult
        public func close() -> Receipt { Receipt(snapshot: State.project(host.close(), configuration: configuration)) }
        package func drainCommands(limit: Int) -> [CommandBatch] {
            host.drainCommands(limit: limit).map { Self.batch($0, configuration: configuration) }
        }
        package func isExecutionAuthorized(_ execution: ExecutionHandle) -> Bool { host.isActive(execution.authority) }
        package func acknowledgeExecution(
            _ execution: ExecutionHandle,
            disposition: ExecutionDisposition
        ) -> AcknowledgmentResult {
            switch host.acknowledge(execution.authority, skipped: disposition == .skippedBeforeStart) {
            case .recorded: return .recorded
            case .duplicate: return .duplicate
            case .foreignOwner: return .foreignOwner
            }
        }
        /// Whether closure, FIFO transfer, and actual execution and delivery obligations have settled.
        public var isQuiescent: Bool { host.isQuiescent }
        private static func batch(_ raw: Engine.Batch, configuration: Configuration) -> CommandBatch {
            CommandBatch(
                receipt: Receipt(snapshot: State.project(raw.snapshot, configuration: configuration)),
                commands: raw.commands.map { command in
                    switch command {
                    case .cancel(let ticket): return .cancel(ExecutionHandle(authority: ticket))
                    case .start(let work): return Self.start(work)
                    }
                },
                terminal: raw.terminal
            )
        }
        private static func start(_ work: RuntimeWork<Descriptor>) -> Command {
            switch work.descriptor {
            case .fetch(let input): return .start(FetchWork(input: input, authority: work.ticket))
            case .audit(let input): return .audit(AuditWork(input: input, authority: work.ticket))
            }
        }
        private func project(_ admission: Engine.Admission) -> CommitResult {
            switch admission {
            case .committed(let record):
                return .committed(Receipt(snapshot: State.project(record, configuration: configuration)))
            case .rejected(let reason, let current):
                return .rejected(Self.rejection(reason), current: State.project(current, configuration: configuration))
            }
        }
        private static func rejection(_ reason: Engine.Rejection) -> CommitRejection {
            switch reason {
            case .plan(let plan): return .plan(plan)
            case .foreignOwner: return .foreignOwner
            case .closed: return .closed
            case .obsoleteIncarnation: return .obsoleteIncarnation
            case .inactiveAuthority: return .inactiveAuthority
            case .conflict: return .conflict
            case .operationPolicy(.alreadyActive): return .operationPolicy(.alreadyActive)
            case .operationPolicy(.parallelLimit): return .operationPolicy(.parallelLimit)
            case .revisionExhausted: return .revisionExhausted
            case .capacityExceeded(.commitQueue): return .capacityExceeded(.commitQueue)
            case .capacityExceeded(.executionReservations): return .capacityExceeded(.executionReservations)
            }
        }
        private func project(_ result: Host.Delivery) -> DeliveryResult {
            switch result {
            case .committed(let stamp):
                return .committed(Receipt(snapshot: State.project(stamp, configuration: configuration)))
            case .pending(let id, let status): return .pending(id, status)
            case .inProgress: return .inProgress
            case .notPending: return .notPending
            case .stale: return .stale
            case .foreignOwner: return .foreignOwner
            case .discarded(let stamp):
                return .discarded(Receipt(snapshot: State.project(stamp, configuration: configuration)))
            case .rejected(let reason): return .rejected(Self.rejection(reason))
            }
        }
        /// Queries typed historical first-outcome records without claiming preparation.
        public func pendingCompletions() -> [PendingCompletion] { host.pendingCompletions().map(Self.projectPending) }
        private static func projectPending(_ pending: Ledger.Pending) -> PendingCompletion {
            let reason: CompletionRejection?
            switch pending.lastRejection {
            case .preparation(let failure): reason = .preparation(failure)
            case .admission(let rejection): reason = .commit(Self.rejection(rejection))
            case nil: reason = nil
            }
            return PendingCompletion(
                id: pending.id,
                outcome: pending.outcome,
                status: pending.status,
                lastRejection: reason,
                attemptCount: pending.attempts,
                attemptsSaturated: pending.attemptsSaturated
            )
        }
        /// Retains and attempts delivery using the common managed first-envelope algorithm.
        public func deliver(_ completion: Completion) -> DeliveryResult { project(host.deliver(completion)) }
        /// Claims exactly one fresh preparation for a retained terminal outcome.
        public func reconcile(id: PendingCompletionID) -> DeliveryResult { project(host.reconcile(id: id)) }
        /// Revokes retained authority through an ordinary atomic commit.
        public func discardPending(id: PendingCompletionID) -> DeliveryResult { project(host.discardPending(id: id)) }
        /// Waits for FIFO snapshot offers and launch decisions through this owner's receipt.
        public func flush(through receipt: Receipt) async -> FlushResult {
            await host.flush(through: receipt.snapshot.stamp) ? .processed : .foreignOwner
        }
        /// Closes and waits for actual task termination and preparation claim exit, bounded by an optional deadline.
        ///
        /// A timeout reports the obligations observed in the same atomic load that found the deadline expired.
        @discardableResult
        public func shutdown(deadline: ContinuousClock.Instant? = nil) async -> ShutdownResult {
            guard let diagnostics = await host.shutdownWithAuthority(deadline: deadline) else { return .quiescent }
            return .timedOut(
                .init(
                    acceptedRevision: diagnostics.acceptedRevision,
                    processedThrough: diagnostics.processedThrough,
                    hasQueuedBatches: diagnostics.hasQueuedBatches,
                    isDraining: diagnostics.isDraining,
                    isRetrying: diagnostics.isRetrying,
                    pending: diagnostics.pending,
                    outstanding: diagnostics.outstanding.map { reservation in
                        .init(
                            execution: .init(authority: reservation.ticket),
                            disposition: reservation.execution,
                            delivery: reservation.delivery,
                            preparation: reservation.preparationClaim.map { .init(claim: $0) }
                        )
                    }
                )
            )
        }
    }

    /// A manually driven owner.
    ///
    /// Drained work must be acknowledged after actual termination or definite nonstart.
    public struct Local: ~Copyable {
        fileprivate var state: State
        /// Creates a local owner in the declared initial phase.
        public init(_ initial: Idle, configuration: Configuration = .default) {
            state = State(record: Record(model: .idle(initial)), configuration: configuration)
        }
        fileprivate init(archive: Archive, configuration: Configuration) {
            state = State(
                record: Record(model: archive.model, presentation: archive.presentation),
                configuration: configuration
            )
        }
        /// Creates a fresh owner from validated data, without adopting live authority.
        public static func restore(_ archive: Archive, configuration: Configuration = .default) -> Local {
            Local(archive: archive, configuration: configuration)
        }
        /// Copies the current historical observation.
        public borrowing func snapshot() -> Snapshot { state.snapshot() }
        /// Creates a fresh history from the current validated data.
        public borrowing func fork() throws(RestoreRejection) -> Local {
            let archive = try Archive(model: state.record.model, presentation: state.record.presentation)
            return Local(archive: archive, configuration: state.configuration)
        }
        /// Attempts validated replacement with a fresh incarnation and monotonic revision.
        public mutating func reset(_ archive: Archive, expected: Snapshot) -> CommitResult {
            let payload = Payload(
                stamp: expected.stamp,
                record: Record(model: archive.model, presentation: archive.presentation),
                action: .reset
            )
            return state.commit(payload)
        }
        /// Consumes a proposal and checks owner, incarnation, authority, freshness, and capacities.
        public mutating func commit(_ prepared: consuming Prepared) -> CommitResult {
            switch prepared.payload {
            case .payload(let payload): return state.commit(payload)
            case .defective(let defect): return state.project(state.engine.reject(defect))
            }
        }
        /// Irreversibly closes using the reserved terminal record.
        @discardableResult
        public mutating func close() -> Receipt { state.close() }
        /// Transfers up to the requested number of whole FIFO batches.
        public mutating func drainCommands(limit: Int) -> [CommandBatch] { state.drain(limit: limit) }
        /// Records actual termination independently of result admission.
        public mutating func acknowledgeExecution(
            _ execution: ExecutionHandle,
            disposition: ExecutionDisposition
        ) -> AcknowledgmentResult { state.acknowledge(execution, disposition: disposition) }
        /// Whether closure, terminal draining, and issued execution obligations are complete.
        public var isQuiescent: Bool {
            state.isQuiescent
        }
    }
}

extension ReferenceProfile.Owned where Phase == ReferenceProfile.Idle {
    /// Validates the request and advances through the declared load edge.
    public consuming func load(
        _ request: ProfileRequest
    ) -> Advance<
        Self, ReferenceProfile.Owned<ReferenceProfile.Loading>, ReferenceProfile.Effect, ReferenceProfile.LoadRejection
    > {
        guard request.userID == phase.userID else { return .rejected(.wrongUser, self) }
        return .advanced(
            ReferenceProfile.Owned(ReferenceProfile.Loading(request: request)),
            effects: [.fetch(request)]
        )
    }
}
extension ReferenceProfile.Owned where Phase == ReferenceProfile.Loading {
    /// Advances through the declared success edge.
    public consuming func received(
        _ profile: Profile
    ) -> Change<ReferenceProfile.Owned<ReferenceProfile.Loaded>, ReferenceProfile.Effect> {
        Change(ReferenceProfile.Owned(ReferenceProfile.Loaded(profile: profile)))
    }
    /// Advances through the declared failure edge.
    public consuming func failed(
        _ failure: ProfileFailure
    ) -> Change<ReferenceProfile.Owned<ReferenceProfile.Failed>, ReferenceProfile.Effect> {
        Change(ReferenceProfile.Owned(ReferenceProfile.Failed(request: phase.request, failure: failure)))
    }
    /// Advances through the declared cancellation edge.
    public consuming func cancel() -> Change<ReferenceProfile.Owned<ReferenceProfile.Idle>, ReferenceProfile.Effect> {
        Change(ReferenceProfile.Owned(ReferenceProfile.Idle(userID: phase.request.userID)))
    }
}
extension ReferenceProfile.Owned where Phase == ReferenceProfile.Loaded {
    /// Validates a request and advances through the refresh edge.
    public consuming func refresh(
        _ request: ProfileRequest
    ) -> Advance<
        Self, ReferenceProfile.Owned<ReferenceProfile.Loading>, ReferenceProfile.Effect, ReferenceProfile.LoadRejection
    > {
        guard request.userID == phase.profile.userID else { return .rejected(.wrongUser, self) }
        return .advanced(
            ReferenceProfile.Owned(ReferenceProfile.Loading(request: request)),
            effects: [.fetch(request)]
        )
    }
}
extension ReferenceProfile.Owned where Phase == ReferenceProfile.Failed {
    /// Advances through the declared retry edge.
    public consuming func retry() -> Change<ReferenceProfile.Owned<ReferenceProfile.Loading>, ReferenceProfile.Effect> {
        Change(
            ReferenceProfile.Owned(ReferenceProfile.Loading(request: phase.request)),
            effects: [.fetch(phase.request)]
        )
    }
}
extension ReferenceProfile.Observed where Phase == ReferenceProfile.Idle {
    /// Validates the request and prepares the declared load edge.
    public func load(
        _ request: ProfileRequest
    ) throws(ReferenceProfile.LoadRejection) -> ReferenceProfile.Prepared {
        guard request.userID == payload.userID else { throw .wrongUser }
        var next = record
        next.model = .loading(ReferenceProfile.Loading(request: request))
        return ReferenceProfile.Prepared(starting: .fetch(request), stamp: stamp, record: next)
    }
}
extension ReferenceProfile.Observed where Phase == ReferenceProfile.Loading {
    /// Prepares the success edge using a sealed fetch completion.
    public func received(
        _ completion: ReferenceProfile.FetchSuccessCompletion
    ) -> ReferenceProfile.Prepared {
        var next = record
        next.model = .loaded(ReferenceProfile.Loaded(profile: completion.value))
        return ReferenceProfile.Prepared(
            ReferenceProfile.Payload(stamp: stamp, record: next, action: .terminal(completion.authority))
        )
    }
    /// Prepares the failure edge using a sealed fetch completion.
    public func failed(
        _ completion: ReferenceProfile.FetchFailureCompletion
    ) -> ReferenceProfile.Prepared {
        var next = record
        next.model = .failed(ReferenceProfile.Failed(request: payload.request, failure: completion.value))
        return ReferenceProfile.Prepared(
            ReferenceProfile.Payload(stamp: stamp, record: next, action: .terminal(completion.authority))
        )
    }
    /// Prepares the declared cancellation edge.
    public func cancel() -> ReferenceProfile.Prepared {
        var next = record
        next.model = .idle(ReferenceProfile.Idle(userID: payload.request.userID))
        return ReferenceProfile.Prepared(ReferenceProfile.Payload(stamp: stamp, record: next, action: .cancel))
    }
}
extension ReferenceProfile.Observed where Phase == ReferenceProfile.Loaded {
    /// Validates a request and prepares the refresh edge.
    public func refresh(
        _ request: ProfileRequest
    ) throws(ReferenceProfile.LoadRejection) -> ReferenceProfile.Prepared {
        guard request.userID == payload.profile.userID else { throw .wrongUser }
        var next = record
        next.model = .loading(ReferenceProfile.Loading(request: request))
        return ReferenceProfile.Prepared(starting: .fetch(request), stamp: stamp, record: next)
    }
}
extension ReferenceProfile.Observed where Phase == ReferenceProfile.Failed {
    /// Prepares the declared retry edge.
    public func retry() -> ReferenceProfile.Prepared {
        var next = record
        next.model = .loading(ReferenceProfile.Loading(request: payload.request))
        return ReferenceProfile.Prepared(starting: .fetch(payload.request), stamp: stamp, record: next)
    }
}

extension ReferenceProfile.Prepared {
    /// Prepares a start, carrying a plan defect to admission instead of throwing it.
    fileprivate init(
        starting start: ReferenceProfile.Descriptor,
        stamp: ReferenceProfile.Stamp,
        record: ReferenceProfile.Record
    ) {
        do throws(PlanRejection) {
            self.init(try ReferenceProfile.Payload(stamp: stamp, record: record, start: start))
        } catch { self.init(defect: ReferenceProfile.Engine.DefectivePlan(error, preparedOn: stamp)) }
    }
}

extension ReferenceProfile {
    fileprivate final class SubscriptionCancellation: Sendable {
        private let storage: AtomicRecordStorage<(@Sendable () -> Void)?>
        init(_ action: @escaping @Sendable () -> Void) { storage = AtomicRecordStorage(action) }
        func cancel() {
            while true {
                let previous = storage.load()
                guard let action = previous.value else { return }
                if storage.install(.init(nil), replacing: previous) {
                    action()
                    return
                }
            }
        }
        deinit { storage.load().value?() }
    }
    fileprivate typealias Identity = RuntimeIdentity
    fileprivate enum Descriptor: Sendable {
        case fetch(ProfileRequest)
        case audit(String)
    }
    fileprivate typealias Engine = RuntimeState<Record, Descriptor>
    fileprivate typealias Ledger = RuntimeDeliveryLedger<
        Record, Descriptor, Completion, CompletionPreparationRejection
    >
    fileprivate typealias Stamp = Engine.Snapshot
    fileprivate typealias Authority = RuntimeTicket
    fileprivate struct Record: Sendable {
        var model: Model
        var presentation = ""
        var closed = false
    }
    fileprivate enum Action: Sendable {
        case preserve
        case auditTerminal(Authority)
        case terminal(Authority)
        case cancel
        case invalidateAuthentication
        case reset
    }
    fileprivate struct Payload: Sendable {
        let candidate: Engine.Candidate
        init(stamp: Stamp, record: Record, start: Descriptor) throws(PlanRejection) {
            let load = RuntimeScopeID(kind: 0)
            let authentication = RuntimeScopeID(kind: 1)
            let plan: Engine.Plan
            switch start {
            case .fetch(let request):
                plan = .init(
                    scopes: [.activate(load)],
                    starts: [
                        .init(.init(kind: 0, scope: load, dependencies: [authentication]), descriptor: .fetch(request))
                    ]
                )
            case .audit(let input):
                plan = .init(starts: [
                    .init(
                        .init(kind: 1, scope: load, dependencies: [authentication], policy: .parallel(2)),
                        descriptor: .audit(input)
                    )
                ])
            }
            candidate = try Engine.prepare(on: stamp, next: record, plan: plan)
        }
        init(stamp: Stamp, record: Record, action: Action, finishingClaims: [RuntimeDeliveryClaim] = []) {
            let load = RuntimeScopeID(kind: 0)
            let authentication = RuntimeScopeID(kind: 1)
            let plan: Engine.Plan
            let required: [Authority]
            switch action {
            case .preserve:
                plan = .init()
                required = []
            case .auditTerminal(let authority):
                plan = .init(retire: [authority], finishingClaims: finishingClaims)
                required = [authority]
            case .terminal(let authority):
                plan = .init(scopes: [.remove(load)], retire: [authority], finishingClaims: finishingClaims)
                required = [authority]
            case .cancel:
                plan = .init(scopes: [.remove(load)], controlCount: 1)
                required = []
            case .invalidateAuthentication:
                plan = .init(scopes: [.activate(authentication)], controlCount: 1)
                required = []
            case .reset:
                plan = .init(scopes: [.remove(load)], reset: true, controlCount: 1)
                required = []
            }
            // These control-only plans contain no eligible starts and at most one
            // explicit descriptor. Validated positive limits admit them even after close.
            // Start plans have a separate throwing initializer above.
            candidate = try! Engine.prepare(on: stamp, next: record, requiring: required, plan: plan)
        }
    }
    fileprivate struct Subscriber: Sendable {
        let identity: Identity
        let mailbox: LatestMailbox<Snapshot>
    }
    fileprivate struct State: Sendable {
        var subscribers: [Subscriber] = []
        var drainerScheduled = false
        var ready = RuntimeDeliveryReadyQueue()
        let configuration: Configuration
        fileprivate var engine: Engine
        fileprivate var ledger = Ledger()

        init(record: Record, configuration: Configuration) {
            self.configuration = configuration
            engine = Engine(
                record,
                scopes: [RuntimeScopeID(kind: 1)],
                limits: try! Limits(
                    commits: configuration.commitCapacity,
                    descriptors: configuration.planCapacity,
                    executions: configuration.executionCapacity
                ),
                // The caller receives every commandless receipt from the commit itself.
                recording: .commands
            )
        }
        mutating func retryCapacity() -> [RuntimePendingID] {
            let results = ledger.retryCapacity(in: &engine)
            ready.prune(keeping: ledger.pending.map(\.id))
            return results.compactMap { result in
                guard case .pending(let id, _) = result,
                    ledger.pending.first(where: { $0.id == id })?.lastRejection == .admission(.conflict)
                else { return nil }
                return id
            }
        }
        var record: Record { engine.snapshot.model }
        var isQuiescent: Bool { engine.isQuiescent && !drainerScheduled && ready.isIdle }
        var hasQueuedBatches: Bool { engine.hasQueuedBatches }
        var hasTerminal: Bool { engine.snapshot.isClosed && engine.hasQueuedBatches }
        func snapshot() -> Snapshot { Self.project(engine.snapshot, configuration: configuration) }
        fileprivate static func project(_ stamp: Stamp, configuration: Configuration) -> Snapshot {
            var record = stamp.model
            record.closed = stamp.isClosed
            return switch record.model {
            case .idle(let value):
                .idle(Observed(payload: value, record: record, stamp: stamp, configuration: configuration))
            case .loading(let value):
                .loading(Observed(payload: value, record: record, stamp: stamp, configuration: configuration))
            case .loaded(let value):
                .loaded(Observed(payload: value, record: record, stamp: stamp, configuration: configuration))
            case .failed(let value):
                .failed(Observed(payload: value, record: record, stamp: stamp, configuration: configuration))
            }
        }
        func isActive(_ authority: Authority) -> Bool { engine.isActive(authority) }
        mutating func commit(_ payload: Payload) -> CommitResult {
            let admission = engine.commit(payload.candidate)
            if case .committed = admission {
                ledger.prune(in: engine)
                ready.prune(keeping: ledger.pending.map(\.id))
            }
            return project(admission)
        }
        func project(_ admission: Engine.Admission) -> CommitResult {
            switch admission {
            case .committed(let snapshot):
                return .committed(Receipt(snapshot: Self.project(snapshot, configuration: configuration)))
            case .rejected(let reason, let current):
                let rejection: CommitRejection
                switch reason {
                case .plan(let plan): rejection = .plan(plan)
                case .foreignOwner: rejection = .foreignOwner
                case .closed: rejection = .closed
                case .obsoleteIncarnation: rejection = .obsoleteIncarnation
                case .inactiveAuthority: rejection = .inactiveAuthority
                case .conflict: rejection = .conflict
                case .operationPolicy(.alreadyActive): rejection = .operationPolicy(.alreadyActive)
                case .operationPolicy(.parallelLimit): rejection = .operationPolicy(.parallelLimit)
                case .revisionExhausted: rejection = .revisionExhausted
                case .capacityExceeded(.commitQueue): rejection = .capacityExceeded(.commitQueue)
                case .capacityExceeded(.executionReservations): rejection = .capacityExceeded(.executionReservations)
                }
                return .rejected(rejection, current: Self.project(current, configuration: configuration))
            }
        }
        mutating func close() -> Receipt {
            let receipt = Receipt(snapshot: Self.project(engine.close(), configuration: configuration))
            ledger.prune(in: engine)
            ready.prune(keeping: [])
            return receipt
        }
        mutating func drain(limit: Int) -> [CommandBatch] {
            engine.drain(limit: limit)
                .map { batch in
                    CommandBatch(
                        receipt: Receipt(snapshot: Self.project(batch.snapshot, configuration: configuration)),
                        commands: batch.commands.map { command in
                            switch command {
                            case .cancel(let ticket): .cancel(ExecutionHandle(authority: ticket))
                            case .start(let work):
                                switch work.descriptor {
                                case .fetch(let input): .start(FetchWork(input: input, authority: work.ticket))
                                case .audit(let input): .audit(AuditWork(input: input, authority: work.ticket))
                                }
                            }
                        },
                        terminal: batch.terminal
                    )
                }
        }
        mutating func acknowledge(
            _ execution: ExecutionHandle,
            disposition: ExecutionDisposition = .terminated
        ) -> AcknowledgmentResult {
            switch engine.acknowledge(execution.authority, skippedBeforeStart: disposition == .skippedBeforeStart) {
            case .recorded: .recorded
            case .duplicate: .duplicate
            case .foreignOwner: .foreignOwner
            }
        }
    }
}

extension ReferenceProfile {
    fileprivate static func authority(of completion: Completion) -> Authority {
        switch completion {
        case .fetch(.success(let value)): value.authority
        case .fetch(.failure(let value)): value.authority
        case .audit(.success(let value)): value.authority
        case .audit(.failure(let value)): value.authority
        }
    }
    fileprivate static func prepareDelivery(_ attempt: Ledger.Attempt) -> Ledger.Preparation {
        var record = attempt.snapshot.model
        guard case .loading(let loading) = record.model else { return .failure(.preparation(.wrongPhase)) }
        switch attempt.outcome {
        case .fetch(.success(let value)): record.model = .loaded(Loaded(profile: value.value))
        case .fetch(.failure(let value)):
            record.model = .failed(Failed(request: loading.request, failure: value.value))
        case .audit: break
        }
        return .success(
            Payload(
                stamp: attempt.snapshot,
                record: record,
                action: {
                    if case .audit = attempt.outcome { return .auditTerminal(authority(of: attempt.outcome)) }
                    return .terminal(authority(of: attempt.outcome))
                }(),
                finishingClaims: [attempt.claim]
            )
            .candidate
        )
    }
}

extension ReferenceProfile.State {
    fileprivate func pendingCompletions() -> [ReferenceProfile.PendingCompletion] {
        ledger.pending.map { pending in
            let reason: ReferenceProfile.CompletionRejection?
            switch pending.lastRejection {
            case .preparation(let failure): reason = .preparation(failure)
            case .admission(let rejection):
                if case .rejected(let projected, _) = project(.rejected(rejection, current: engine.snapshot)) {
                    reason = .commit(projected)
                } else {
                    reason = nil
                }
            case nil: reason = nil
            }
            return ReferenceProfile.PendingCompletion(
                id: pending.id,
                outcome: pending.outcome,
                status: pending.status,
                lastRejection: reason,
                attemptCount: pending.attempts,
                attemptsSaturated: pending.attemptsSaturated
            )
        }
    }
}

extension ReferenceProfile.Local {
    /// Returns typed historical pending outcomes without automatic execution.
    public borrowing func pendingCompletions() -> [ReferenceProfile.PendingCompletion] { state.pendingCompletions() }
    /// Retains the first outcome and prepares it synchronously under caller ownership.
    public mutating func deliver(_ completion: ReferenceProfile.Completion) -> ReferenceProfile.DeliveryResult {
        let existing = state.ledger.pending.map(\.id)
        switch state.ledger.retain(completion, for: ReferenceProfile.authority(of: completion), in: &state.engine) {
        case .stale: return .stale
        case .foreignOwner: return .foreignOwner
        case .pending(let id):
            if existing.contains(id), let pending = state.ledger.pending.first(where: { $0.id == id }) {
                return .pending(id, pending.status)
            }
            return reconcile(id: id)
        }
    }
    /// Authorizes one fresh preparation of a retained outcome.
    public mutating func reconcile(id: ReferenceProfile.PendingCompletionID) -> ReferenceProfile.DeliveryResult {
        switch state.ledger.claim(id, in: &state.engine) {
        case .notPending: return .notPending
        case .inProgress: return .inProgress
        case .claimed(let attempt):
            let preparation = ReferenceProfile.prepareDelivery(attempt)
            switch state.ledger.finish(attempt, preparation: preparation, in: &state.engine) {
            case .notPending: return .notPending
            case .pending(let id, let status): return .pending(id, status)
            case .committed(let stamp):
                return .committed(
                    .init(snapshot: ReferenceProfile.State.project(stamp, configuration: state.configuration))
                )
            }
        }
    }
    /// Revokes pending authority through an ordinary commit; rejection preserves the envelope.
    public mutating func discardPending(id: ReferenceProfile.PendingCompletionID) -> ReferenceProfile.DeliveryResult {
        guard let result = state.ledger.discard(id, in: &state.engine) else { return .notPending }
        switch state.project(result) {
        case .committed(let receipt): return .discarded(receipt)
        case .rejected(let rejection, _): return .rejected(rejection)
        }
    }
}

extension ReferenceProfile.Observed where Phase == ReferenceProfile.Loading {
    /// Prepares an independent audit without replacing the active fetch epoch.
    public func audit(_ input: ReferenceProfile.Audit.Input) -> ReferenceProfile.Prepared {
        ReferenceProfile.Prepared(starting: .audit(input), stamp: stamp, record: record)
    }
    /// Retires only the accepted audit operation using its sealed successful outcome.
    public func audited(_ completion: ReferenceProfile.AuditSuccessCompletion) -> ReferenceProfile.Prepared {
        ReferenceProfile.Prepared(
            ReferenceProfile.Payload(stamp: stamp, record: record, action: .auditTerminal(completion.authority))
        )
    }
    /// Retires only the accepted audit operation using its sealed failed outcome.
    public func auditFailed(_ completion: ReferenceProfile.AuditFailureCompletion) -> ReferenceProfile.Prepared {
        ReferenceProfile.Prepared(
            ReferenceProfile.Payload(stamp: stamp, record: record, action: .auditTerminal(completion.authority))
        )
    }
}
