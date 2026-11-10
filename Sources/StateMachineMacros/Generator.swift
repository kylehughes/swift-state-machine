import Foundation
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder

struct Generator {
    let schema: Schema
    var name: String { schema.name }
    var access: String {
        let declared = schema.access == .private ? Schema.Access.fileprivate : schema.access
        return declared.rawValue + " "
    }
    var sendable: String { schema.mode == .shared ? ": Sendable" : "" }
    var initialType: String { schema.phases.first { $0.caseName == schema.initial }!.typeName }
    var engine: String { "RuntimeState<\(name), Effect>" }
    func declaration(_ source: String) -> DeclSyntax { DeclSyntax(stringLiteral: source) }

    func members() throws -> [DeclSyntax] {
        var result = [witnesses(), effects(), owned()]
        if schema.mode != .ownedOnly {
            result += [values(), operations(), preparation(), local(), managed(mainActor: true)]
            if schema.mode == .shared { result += [shared(), managed(mainActor: false)] }
        }
        return result.flatMap { source in
            Parser.parse(source: source).statements.compactMap { $0.item.as(DeclSyntax.self) }
        }
    }

    /// The effect type an authored edge names, or `Never` when it starts nothing.
    func authoredEffect(_ edge: Schema.Transition) -> String {
        edge.effectNamespace.map { "Effect.\($0)" } ?? "Never"
    }

    func witnesses() -> String {
        func triggerPayload(_ trigger: Schema.Trigger) -> String {
            switch trigger.kind {
            case .input: schema.inputs.first { $0.caseName == trigger.name }!.payloadType!
            case .success: "\(operation(trigger.name).name).Output"
            case .failure: "\(operation(trigger.name).name).Failure"
            }
        }
        let edges = schema.transitions
            .map { edge in
                let before = phase(edge.from)
                let result: String
                switch edge.shape {
                case .destination: result = phase(edge.to)
                case .change: result = "Change<\(phase(edge.to)), \(authoredEffect(edge))>"
                case .advance:
                    result =
                        "Advance<\(before), \(phase(edge.to)), \(authoredEffect(edge)), \(edge.failureType ?? "Never")>"
                }
                var lines = [
                    "let _: _TransitionSourceIsPhasePayload<\(before)> = _TransitionSourceIsPhasePayload<\(edge.sourceType)>()",
                    "let _: _TransitionReturnsDeclaredResult<\(result)> = _TransitionReturnsDeclaredResult<\(edge.returnType)>()",
                ]
                if let payload = edge.payloadType {
                    lines.append(
                        "let _: _TriggerPayloadMatchesDeclaration<\(triggerPayload(edge.trigger))> = _TriggerPayloadMatchesDeclaration<\(payload)>()"
                    )
                }
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n")
        let operationWitnesses = schema.operations
            .map { "let _ = _OperationFailureIsError<\($0.name).Failure>()" }
            .joined(separator: "\n")
        let routeWitnesses = schema.routes
            .map { route in
                var lines = [
                    "let _: _RouterSourceIsPhasePayload<\(phase(route.from))> = _RouterSourceIsPhasePayload<\(route.sourceType)>()"
                ]
                if let payload = route.payloadType {
                    lines.append(
                        "let _: _TriggerPayloadMatchesDeclaration<\(triggerPayload(route.trigger))> = _TriggerPayloadMatchesDeclaration<\(payload)>()"
                    )
                }
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n")
        return """
            fileprivate struct _TransitionSourceIsPhasePayload<Value: ~Copyable> {}
            fileprivate struct _TransitionReturnsDeclaredResult<Value: ~Copyable> {}
            fileprivate struct _TriggerPayloadMatchesDeclaration<Value: ~Copyable> {}
            fileprivate struct _RouterSourceIsPhasePayload<Value: ~Copyable> {}
            fileprivate struct _SharedModeRequiresSendable<Value: Sendable> {}
            fileprivate struct _OperationFailureIsError<Value: Error> {}
            fileprivate struct _EffectIsCopyable<Value> {}
            fileprivate static func _stateMachineWitnesses() {
                \(edges)
                \(operationWitnesses)
                \(routeWitnesses)
                let _ = _EffectIsCopyable<Effect>()
                \(schema.mode == .shared ? "let _ = _SharedModeRequiresSendable<Input>(); let _ = _SharedModeRequiresSendable<Effect>()" : "")
            }
            """
    }

    /// The schema-wide effect vocabulary and one narrowed vocabulary per edge that starts work.
    func effects() -> String {
        let conformance: String
        switch schema.mode {
        case .shared: conformance = ": Sendable"
        case .isolated: conformance = ": ~Sendable"
        case .ownedOnly: conformance = ""
        }
        // Names are schema-qualified because a per-edge type such as `Effect.Save` would otherwise
        // shadow an operation namespace of the same name.
        func cases(_ operations: [Schema.Operation]) -> String {
            operations.map { "case \($0.effect)(\(name).\($0.name).Input)" }.joined(separator: "\n")
        }
        let narrowed = schema.transitions
            .compactMap { edge -> String? in
                guard let namespace = edge.effectNamespace else { return nil }
                let started = edge.starts.map(operation)
                let lowering = started.map { "case .\($0.effect)(let input): return .\($0.effect)(input)" }
                    .joined(separator: "\n")
                return """
                    /// The operations `\(edge.name)` may start.
                    \(access)enum \(namespace)\(conformance) {
                        \(cases(started))
                        /// The schema-wide effect this value describes.
                        \(access)var effect: \(name).Effect { switch self { \(lowering) } }
                    }
                    """
            }
            .joined(separator: "\n")
        return """
            /// Inert descriptions of the operations this workflow can start.
            \(access)enum Effect\(conformance) {
                \(cases(schema.operations))
                \(narrowed)
            }
            """
    }

    func owned() -> String {
        let methods = schema.transitions
            .map { edge in
                let before = phase(edge.from)
                let after = phase(edge.to)
                let payload = edge.payloadType.map { "_ input: \($0)" } ?? ""
                let argument = edge.payloadType == nil ? "" : ", input"
                let failure = edge.failureType ?? "Never"
                let call = "\(name).\(edge.name)(phase\(argument))"
                let starts = edge.effectNamespace != nil
                let effect = starts ? "Effect" : "Never"
                switch edge.shape {
                case .advance:
                    return """
                        /// Consumes the predecessor and preserves it on authored rejection.
                        \(access)consuming func \(edge.name)(\(payload)) -> Advance<Self, Owned<\(after)>, \(effect), \(failure)> where Phase == \(before) {
                            switch \(call) {
                            case .advanced(let next, let effects): return .advanced(Owned<\(after)>(next), effects: \(starts ? "effects.map(\\.effect)" : "effects"))
                            case .rejected(let failure, let original): return .rejected(failure, Owned<\(before)>(original))
                            }
                        }
                        """
                case .change where edge.failureType != nil:
                    return """
                        /// Advances through the authored edge or returns the original predecessor.
                        \(access)consuming func \(edge.name)(\(payload)) -> Advance<Self, Owned<\(after)>, Effect, \(failure)> where Phase == \(before) {
                            do {
                                let change = try \(call)
                                let effects = change.effects.map(\\.effect)
                                return .advanced(Owned<\(after)>(change.next), effects: effects)
                            } catch { return .rejected(error, self) }
                        }
                        """
                case .change:
                    return """
                        /// Advances through the authored edge, preserving effect order.
                        \(access)consuming func \(edge.name)(\(payload)) -> Change<Owned<\(after)>, Effect> where Phase == \(before) {
                            let change = \(call)
                            let effects = change.effects.map(\\.effect)
                            return Change(Owned<\(after)>(change.next), effects: effects)
                        }
                        """
                case .destination where edge.failureType != nil:
                    return """
                        /// Advances through the authored edge or returns the original predecessor.
                        \(access)consuming func \(edge.name)(\(payload)) -> Advance<Self, Owned<\(after)>, Never, \(failure)> where Phase == \(before) {
                            do { return .advanced(Owned<\(after)>(try \(call)), effects: []) } catch { return .rejected(error, self) }
                        }
                        """
                case .destination:
                    return """
                        /// Advances through the authored edge, which starts no operation.
                        \(access)consuming func \(edge.name)(\(payload)) -> Owned<\(after)> where Phase == \(before) {
                            Owned<\(after)>(\(call))
                        }
                        """
                }
            }
            .joined(separator: "\n")
        return """
            /// Unique authority over one declared workflow phase.
            \(access)struct Owned<Phase: ~Copyable\(schema.mode == .shared ? " & Sendable" : "")>: ~Copyable\(schema.mode == .shared ? ", Sendable" : "") {
                fileprivate let phase: Phase
                fileprivate init(_ phase: consuming Phase) { self.phase = phase }
                /// Borrows the payload without copying a unique resource.
                \(access)borrowing func withValue<Result>(_ body: (borrowing Phase) -> Result) -> Result { body(phase) }
                \(methods)
            }
            /// Creates ownership only in the declared initial phase.
            \(access)static func owned(_ initial: consuming \(initialType)) -> Owned<\(initialType)> { Owned(initial) }
            """
    }

    func values() -> String {
        let bound = schema.mode == .shared ? ": Sendable" : ""
        let cases = schema.phases.map { "case \($0.caseName)(Observed<\($0.typeName)>)" }.joined(separator: "\n")
        let recordCases = schema.phases.map { "case .\($0.caseName)(let value): return value.record" }
            .joined(separator: "\n")
        let observationCases = schema.phases
            .map {
                "case .\($0.caseName)(let payload): return .\($0.caseName)(Observed(payload: payload, record: record, claim: claim))"
            }
            .joined(separator: "\n")
        let edgeFailures =
            (schema.transitions.compactMap { edge in edge.failureType.map { "case \(edge.name)(\($0))" } }
            + schema.routes.compactMap { route in route.failureType.map { "case \(route.name)(\($0))" } })
            .joined(separator: "\n")
        let choices = schema.routes
            .compactMap { route -> String? in
                guard let namespace = route.namespace else { return nil }
                let cases = route.choices.map { "case \($0)" }.joined(separator: "\n")
                return "/// The edges `\(route.name)` may choose.\n\(access)enum \(namespace)\(sendable) { \(cases) }"
            }
            .joined(separator: "\n")
        let routeNamespace =
            choices.isEmpty ? "" : "/// The edges each router may choose among.\n\(access)enum Route { \(choices) }"
        let methods = schema.transitions.map(observedMethod).joined(separator: "\n")
        let sharedSnapshots =
            schema.mode == .shared
            ? "/// A single-pass latest-value sequence of a shared or actor owner's snapshots.\n\(access)typealias Snapshots = RuntimeSnapshots<Snapshot>"
            : ""
        return """
            fileprivate typealias _StateMachineEngine = \(engine)
            /// Validated bounds for managed admission and serial subscriptions.
            \(access)typealias Configuration = RuntimeManagedConfiguration
            /// Admission bounds for a manual local owner, with no subscriptions or runner policy.
            \(access)typealias LocalConfiguration = RuntimeLimits
            /// A live observation registration; cancelling or releasing it stops delivery.
            \(access)typealias Subscription = RuntimeSubscription
            /// A live MainActor observation registration; cancelling or releasing it stops delivery.
            \(access)typealias MainActorSubscription = RuntimeMainActorSubscription
            /// Failure to register another live observer.
            \(access)typealias SubscriptionFailure = RuntimeHostSubscriptionFailure
            /// A single-pass latest-value sequence of a MainActor owner's snapshots.
            \(access)typealias MainActorSnapshots = RuntimeMainActorSnapshots<Snapshot>
            \(sharedSnapshots)
            /// Whether a managed owner retries a conflicting completion or waits for reconciliation.
            \(access)typealias CompletionPolicy = RuntimeCompletionPolicy
            /// The disposition of a retained completion.
            \(access)typealias PendingStatus = RuntimePendingStatus
            /// Admission rejection reasons in exact evaluation precedence.
            \(access)typealias CommitRejection = \(engine).Rejection
            /// An immutable historical payload with sealed complete-root provenance.
            \(access)struct Observed<Phase\(bound)>\(sendable) {
                fileprivate let payload: Phase
                fileprivate let record: _StateMachineEngine.Snapshot
                fileprivate let claim: RuntimeDeliveryClaim?
                /// The copied historical payload.
                \(access)var value: Phase { payload }
                /// The owner-lifetime accepted revision.
                \(access)var revision: UInt64 { record.revision }
                \(methods)
            }
            /// A complete historical root observation with sealed provenance.
            \(access)enum Snapshot: \(schema.mode == .shared ? "Sendable, " : "")StateMachineSnapshot {
                \(cases)
                fileprivate var record: _StateMachineEngine.Snapshot { switch self { \(recordCases) } }
                /// The accepted revision of this observation.
                \(access)var revision: UInt64 { record.revision }
                /// Whether this historical root records closure.
                \(access)var isClosed: Bool { record.isClosed }
                /// Ordinary model data; constructing it confers no installation authority.
                \(access)var model: \(name) { record.model }
            }
            fileprivate static func _stateMachineSnapshot(_ record: _StateMachineEngine.Snapshot, claim: RuntimeDeliveryClaim? = nil) -> Snapshot {
                switch record.model { \(observationCases) }
            }
            /// A sealed inert candidate consumed by admission.
            \(access)struct Prepared: ~Copyable\(schema.mode == .shared ? ", Sendable" : "") {
                fileprivate let candidate: _StateMachineEngine.Candidate
                fileprivate init(_ candidate: _StateMachineEngine.Candidate) { self.candidate = candidate }
            }
            /// A closed typed dynamic routing rejection.
            \(access)enum PreparationRejection: Error {
                /// The input or outcome has no edge from the observed phase.
                case invalidPhase
                /// Actual emitted effects violate metadata or immutable limits.
                case plan(PlanRejection)
                \(edgeFailures)
            }
            \(routeNamespace)
            /// A prepared candidate or typed routing rejection.
            \(access)enum PreparationResult: ~Copyable\(schema.mode == .shared ? ", Sendable" : "") {
                case prepared(Prepared)
                case rejected(PreparationRejection)
            }
            /// A historical receipt for an atomic acceptance.
            \(access)struct Receipt: \(schema.mode == .shared ? "Sendable, " : "")StateMachineReceipt {
                /// The accepted historical observation.
                \(access)let snapshot: Snapshot
                fileprivate init(_ record: _StateMachineEngine.Snapshot) { snapshot = _stateMachineSnapshot(record) }
                /// The owner-lifetime accepted revision.
                \(access)var revision: UInt64 { snapshot.revision }
            }
            /// Why `send` did not admit an input.
            \(access)enum SendRejection: Error {
                /// Routing or the authored transition declined the input before a candidate existed.
                case preparation(PreparationRejection)
                /// The owner refused the prepared candidate; read `snapshot()` for the current root.
                case commit(CommitRejection)
            }
            /// Admission either publishes the entire candidate or leaves all state unchanged.
            \(access)enum CommitResult\(sendable) {
                case committed(Receipt)
                case rejected(CommitRejection, current: Snapshot)
            }
            fileprivate static func _stateMachineAdmission(_ result: _StateMachineEngine.Admission) -> CommitResult {
                switch result {
                case .committed(let record): return .committed(Receipt(record))
                case .rejected(let reason, let current): return .rejected(reason, current: _stateMachineSnapshot(current))
                }
            }
            """
    }

    func phase(_ caseName: String) -> String { schema.phases.first { $0.caseName == caseName }!.typeName }
    func operation(_ effect: String) -> Schema.Operation { schema.operations.first { $0.effect == effect }! }
    func observedMethod(_ edge: Schema.Transition) -> String {
        let before = phase(edge.from)
        let after = phase(edge.to)
        let failure = edge.failureType ?? "Never"
        let argument: String
        let parameter: String
        let ticket: String
        if edge.trigger.kind == .input {
            parameter = edge.payloadType.map { "_ input: \($0)" } ?? ""
            argument = edge.payloadType == nil ? "" : ", input"
            ticket = "nil"
        } else {
            let op = operation(edge.trigger.name)
            parameter = "_ completion: \(op.name)\(edge.trigger.kind == .success ? "Success" : "Failure")Completion"
            argument = ", completion.value"
            ticket = "completion.authority"
        }
        let call = "\(edge.failureType == nil ? "" : "try ")\(name).\(edge.name)(payload\(argument))"
        let starts = edge.effectNamespace != nil
        let result = starts ? "change" : "next"
        let resultType = starts ? "Change<\(after), \(authoredEffect(edge))>" : after
        return """
            /// Prepares the declared edge with phase and operation authority preserved.
            \(access)func \(edge.name)(\(parameter)) throws(PreparationFailure<\(failure)>) -> Prepared where Phase == \(before) {
                let \(result): \(resultType)
                \(edge.failureType == nil ? "\(result) = \(call)" : "do { \(result) = \(call) } catch { throw .domain(error) }")
                do {
                    let candidate = try _stateMachinePrepare(on: record, next: .\(edge.to)(\(starts ? "change.next" : "next")),
                        effects: \(starts ? "change.effects.map(\\.effect)" : "[]"),
                        from: \(index(edge.from)), to: \(index(edge.to)), invalidates: \(scopeIndices(edge.invalidates)),
                        requiring: \(ticket), claim: claim)
                    return Prepared(candidate)
                } catch { throw .plan(error) }
            }
            """
    }
    /// The runtime admission policy expression for a declared admission.
    func policy(_ admission: Schema.Admission) -> String {
        switch admission {
        case .latest: ".latest"
        case .rejectWhenActive: ".rejectWhenActive"
        case .parallel(let limit): ".parallel(\(limit))"
        }
    }
    func index(_ phase: String) -> Int { schema.phases.firstIndex { $0.caseName == phase }! }
    func scopeIndices(_ scopes: [String]) -> String {
        "[" + scopes.map { String(schema.scopes.firstIndex(of: $0)!) }.joined(separator: ", ") + "]"
    }

    func operations() -> String {
        let declarations = schema.operations
            .map { op in
                """
                /// Work issued exclusively from an accepted command batch.
                \(access)struct \(op.name)Work\(sendable) {
                    /// The immutable declared input.
                    \(access)let input: \(op.name).Input
                    fileprivate let authority: RuntimeTicket
                    /// The sealed identity for acknowledging physical execution termination.
                    \(access)var execution: ExecutionHandle { ExecutionHandle(authority: authority) }
                    /// Seals a successful terminal result for this exact work.
                    \(access)func succeeded(_ value: \(op.name).Output) -> \(op.name)Completion {
                        .success(\(op.name)SuccessCompletion(value: value, authority: authority))
                    }
                    \(["Void", "()"].contains(op.outputType) ? "/// Seals a successful terminal result that carries no value.\n\(access)func succeeded() -> \(op.name)Completion { succeeded(()) }" : "")
                    /// Seals a failed terminal result for this exact work.
                    \(access)func failed(_ value: \(op.name).Failure) -> \(op.name)Completion {
                        \(op.failureType == "Never" ? "" : ".failure(\(op.name)FailureCompletion(value: value, authority: authority))")
                    }
                }
                /// A sealed successful terminal result for one declared operation.
                \(access)struct \(op.name)SuccessCompletion\(sendable) {
                    /// The typed successful value.
                    \(access)let value: \(op.name).Output
                    fileprivate let authority: RuntimeTicket
                }
                /// A sealed failed terminal result for one declared operation.
                \(access)struct \(op.name)FailureCompletion\(sendable) {
                    /// The typed failure value.
                    \(access)let value: \(op.name).Failure
                    fileprivate let authority: RuntimeTicket
                }
                /// The closed terminal vocabulary for this operation.
                \(access)enum \(op.name)Completion\(sendable) {
                    case success(\(op.name)SuccessCompletion)
                    case failure(\(op.name)FailureCompletion)
                    fileprivate var authority: RuntimeTicket { switch self {
                        case .success(let value): return value.authority
                        case .failure(let value): return value.authority
                    } }
                }
                """
            }
            .joined(separator: "\n")
        let cases = schema.operations.map { "case \($0.effect)(\($0.name)Completion)" }.joined(separator: "\n")
        let tickets = schema.operations.map { "case .\($0.effect)(let value): return value.authority" }
            .joined(separator: "\n")
        let commands = schema.operations.map { "case \($0.effect)(\($0.name)Work)" }.joined(separator: "\n")
        let starts = schema.operations
            .map {
                "case .\($0.effect)(let input): return .\($0.effect)(\($0.name)Work(input: input, authority: work.ticket))"
            }
            .joined(separator: "\n")
        return """
            \(declarations)
            /// Closed typed terminal outcomes for this domain.
            \(access)enum Completion\(sendable) {
                \(cases)
                fileprivate var authority: RuntimeTicket { switch self { \(tickets) } }
            }
            /// A sealed handle to actual execution bookkeeping.
            \(access)struct ExecutionHandle: Equatable, Sendable {
                fileprivate let authority: RuntimeTicket
            }
            /// Physical termination is independent of cancellation or completion delivery.
            \(access)enum ExecutionDisposition: Equatable, Sendable { case terminated, skippedBeforeStart }
            /// Whether a physical execution acknowledgment was recorded.
            \(access)enum AcknowledgmentResult: Equatable, Sendable {
                case recorded
                case duplicate
                case foreignOwner
            }
            /// A closed accepted start or cancellation command.
            \(access)enum Command\(sendable) {
                case cancel(ExecutionHandle)
                \(commands)
            }
            /// One whole FIFO batch with its historical receipt.
            \(access)struct CommandBatch\(sendable) {
                /// The atomic acceptance represented by this batch.
                \(access)let receipt: Receipt
                /// Cancellation commands followed by starts in authored effect order.
                \(access)let commands: [Command]
                /// Whether this is the separately reserved close batch.
                \(access)let terminal: Bool
                fileprivate init(receipt: Receipt, commands: [Command], terminal: Bool) {
                    self.receipt = receipt
                    self.commands = commands
                    self.terminal = terminal
                }
            }
            fileprivate static func _stateMachineBatch(_ batch: _StateMachineEngine.Batch) -> CommandBatch {
                let commands = batch.commands.map { command -> Command in
                    switch command {
                    case .cancel(let ticket): return .cancel(ExecutionHandle(authority: ticket))
                    case .start(let work): switch work.descriptor { \(starts) }
                    }
                }
                return CommandBatch(receipt: Receipt(batch.snapshot), commands: commands, terminal: batch.terminal)
            }
            """
    }

    func preparation() -> String {
        let eligibility = schema.scopes
            .map { scope in
                if let op = schema.operations.first(where: { $0.scope == scope }) {
                    return "[" + op.activeIn.map { String(index($0)) }.joined(separator: ", ") + "]"
                }
                return "Array(0..<\(schema.phases.count))"
            }
            .joined(separator: ", ")
        let starts = schema.operations.enumerated()
            .map { i, op in
                let scope = schema.scopes.firstIndex(of: op.scope)!
                let dependencies = op.requires.map { "RuntimeScopeID(kind: \(schema.scopes.firstIndex(of: $0)!))" }
                    .joined(separator: ", ")
                let admission = policy(op.admission)
                return """
                    case .\(op.effect)(let input):
                        let _: \(op.name).Input = input
                        counts[\(i)] += 1
                        guard counts[\(i)] <= \(op.admission.maxNewIntents) else { throw .invalidPlan }
                        starts.append(.init(RuntimeOperation(kind: \(i), scope: RuntimeScopeID(kind: \(scope)),
                            dependencies: [\(dependencies)], policy: \(admission)), descriptor: effect))
                    """
            }
            .joined(separator: "\n")
        let inputCases = schema.phases
            .flatMap { p in
                schema.inputs.map { input -> String in
                    let trigger = Schema.Trigger(kind: .input, name: input.caseName)
                    let dispatch =
                        dispatch(
                            from: p.caseName,
                            trigger: trigger,
                            source: "source",
                            payload: input.payloadType == nil ? nil : "input"
                        )
                    guard let dispatch else {
                        return "case (.\(input.caseName), .\(p.caseName)): return .rejected(.invalidPhase)"
                    }
                    return
                        "case (.\(input.caseName)\(input.payloadType == nil ? "" : "(let input)"), .\(p.caseName)(let source)): \(dispatch)"
                }
            }
            .joined(separator: "\n")
        let completionCases = schema.operations
            .flatMap { op in
                schema.phases.flatMap { phase in
                    let p = phase.caseName
                    return [Schema.Trigger.Kind.success, .failure]
                        .map { outcome -> String in
                            let kind = outcome.rawValue
                            let trigger = Schema.Trigger(kind: outcome, name: op.effect)
                            let dispatch =
                                dispatch(from: p, trigger: trigger, source: "source", payload: "completion")
                            guard let dispatch else {
                                return "case (.\(op.effect)(.\(kind)), .\(p)): return .rejected(.invalidPhase)"
                            }
                            return "case (.\(op.effect)(.\(kind)(let completion)), .\(p)(let source)): \(dispatch)"
                        }
                }
            }
            .joined(separator: "\n")
        return """
            fileprivate static var _stateMachineEligibility: [[Int]] { [\(eligibility)] }
            fileprivate static func _stateMachinePrepare(
                on record: _StateMachineEngine.Snapshot, next: \(name), effects: [Effect], from: Int, to: Int,
                invalidates: [Int], requiring ticket: RuntimeTicket?, claim: RuntimeDeliveryClaim?
            ) throws(PlanRejection) -> _StateMachineEngine.Candidate {
                var edits: [_StateMachineEngine.ScopeEdit] = []
                for (scope, phases) in _stateMachineEligibility.enumerated() {
                    let before = phases.contains(from)
                    let after = phases.contains(to)
                    if after && (!before || invalidates.contains(scope)) { edits.append(.activate(RuntimeScopeID(kind: UInt32(scope)))) }
                    else if before && !after { edits.append(.remove(RuntimeScopeID(kind: UInt32(scope)))) }
                }
                \(schema.operations.isEmpty ? "let" : "var") starts: [_StateMachineEngine.Start] = []
                \(schema.operations.isEmpty ? "" : "var counts = Array(repeating: 0, count: \(schema.operations.count))")
                for effect in effects { switch effect { \(starts) } }
                return try _StateMachineEngine.prepare(on: record, next: next, requiring: ticket.map { [$0] } ?? [],
                    plan: .init(scopes: edits, retire: ticket.map { [$0] } ?? [], starts: starts,
                        controlCount: invalidates.count, finishingClaims: claim.map { [$0] } ?? []))
            }
            /// Routes an input against a historical snapshot, rejecting a missing phase edge explicitly.
            \(access)static func prepare(_ input: Input, on snapshot: Snapshot) -> PreparationResult {
                \(schema.inputs.isEmpty ? "" : "switch (input, snapshot) { \(inputCases) }")
            }
            fileprivate static func _stateMachineCompletion(_ completion: Completion, on snapshot: Snapshot) -> PreparationResult {
                \(schema.operations.isEmpty ? "" : "switch (completion, snapshot) { \(completionCases) }")
            }
            """
    }

    func dispatch(from: String, trigger: Schema.Trigger, source: String, payload: String?) -> String? {
        func prepare(_ edge: Schema.Transition) -> String {
            let call = "try \(source).\(edge.name)(\(payload ?? ""))"
            let domain: String
            if edge.failureType != nil {
                domain = "case .domain(let error): return .rejected(.\(edge.name)(error))"
            } else {
                domain = "case .domain(let never): switch never {}"
            }
            return """
                do { return .prepared(\(call)) }
                catch { switch error { case .plan(let reason): return .rejected(.plan(reason)) \(domain) } }
                """
        }
        let edges = schema.transitions.filter { $0.from == from && $0.trigger == trigger }
        guard let route = schema.routes.first(where: { $0.from == from && $0.trigger == trigger }) else {
            return edges.first.map(prepare)
        }
        // A router sees plain values only; the sealed completion goes to the edge it selects.
        let value = payload.map { trigger.kind == .input ? $0 : "\($0).value" }
        let call = "\(name).\(route.name)(\(source).value\(value.map { ", " + $0 } ?? ""))"
        guard let namespace = route.namespace else {
            return "do { try \(call) } catch { return .rejected(.\(route.name)(error)) }"
        }
        let selection =
            route.failureType == nil
            ? "let selection: Route.\(namespace) = \(call)"
            : "let selection: Route.\(namespace)\ndo { selection = try \(call) } catch { return .rejected(.\(route.name)(error)) }"
        let cases = edges.map { "case .\($0.name): \(prepare($0))" }.joined(separator: "\n")
        return """
            \(selection)
            switch selection { \(cases) }
            """
    }

    var ledger: String { "RuntimeDeliveryLedger<\(name), Effect, Completion, PreparationRejection>" }
    func local() -> String {
        """
        fileprivate typealias _StateMachineLedger = \(ledger)
        /// The opaque identity of a first retained terminal envelope.
        \(access)typealias PendingCompletionID = RuntimePendingID
        /// Typed historical diagnostics for a retained completion.
        \(access)typealias PendingCompletion = \(ledger).Pending
        /// A closed completion delivery decision.
        \(access)enum DeliveryResult\(sendable) {
            case committed(Receipt)
            case pending(PendingCompletionID, PendingStatus)
            case inProgress
            case notPending
            /// The operation's authority is inactive or its outcome was already settled.
            case stale
            /// The completion was issued by a different owner.
            case foreignOwner
            case discarded(Receipt)
            case rejected(CommitRejection)
        }
        fileprivate static func _stateMachineFinish(_ result: _StateMachineLedger.Finish) -> DeliveryResult {
            switch result {
            case .committed(let record): return .committed(Receipt(record))
            case .pending(let id, let status): return .pending(id, status)
            case .notPending: return .notPending
            }
        }
        fileprivate static func _stateMachineDeliveryPreparation(_ attempt: _StateMachineLedger.Attempt) -> _StateMachineLedger.Preparation {
            \(schema.operations.isEmpty ? "return .failure(.domain(.invalidPhase))" : """
            switch _stateMachineCompletion(attempt.outcome, on: _stateMachineSnapshot(attempt.snapshot, claim: attempt.claim)) {
            case .prepared(let prepared): return .success(prepared.candidate)
            case .rejected(let reason):
                if case .plan(let plan) = reason { return .failure(.plan(plan)) }
                return .failure(.domain(reason))
            }
            """)
        }
        /// A noncopyable manually driven owner with an embedded value engine.
        \(access)struct Local: ~Copyable {
            fileprivate var engine: _StateMachineEngine
            fileprivate var ledger = _StateMachineLedger()
            /// Creates fresh authority only in the declared initial phase.
            \(access)init(_ initial: \(initialType), configuration: LocalConfiguration = .default) {
                engine = _StateMachineEngine(.\(schema.initial)(initial), scopes: [\(initialScopes)], limits: configuration)
            }
            /// Returns an immutable historical observation.
            \(access)borrowing func snapshot() -> Snapshot { _stateMachineSnapshot(engine.snapshot) }
            /// Consumes and atomically accepts or rejects a complete candidate.
            \(access)mutating func commit(_ prepared: consuming Prepared) -> CommitResult {
                let result = engine.commit(prepared.candidate)
                ledger.prune(in: engine)
                return _stateMachineAdmission(result)
            }
            /// Routes, prepares and admits one input against the current root.
            @discardableResult
            \(access)mutating func send(_ input: Input) throws(SendRejection) -> Receipt {
                switch \(name).prepare(input, on: snapshot()) {
                case .prepared(let prepared):
                    switch commit(prepared) {
                    case .committed(let receipt): return receipt
                    case .rejected(let reason, _): throw .commit(reason)
                    }
                case .rejected(let reason): throw .preparation(reason)
                }
            }
            /// Transfers whole FIFO batches; physical execution occurs after mutating access ends.
            \(access)mutating func drainCommands(limit: Int) -> [CommandBatch] {
                let batches = engine.drain(limit: limit).map { _stateMachineBatch($0) }
                _ = ledger.retryCapacity(in: &engine)
                return batches
            }
            /// Records actual termination independently of cancellation and completion delivery.
            \(access)mutating func acknowledgeExecution(_ execution: ExecutionHandle, disposition: ExecutionDisposition) -> AcknowledgmentResult {
                let result = engine.acknowledge(execution.authority, skippedBeforeStart: disposition == .skippedBeforeStart)
                _ = ledger.retryCapacity(in: &engine)
                switch result {
                case .recorded: return .recorded
                case .duplicate: return .duplicate
                case .foreignOwner: return .foreignOwner
                }
            }
            /// Retains the first outcome and attempts one typed preparation against the current root.
            \(access)mutating func deliver(_ completion: Completion) -> DeliveryResult {
                \(schema.operations.isEmpty ? "" : """
                switch ledger.retain(completion, for: completion.authority, in: &engine) {
                case .stale: return .stale
                case .foreignOwner: return .foreignOwner
                case .pending(let id):
                    guard let pending = ledger.pending.first(where: { $0.id == id }) else { return .notPending }
                    if pending.status != .awaitingAdmission { return .pending(id, pending.status) }
                    return reconcile(id: id)
                }
                """)
            }
            \(operationDeliveries(prefix: "mutating ", asynchronous: "", awaiting: ""))
            /// Claims one retained outcome before evaluating domain code.
            \(access)mutating func reconcile(id: PendingCompletionID) -> DeliveryResult {
                switch ledger.claim(id, in: &engine) {
                case .inProgress: return .inProgress
                case .notPending: return .notPending
                case .claimed(let attempt):
                    let preparation = _stateMachineDeliveryPreparation(attempt)
                    return _stateMachineFinish(ledger.finish(attempt, preparation: preparation, in: &engine))
                }
            }
            /// Queries immutable first-outcome records without claiming preparation.
            \(access)borrowing func pendingCompletions() -> [PendingCompletion] { ledger.pending }
            /// Revokes one retained operation using an atomic authority-only commit.
            \(access)mutating func discardPending(id: PendingCompletionID) -> DeliveryResult {
                guard let result = ledger.discard(id, in: &engine) else { return .notPending }
                switch result {
                case .committed(let record): return .discarded(Receipt(record))
                case .rejected(let reason, _): return .rejected(reason)
                }
            }
            /// Ends admission while retaining historical read access.
            \(access)mutating func close() -> Receipt {
                let result = engine.close()
                ledger.prune(in: engine)
                return Receipt(result)
            }
            /// Closure, FIFO transfer, and all actual execution and delivery obligations have settled.
            \(access)var isQuiescent: Bool { engine.isQuiescent }
        }
        """
    }
    func managed(mainActor: Bool) -> String {
        let facade = mainActor ? "MainActorHost" : "ActorHost"
        let runtime = mainActor ? "RuntimeMainActorHost" : "RuntimeActorHost"
        let drivers = mainActor ? "MainActorDrivers" : "Drivers"
        let isolation = mainActor ? "@MainActor" : "@Sendable"
        let asynchronous = mainActor ? "" : " async"
        let awaiting = mainActor ? "" : "await "
        let token = mainActor ? "MainActorSubscription" : "Subscription"
        let fields = schema.operations
            .map {
                "/// Executes this operation within the selected isolation.\n\(access)let \($0.effect): @MainActor (\($0.name).Input) async -> Result<\($0.name).Output, \($0.name).Failure>"
            }
            .joined(separator: "\n")
        let params = schema.operations
            .map {
                "\($0.effect): @escaping @MainActor (\($0.name).Input) async -> Result<\($0.name).Output, \($0.name).Failure>"
            }
            .joined(separator: ", ")
        let assignments = schema.operations.map { "self.\($0.effect) = \($0.effect)" }.joined(separator: "\n")
        let driverDeclaration =
            mainActor
            ? """
            /// Immutable operation selections whose non-Sendable values stay within MainActor.
            @MainActor \(access)struct MainActorDrivers {
                \(fields)
                /// Selects every driver for this owner's lifetime.
                \(access)init(\(params)) { \(assignments) }
            }
            """ : ""
        return """
            \(driverDeclaration)
            /// A sealed sole-writer \(mainActor ? "MainActor" : "native actor") owner with managed execution.
            \(mainActor ? "@MainActor " : "")\(access)final class \(facade): \(mainActor ? "MainActorStateMachineHost" : "Sendable") {
                private typealias Host = \(runtime)<\(name), Effect, Completion, PreparationRejection>
                private let host: Host
                /// Creates fresh authority and immutable execution selections.
                \(access)init(_ initial: \(initialType), drivers: \(drivers), configuration: Configuration = .default,
                    completionPolicy: CompletionPolicy = .manualOnConflict,
                    onReconciliationRequired: @escaping \(isolation) (PendingCompletion) -> Void = { _ in }) {
                    host = Host(.\(schema.initial)(initial), scopes: [\(initialScopes)], configuration: configuration,
                        policy: completionPolicy, driver: { raw in
                            switch raw.descriptor { \(managedExecutions) }
                        }, ticket: { (outcome: Completion) -> RuntimeTicket in \(schema.operations.isEmpty ? "" : "return outcome.authority") },
                        prepare: { _stateMachineDeliveryPreparation($0) }, reconciliationRequired: onReconciliationRequired)
                }
                /// Captures a complete historical observation.
                \(access)func snapshot()\(asynchronous) -> Snapshot { _stateMachineSnapshot(\(awaiting)host.snapshot()) }
                /// Routes, prepares and admits one input in a single isolated turn without suspension.
                @discardableResult
                \(access)func send(_ input: Input)\(asynchronous) throws(SendRejection) -> Receipt {
                    let result = \(awaiting)host.prepareAndCommit { raw -> Result<_StateMachineEngine.Candidate, PreparationRejection> in
                        switch \(name).prepare(input, on: _stateMachineSnapshot(raw)) {
                        case .prepared(let prepared): return .success(prepared.candidate)
                        case .rejected(let reason): return .failure(reason)
                        }
                    }
                    switch result {
                    case .success(.committed(let record)): return Receipt(record)
                    case .success(.rejected(let reason, _)): throw .commit(reason)
                    case .failure(let reason): throw .preparation(reason)
                    }
                }
                /// Consumes an explicitly prepared historical candidate, rechecking freshness.
                \(access)func commit(_ prepared: consuming Prepared)\(asynchronous) -> CommitResult {
                    let candidate = prepared.candidate
                    return _stateMachineAdmission(\(awaiting)host.commit(candidate))
                }
                /// Subscribes to initial, accepted and terminal complete snapshots.
                \(access)func subscribe(_ receive: @escaping \(isolation) (Snapshot) -> Void,
                    onFinish: @escaping \(isolation) () -> Void = {})\(asynchronous) throws(SubscriptionFailure) -> \(token) {
                    try \(awaiting)host.subscribe({ receive(_stateMachineSnapshot($0)) }, onFinish: onFinish)
                }
                /// Registers a single-pass sequence of the latest complete snapshots.
                ///
                /// The sequence ends after the closed snapshot, when its task is cancelled, or when this owner is released.
                \(access)func snapshots()\(asynchronous) throws(SubscriptionFailure) -> \(mainActor ? "MainActorSnapshots" : "Snapshots") {
                    try \(awaiting)host.snapshots { _stateMachineSnapshot($0) }
                }
                /// Retains the first terminal outcome and validates current authority.
                \(access)func deliver(_ completion: Completion)\(asynchronous) -> DeliveryResult { \(schema.operations.isEmpty ? "" : "return Self.project(\(awaiting)host.deliver(completion))") }
                \(operationDeliveries(prefix: "", asynchronous: asynchronous, awaiting: awaiting))
                /// Reads immutable retained first-outcome diagnostics.
                \(access)func pendingCompletions()\(asynchronous) -> [PendingCompletion] { \(awaiting)host.pendingCompletions() }
                /// Explicitly claims a fresh preparation attempt for a retained outcome.
                \(access)func reconcile(id: PendingCompletionID)\(asynchronous) -> DeliveryResult { Self.project(\(awaiting)host.reconcile(id: id)) }
                /// Revokes retained delivery with an authority-only admission.
                \(access)func discardPending(id: PendingCompletionID)\(asynchronous) -> DeliveryResult { Self.project(\(awaiting)host.discardPending(id: id)) }
                /// Closes admission while preserving historical model data.
                \(access)func close()\(asynchronous) -> Receipt { Receipt(\(awaiting)host.close()) }
                /// Waits for cancellation and launch decisions through this owner-bound receipt.
                \(access)func flush(through receipt: Receipt) async -> Bool { await host.flush(through: receipt.snapshot.record) }
                /// Closes and joins actual execution and retained delivery obligations.
                \(access)func shutdown() async { await host.shutdown() }
                /// Closes and waits for settlement through an optional deadline.
                \(access)func shutdownAndWait(deadline: ContinuousClock.Instant? = nil) async -> Bool { await host.shutdownAndWait(deadline: deadline) }
                /// Actual workers whose joined termination has not yet been processed.
                \(access)var runningCount: Int { \(mainActor ? "host.runningCount" : "get async { await host.runningCount }") }
                /// Live observer registrations.
                \(access)var subscriberCount: Int { \(mainActor ? "host.subscriberCount" : "get async { await host.subscriberCount }") }
                /// Whether closure and all managed obligations have settled.
                \(access)var isQuiescent: Bool { \(mainActor ? "host.isQuiescent" : "get async { await host.isQuiescent }") }
                private static func project(_ result: RuntimeHostDelivery<\(name), Effect>) -> DeliveryResult {
                    switch result {
                    case .committed(let record): return .committed(Receipt(record))
                    case .pending(let id, let status): return .pending(id, status)
                    case .inProgress: return .inProgress
                    case .notPending: return .notPending
                    case .stale: return .stale
                    case .foreignOwner: return .foreignOwner
                    case .discarded(let record): return .discarded(Receipt(record))
                    case .rejected(let reason): return .rejected(reason)
                    }
                }
            }
            """
    }

    func shared() -> String {
        let fields = schema.operations
            .map {
                "/// Executes one typed operation outside admission locks.\n\(access)let \($0.effect): @Sendable (\($0.name).Input) async -> Result<\($0.name).Output, \($0.name).Failure>"
            }
            .joined(separator: "\n")
        let params = schema.operations
            .map {
                "\($0.effect): @escaping @Sendable (\($0.name).Input) async -> Result<\($0.name).Output, \($0.name).Failure>"
            }
            .joined(separator: ", ")
        let assignments = schema.operations.map { "self.\($0.effect) = \($0.effect)" }.joined(separator: "\n")
        return """
            /// Immutable typed execution selection for one managed owner's lifetime.
            \(access)struct Drivers: Sendable {
                \(fields)
                /// Selects all drivers for this owner.
                \(access)init(\(params)) { \(assignments) }
            }
            /// A synchronous shared owner with managed physical execution and terminal delivery.
            \(access)final class Shared: Sendable {
                private let host: RuntimeSharedHost<\(name), Effect, Completion, PreparationRejection>
                /// Creates fresh initial authority and retains the driver selection immutably.
                \(access)init(_ initial: \(initialType), drivers: Drivers, configuration: Configuration = .default,
                    completionPolicy: CompletionPolicy = .manualOnConflict,
                    onReconciliationRequired: @escaping @Sendable (PendingCompletion) -> Void = { _ in }) {
                    host = RuntimeSharedHost(.\(schema.initial)(initial), scopes: [\(initialScopes)], limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
                        policy: completionPolicy, driver: { raw in
                            switch raw.descriptor { \(managedExecutions) }
                        }, ticket: { (outcome: Completion) -> RuntimeTicket in \(schema.operations.isEmpty ? "" : "return outcome.authority") }, prepare: { _stateMachineDeliveryPreparation($0) }, reconciliationRequired: onReconciliationRequired)
                }
                /// Captures a coherent historical observation.
                \(access)func snapshot() -> Snapshot { _stateMachineSnapshot(host.snapshot()) }
                /// Registers a serial capacity-one latest-value observation callback.
                \(access)func subscribe(_ receive: @escaping @Sendable (Snapshot) -> Void,
                    onFinish: @escaping @Sendable () -> Void = {}) throws(SubscriptionFailure) -> Subscription {
                    try host.subscribe({ receive(_stateMachineSnapshot($0)) }, onFinish: onFinish)
                }
                /// Registers a single-pass sequence of the latest complete snapshots.
                ///
                /// The sequence ends after the closed snapshot, when its task is cancelled, or when this owner is released.
                \(access)func snapshots() throws(SubscriptionFailure) -> Snapshots {
                    try host.snapshots { _stateMachineSnapshot($0) }
                }
                /// Routes, prepares and admits one input in a single attempt.
                ///
                /// Preparation runs outside the lock against one snapshot and is never repeated, so
                /// a concurrent commit surfaces as `.commit(.conflict)` for the caller to resolve.
                @discardableResult
                \(access)func send(_ input: Input) throws(SendRejection) -> Receipt {
                    switch \(name).prepare(input, on: snapshot()) {
                    case .prepared(let prepared):
                        switch commit(prepared) {
                        case .committed(let receipt): return receipt
                        case .rejected(let reason, _): throw .commit(reason)
                        }
                    case .rejected(let reason): throw .preparation(reason)
                    }
                }
                /// Consumes one candidate into an atomic admission attempt.
                \(access)func commit(_ prepared: consuming Prepared) -> CommitResult { _stateMachineAdmission(host.commit(prepared.candidate)) }
                /// Retains and attempts delivery of the first typed terminal outcome.
                \(access)func deliver(_ completion: Completion) -> DeliveryResult { \(schema.operations.isEmpty ? "" : "return Self.project(host.deliver(completion))") }
                \(operationDeliveries(prefix: "", asynchronous: "", awaiting: ""))
                /// Returns immutable first-outcome diagnostics.
                \(access)func pendingCompletions() -> [PendingCompletion] { host.pendingCompletions() }
                /// Claims one fresh preparation for a retained outcome.
                \(access)func reconcile(id: PendingCompletionID) -> DeliveryResult { Self.project(host.reconcile(id: id)) }
                /// Revokes one retained operation by an authority-only commit.
                \(access)func discardPending(id: PendingCompletionID) -> DeliveryResult { Self.project(host.discardPending(id: id)) }
                /// Ends admission and schedules cancellation in FIFO order.
                \(access)func close() -> Receipt { Receipt(host.close()) }
                /// Waits until cancellation and launch decisions through this receipt have been processed.
                \(access)func flush(through receipt: Receipt) async -> Bool { await host.flush(through: receipt.snapshot.record) }
                /// Closes and waits for actual execution termination and retained obligation settlement.
                \(access)func shutdown() async { await host.shutdown() }
                /// Whether closure and all managed obligations have settled.
                \(access)var isQuiescent: Bool { host.isQuiescent }
                private static func project(_ result: RuntimeSharedHost<\(name), Effect, Completion, PreparationRejection>.Delivery) -> DeliveryResult {
                    switch result {
                    case .committed(let record): return .committed(Receipt(record))
                    case .pending(let id, let status): return .pending(id, status)
                    case .inProgress: return .inProgress
                    case .notPending: return .notPending
                    case .stale: return .stale
                    case .foreignOwner: return .foreignOwner
                    case .discarded(let record): return .discarded(Receipt(record))
                    case .rejected(let reason): return .rejected(reason)
                    }
                }
            }
            """
    }

    /// One `deliver` overload per operation, so a sealed completion needs no schema-wide wrapping.
    private func operationDeliveries(prefix: String, asynchronous: String, awaiting: String) -> String {
        schema.operations
            .map { op in
                """
                /// Delivers the sealed terminal result of one `\(op.name)` execution.
                \(access)\(prefix)func deliver(_ completion: \(op.name)Completion)\(asynchronous) -> DeliveryResult {
                    \(awaiting)deliver(.\(op.effect)(completion))
                }
                """
            }
            .joined(separator: "\n")
    }

    /// The initially active scope identifiers in declaration order.
    private var initialScopes: String {
        schema.scopes.enumerated()
            .compactMap { i, scope -> String? in
                let operation = schema.operations.first { $0.scope == scope }
                guard operation == nil || operation!.activeIn.contains(schema.initial) else { return nil }
                return "RuntimeScopeID(kind: \(i))"
            }
            .joined(separator: ", ")
    }

    /// The managed driver cases shared by all managed facades.
    private var managedExecutions: String {
        schema.operations
            .map { op in
                """
                case .\(op.effect)(let input):
                    let work = \(op.name)Work(input: input, authority: raw.ticket)
                    switch await drivers.\(op.effect)(input) {
                    case .success(let value): return .\(op.effect)(work.succeeded(value))
                    case .failure(let value): \(op.failureType == "Never" ? "switch value {}" : "return .\(op.effect)(work.failed(value))")
                    }
                """
            }
            .joined(separator: "\n")
    }

}
