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
    /// The default of every fresh entry point's initial parameter, when the schema declares one.
    var initialDefault: String { schema.initialDefault.map { " = \($0)" } ?? "" }
    var engine: String { "RuntimeState<\(name), Effect>" }
    /// Whether the schema declares any operation, and so generates work, completion, and delivery surfaces.
    var hasOperations: Bool { !schema.operations.isEmpty }
    /// The retained-outcome type of the runtime hosts: the sealed completion, or `Never` without operations.
    var outcome: String { hasOperations ? "Completion" : "Never" }
    func declaration(_ source: String) -> DeclSyntax { DeclSyntax(stringLiteral: source) }

    func members() throws -> [DeclSyntax] {
        var result = [witnesses(), effects(), owned()]
        if schema.mode != .ownedOnly {
            result += [values()]
            if hasOperations { result += [operations()] }
            result += [preparation(), restoration(), local(), managed(mainActor: true)]
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
            case .failure: operation(trigger.name).failure
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
        let operationWitnesses = schema.operations.filter(\.declaresFailure)
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

    /// The router that selects among the edges sharing this edge's source phase and trigger, if any.
    func router(of edge: Schema.Transition) -> Schema.Route? {
        schema.routes.first { $0.from == edge.from && $0.trigger == edge.trigger && !$0.choices.isEmpty }
    }

    /// The access of an edge's own `Owned` or `Observed` method.
    ///
    /// A routed edge is reached only through its router's method, so a typed call obeys the router. An
    /// observation's completion edge is reached only through delivery, so the first retained outcome is
    /// the only one that can commit. An unrouted `Owned` completion edge stays callable: `Owned` holds
    /// no work authority and retains no outcome, so it is the caller's only way to finish its own typestate.
    func edgeAccess(_ edge: Schema.Transition, observed: Bool) -> String {
        if router(of: edge) != nil { return "fileprivate " }
        return observed && edge.trigger.kind != .input ? "fileprivate " : access
    }

    /// The input routers that become `Observed` methods: those with candidate edges.
    var inputRouters: [Schema.Route] { schema.routes.filter { $0.trigger.kind == .input && !$0.choices.isEmpty } }

    /// The routers that become `Owned` methods: every router with candidate edges, for an input or a completion.
    var ownedRouters: [Schema.Route] { schema.routes.filter { !$0.choices.isEmpty } }

    /// A router's candidate edges in declaration order.
    func branches(_ route: Schema.Route) -> [Schema.Transition] {
        route.choices.map { choice in schema.transitions.first { $0.name == choice }! }
    }

    /// The functions of a routed group that can throw, as (function name, failure type) pairs.
    func throwers(_ route: Schema.Route) -> [(name: String, type: String)] {
        (route.failureType.map { [(route.name, $0)] } ?? [])
            + branches(route).compactMap { edge in edge.failureType.map { (edge.name, $0) } }
    }

    /// The failure type of a router's `Observed` method, or `nil` when no function of its group throws.
    ///
    /// It is the type every throwing function of the group shares, however many of them throw, and
    /// `PreparationRejection`, whose cases are named for each throwing function, when their types differ.
    func routedFailure(_ route: Schema.Route) -> String? {
        let types = throwers(route).map(\.type)
        guard let first = types.first else { return nil }
        return types.allSatisfy { $0 == first } ? first : "PreparationRejection"
    }

    /// Whether a router's `Observed` method wraps each function's failure in `PreparationRejection`.
    func routedFailureWraps(_ route: Schema.Route) -> Bool { routedFailure(route) == "PreparationRejection" }

    /// The typed throws clause of a router's `Observed` method.
    func routedThrows(_ route: Schema.Route) -> String { routedFailure(route).map { " throws(\($0))" } ?? "" }

    /// What an edge's `Owned` method returns, with its own source spelled `source`.
    func ownedResult(_ edge: Schema.Transition, source: String) -> String {
        let after = "Owned<\(phase(edge.to))>"
        let effect = authoredEffect(edge)
        switch edge.shape {
        case .advance: return "Advance<\(source), \(after), \(effect), \(edge.failureType ?? "Never")>"
        case .change where edge.failureType != nil:
            return "Advance<\(source), \(after), \(effect), \(edge.failureType!)>"
        case .change: return "Change<\(after), \(effect)>"
        case .destination where edge.failureType != nil:
            return "Advance<\(source), \(after), Never, \(edge.failureType!)>"
        case .destination: return after
        }
    }

    /// The type a router's `Owned` method returns.
    ///
    /// When the router cannot throw and every candidate edge returns the same type, that type; otherwise
    /// `Route.<Router>Result`, which has one case per candidate edge and, when the router can throw, a
    /// `rejected` case that returns the source.
    func ownedRoutedResult(_ route: Schema.Route) -> String {
        let results = Set(branches(route).map { ownedResult($0, source: "Self") })
        if route.failureType == nil, results.count == 1 { return results.first! }
        return "Route.\(route.namespace!)Result"
    }

    /// The `Route.<Router>Result` declaration of a router whose `Owned` method needs one.
    func ownedRoutedResultDeclaration(_ route: Schema.Route) -> String? {
        guard ownedRoutedResult(route) == "Route.\(route.namespace!)Result" else { return nil }
        let source = "Owned<\(phase(route.from))>"
        var cases = branches(route).map { "case \($0.name)(\(ownedResult($0, source: source)))" }
        if let failure = route.failureType {
            cases.append(
                "/// The router declined; the source is returned unchanged.\ncase rejected(\(failure), \(source))"
            )
        }
        return """
            /// The result of `\(route.name)` on an owned `\(phase(route.from))`: one case per edge it may select.
            \(access)enum \(route.namespace!)Result: ~Copyable\(schema.mode == .shared ? ", Sendable" : "") {
                \(cases.joined(separator: "\n"))
            }
            """
    }

    /// The `Owned` method that runs a router and then advances through the edge it selects.
    func ownedRoutedMethod(_ route: Schema.Route) -> String {
        let parameter = route.payloadType.map { "_ input: \($0)" } ?? ""
        let argument = route.payloadType == nil ? "" : ", input"
        let branchArgument = route.payloadType == nil ? "" : "input"
        let result = ownedRoutedResult(route)
        let wraps = result == "Route.\(route.namespace!)Result"
        let call = "\(name).\(route.name)(phase\(argument))"
        let selection =
            route.failureType == nil
            ? "let selection: Route.\(route.namespace!) = \(call)"
            : "let selection: Route.\(route.namespace!)\ndo { selection = try \(call) } catch { return .rejected(error, self) }"
        let cases = route.choices
            .map { choice in
                wraps
                    ? "case .\(choice): return .\(choice)(\(choice)(\(branchArgument)))"
                    : "case .\(choice): return \(choice)(\(branchArgument))"
            }
            .joined(separator: "\n")
        return """
            /// Runs the router `\(route.name)`, then advances through the edge it selects.
            \(access)consuming func \(route.name)(\(parameter)) -> \(result) where Phase == \(phase(route.from)) {
                \(selection)
                switch selection { \(cases) }
            }
            """
    }

    /// The `Observed` method that runs a router and then prepares the edge it selects.
    func observedRoutedMethod(_ route: Schema.Route) -> String {
        let parameter = route.payloadType.map { "_ input: \($0)" } ?? ""
        let argument = route.payloadType == nil ? "" : ", input"
        let branchArgument = route.payloadType == nil ? "" : "input"
        let wraps = routedFailureWraps(route)
        let call = "\(name).\(route.name)(payload\(argument))"
        let selection: String
        switch (route.failureType != nil, wraps) {
        case (false, _): selection = "let selection: Route.\(route.namespace!) = \(call)"
        case (true, false): selection = "let selection: Route.\(route.namespace!) = try \(call)"
        case (true, true):
            selection =
                "let selection: Route.\(route.namespace!)\ndo { selection = try \(call) } catch { throw .\(route.name)(error) }"
        }
        let cases = branches(route)
            .map { edge in
                let branch = "\(edge.name)(\(branchArgument))"
                switch (edge.failureType != nil, wraps) {
                case (false, _): return "case .\(edge.name): return \(branch)"
                case (true, false): return "case .\(edge.name): return try \(branch)"
                case (true, true):
                    return "case .\(edge.name): do { return try \(branch) } catch { throw .\(edge.name)(error) }"
                }
            }
            .joined(separator: "\n")
        return """
            /// Runs the router `\(route.name)`, then prepares the edge it selects.
            \(access)func \(route.name)(\(parameter))\(routedThrows(route)) -> Prepared where Phase == \(phase(route.from)) {
                \(selection)
                switch selection { \(cases) }
            }
            """
    }

    func owned() -> String {
        let methods = schema.transitions
            .map { edge in
                let before = phase(edge.from)
                let after = phase(edge.to)
                let visibility = edgeAccess(edge, observed: false)
                let payload = edge.payloadType.map { "_ input: \($0)" } ?? ""
                let argument = edge.payloadType == nil ? "" : ", input"
                let call = "\(name).\(edge.name)(phase\(argument))"
                // The edge's own effect type, so a caller switches over only what this edge can start.
                let result = ownedResult(edge, source: "Self")
                switch edge.shape {
                case .advance:
                    return """
                        /// Consumes the predecessor and preserves it on authored rejection.
                        \(visibility)consuming func \(edge.name)(\(payload)) -> \(result) where Phase == \(before) {
                            switch \(call) {
                            case .advanced(let next, let effects): return .advanced(Owned<\(after)>(next), effects: effects)
                            case .rejected(let failure, let original): return .rejected(failure, Owned<\(before)>(original))
                            }
                        }
                        """
                case .change where edge.failureType != nil:
                    return """
                        /// Advances through the authored edge or returns the original predecessor.
                        \(visibility)consuming func \(edge.name)(\(payload)) -> \(result) where Phase == \(before) {
                            do {
                                let change = try \(call)
                                return .advanced(Owned<\(after)>(change.next), effects: change.effects)
                            } catch { return .rejected(error, self) }
                        }
                        """
                case .change:
                    return """
                        /// Advances through the authored edge, preserving effect order.
                        \(visibility)consuming func \(edge.name)(\(payload)) -> \(result) where Phase == \(before) {
                            let change = \(call)
                            return Change(Owned<\(after)>(change.next), effects: change.effects)
                        }
                        """
                case .destination where edge.failureType != nil:
                    return """
                        /// Advances through the authored edge or returns the original predecessor.
                        \(visibility)consuming func \(edge.name)(\(payload)) -> \(result) where Phase == \(before) {
                            do { return .advanced(Owned<\(after)>(try \(call)), effects: []) } catch { return .rejected(error, self) }
                        }
                        """
                case .destination:
                    return """
                        /// Advances through the authored edge, which starts no operation.
                        \(visibility)consuming func \(edge.name)(\(payload)) -> \(result) where Phase == \(before) {
                            Owned<\(after)>(\(call))
                        }
                        """
                }
            }
            .joined(separator: "\n")
        let routed = ownedRouters.map(ownedRoutedMethod).joined(separator: "\n")
        return """
            /// Unique authority over one declared workflow phase.
            \(access)struct Owned<Phase: ~Copyable\(schema.mode == .shared ? " & Sendable" : "")>: ~Copyable\(schema.mode == .shared ? ", Sendable" : "") {
                fileprivate let phase: Phase
                fileprivate init(_ phase: consuming Phase) { self.phase = phase }
                /// Borrows the payload without copying a unique resource, returning what `body` returns or throws.
                \(access)borrowing func withValue<Result: ~Copyable, Failure: Error>(
                    _ body: (borrowing Phase) throws(Failure) -> Result
                ) throws(Failure) -> Result { try body(phase) }
                /// Consumes this authority and returns its payload, so a unique resource can move on.
                \(access)consuming func takeValue() -> Phase { phase }
                \(methods)
                \(routed)
            }
            /// Creates ownership only in the declared initial phase.
            \(access)static func owned(_ initial: consuming \(initialType)\(initialDefault)) -> Owned<\(initialType)> { Owned(initial) }
            """
    }

    func values() -> String {
        let bound = schema.mode == .shared ? ": Sendable" : ""
        let cases = schema.phases.map { "case \($0.caseName)(Observed<\($0.typeName)>)" }.joined(separator: "\n")
        let recordCases = schema.phases.map { "case .\($0.caseName)(let value): return value.record" }
            .joined(separator: "\n")
        let descriptionCases = schema.phases
            .map {
                "case .\($0.caseName)(let value): return \"\($0.caseName), revision \\(value.record.revision)\\(value.record.isClosed ? \", closed\" : \"\")\""
            }
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
        let choiceTypes = schema.routes
            .compactMap { route -> String? in
                guard let namespace = route.namespace else { return nil }
                let cases = route.choices.map { "case \($0)" }.joined(separator: "\n")
                return "/// The edges `\(route.name)` may choose.\n\(access)enum \(namespace)\(sendable) { \(cases) }"
            }
        let choices = (choiceTypes + ownedRouters.compactMap(ownedRoutedResultDeclaration)).joined(separator: "\n")
        let routeNamespace =
            choices.isEmpty ? "" : "/// The edges each router may choose among.\n\(access)enum Route { \(choices) }"
        let methods = (schema.transitions.map(observedMethod) + inputRouters.map(observedRoutedMethod))
            .joined(separator: "\n")
        // The runtime's short type names are module-qualified, so a client's own `Subscription`, such as
        // Combine's, cannot capture them. The rest of the expansion names them through these aliases.
        let policies =
            hasOperations
            ? """
            /// The disposition of a retained completion.
            \(access)typealias PendingStatus = StateMachine.PendingStatus
            """ : ""
        let snapshotSequence =
            schema.mode == .shared
            ? "/// A single-pass latest-value sequence of an owner's snapshots.\n\(access)typealias Snapshots = StateMachine.SnapshotSequence<Snapshot>"
            : "/// A single-pass latest-value sequence of a MainActor owner's snapshots.\n\(access)typealias MainActorSnapshots = StateMachine.MainActorSnapshotSequence<Snapshot>"
        return """
            fileprivate typealias _StateMachineEngine = \(engine)
            /// Validated bounds for managed admission and serial subscriptions.
            \(access)typealias Configuration = StateMachine.ManagedConfiguration
            /// Admission bounds for a manual local owner, with no subscriptions or runner policy.
            \(access)typealias LocalConfiguration = StateMachine.Limits
            /// A live observation registration; cancelling or releasing it stops delivery.
            \(access)typealias Subscription = StateMachine.SnapshotSubscription
            /// A live MainActor observation registration; cancelling or releasing it stops delivery.
            \(access)typealias MainActorSubscription = StateMachine.MainActorSnapshotSubscription
            /// Failure to register another live observer.
            \(access)typealias SubscriptionFailure = StateMachine.SubscriptionFailure
            \(snapshotSequence)
            \(policies)
            /// Why an owner refused a prepared candidate, in precedence order.
            \(access)typealias CommitRejection = StateMachine.CommitRejection
            /// An immutable historical payload with sealed complete-root provenance.
            \(access)struct Observed<Phase\(bound)>: \(schema.mode == .shared ? "Sendable, " : "")CustomStringConvertible {
                fileprivate let payload: Phase
                fileprivate let record: _StateMachineEngine.Snapshot
                fileprivate let claim: RuntimeDeliveryClaim?
                /// The copied historical payload.
                \(access)var value: Phase { payload }
                /// The owner-lifetime accepted revision.
                \(access)var revision: UInt64 { record.revision }
                /// The phase, revision, and closure of this observation, without its payload.
                \(access)var description: String { "\\(Phase.self), revision \\(record.revision)\\(record.isClosed ? ", closed" : "")" }
                \(methods)
            }
            /// A complete historical root observation with sealed provenance.
            \(access)enum Snapshot: \(schema.mode == .shared ? "Sendable, " : "")StateMachineSnapshot, CustomStringConvertible {
                \(cases)
                fileprivate var record: _StateMachineEngine.Snapshot { switch self { \(recordCases) } }
                /// The accepted revision of this observation.
                \(access)var revision: UInt64 { record.revision }
                /// Whether this historical root records closure.
                \(access)var isClosed: Bool { record.isClosed }
                /// Ordinary model data; constructing it confers no installation authority.
                \(access)var model: \(name) { record.model }
                /// The phase, revision, and closure of this observation, without its payload.
                \(access)var description: String { switch self { \(descriptionCases) } }
            }
            fileprivate static func _stateMachineSnapshot(_ record: _StateMachineEngine.Snapshot, claim: RuntimeDeliveryClaim? = nil) -> Snapshot {
                switch record.model { \(observationCases) }
            }
            /// A sealed inert candidate consumed by admission.
            ///
            /// A plan defect found while preparing travels inside it with the snapshot it was prepared on,
            /// so admission installs nothing and reports `CommitRejection.plan` unless the snapshot is
            /// another owner's or the owner is closed, which it reports first.
            \(access)struct Prepared: ~Copyable\(schema.mode == .shared ? ", Sendable" : "") {
                fileprivate let candidate: _StateMachineEngine.Proposal
                fileprivate init(_ candidate: _StateMachineEngine.Proposal) { self.candidate = candidate }
            }
            /// A closed typed dynamic routing rejection.
            \(access)enum PreparationRejection: Error {
                /// The input or outcome has no edge from the observed phase.
                case invalidPhase
                \(edgeFailures)
            }
            \(routeNamespace)
            /// A historical receipt for an atomic acceptance.
            \(access)struct Receipt: \(schema.mode == .shared ? "Sendable, " : "")StateMachineReceipt, CustomStringConvertible {
                /// The accepted historical observation.
                \(access)let snapshot: Snapshot
                fileprivate init(_ record: _StateMachineEngine.Snapshot) { snapshot = _stateMachineSnapshot(record) }
                /// The owner-lifetime accepted revision.
                \(access)var revision: UInt64 { snapshot.revision }
                /// The accepted phase, revision, and closure, without the payload.
                \(access)var description: String { snapshot.description }
            }
            /// Why `send` did not admit an input.
            \(access)enum SendRejection: Error {
                /// Routing or the authored transition declined the input before a candidate existed.
                case preparation(PreparationRejection)
                /// The owner refused the prepared candidate, or its effect plan is defective (`.plan`);
                /// read `snapshot()` for the current root.
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
        let argument: String
        let parameter: String
        let ticket: String
        let documentation: String
        if edge.trigger.kind == .input {
            parameter = edge.payloadType.map { "_ input: \($0)" } ?? ""
            argument = edge.payloadType == nil ? "" : ", input"
            ticket = "nil"
            documentation =
                router(of: edge).map { "/// Prepares the declared edge that the router `\($0.name)` selects." }
                ?? "/// Prepares the declared edge with phase authority preserved."
        } else {
            let op = operation(edge.trigger.name)
            let value = edge.trigger.kind == .success ? "\(op.name).Output" : op.failure
            parameter = "_ value: \(value), authority: RuntimeTicket"
            argument = ", value"
            ticket = "authority"
            documentation =
                "/// Prepares the completion edge that delivery selects, with operation authority preserved."
        }
        let call = "\(edge.failureType == nil ? "" : "try ")\(name).\(edge.name)(payload\(argument))"
        let starts = edge.effectNamespace != nil
        let result = starts ? "change" : "next"
        let resultType = starts ? "Change<\(after), \(authoredEffect(edge))>" : after
        let throwsClause = edge.failureType.map { " throws(\($0))" } ?? ""
        return """
            \(documentation)
            \(edgeAccess(edge, observed: true))func \(edge.name)(\(parameter))\(throwsClause) -> Prepared where Phase == \(before) {
                let \(result): \(resultType) = \(call)
                return _stateMachinePrepare(on: record, next: .\(edge.to)(\(starts ? "change.next" : "next")),
                    effects: \(starts ? "change.effects.map(\\.effect)" : "[]"),
                    from: \(index(edge.from)), to: \(index(edge.to)), invalidates: \(scopeIndices(edge.invalidates)),
                    requiring: \(ticket), claim: claim)
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
        "[" + scopes.map { String(schema.scopeKeys.firstIndex(of: $0)!) }.joined(separator: ", ") + "]"
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
                        \(op.name)Completion(\(op.isInfallible ? "value: value" : "result: .success(value)"), authority: authority)
                    }
                    \(["Void", "()"].contains(op.outputType) ? "/// Seals a successful terminal result that carries no value.\n\(access)func succeeded() -> \(op.name)Completion { succeeded(()) }" : "")
                    \(op.isInfallible ? "" : "/// Seals a failed terminal result for this exact work.\n\(access)func failed(_ value: \(op.failure)) -> \(op.name)Completion {\n\(op.name)Completion(result: .failure(value), authority: authority)\n}")
                }
                /// The sealed terminal result of one execution, which only its owner's `deliver` admits.
                \(access)struct \(op.name)Completion\(sendable) {
                    \(op.isInfallible ? "/// The value the operation produced; it cannot fail." : "/// The typed terminal value.")
                    \(access)let \(op.isInfallible ? "value: \(op.name).Output" : "result: Result<\(op.name).Output, \(op.failure)>")
                    fileprivate let authority: RuntimeTicket
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

    /// The dispatch of one prepared edge from `source`, mapping an authored failure into `PreparationRejection`.
    func dispatchEdge(_ edge: Schema.Transition, source: String, arguments: String) -> String {
        let call = "\(source).\(edge.name)(\(arguments))"
        guard edge.failureType != nil else { return "return \(call)" }
        return "do { return try \(call) } catch { throw .\(edge.name)(error) }"
    }

    func preparation() -> String {
        let eligibility = schema.scopeKeys
            .map { scope in
                if let op = schema.operations.first(where: { $0.scopeKey == scope }) {
                    return "[" + op.activeIn.map { String(index($0)) }.joined(separator: ", ") + "]"
                }
                return "Array(0..<\(schema.phases.count))"
            }
            .joined(separator: ", ")
        let starts = schema.operations.enumerated()
            .map { i, op in
                let scope = schema.scopeKeys.firstIndex(of: op.scopeKey)!
                let dependencies = op.requires.map { "RuntimeScopeID(kind: \(schema.scopeKeys.firstIndex(of: $0)!))" }
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
        // Only pairs that have an edge get a case. One default covers the rest, which keeps the
        // switch small and its exhaustiveness check trivial for a graph with many inputs.
        let missing = "default: throw .invalidPhase"
        var inputCases = schema.phases
            .flatMap { p in
                schema.inputs.compactMap { input -> String? in
                    let trigger = Schema.Trigger(kind: .input, name: input.caseName)
                    let dispatch =
                        dispatch(
                            from: p.caseName,
                            trigger: trigger,
                            source: "source",
                            payload: input.payloadType == nil ? nil : "input"
                        )
                    guard let dispatch else { return nil }
                    return
                        "case (.\(input.caseName)\(input.payloadType == nil ? "" : "(let input)"), .\(p.caseName)(let source)): \(dispatch)"
                }
            }
        if inputCases.count < schema.phases.count * schema.inputs.count { inputCases.append(missing) }
        var completionCases = schema.operations
            .flatMap { op in
                schema.phases.compactMap { phase -> String? in
                    let p = phase.caseName
                    let success = dispatch(
                        from: p,
                        trigger: Schema.Trigger(kind: .success, name: op.effect),
                        source: "source",
                        payload: "value"
                    )
                    let failure = dispatch(
                        from: p,
                        trigger: Schema.Trigger(kind: .failure, name: op.effect),
                        source: "source",
                        payload: "value"
                    )
                    guard success != nil || failure != nil else { return nil }
                    // An infallible completion carries its value directly and has no failure edge.
                    if op.isInfallible, let success {
                        return """
                            case (.\(op.effect)(let completion), .\(p)(let source)):
                                let value: \(op.name).Output = completion.value
                                \(success)
                            """
                    }
                    let succeeded =
                        success.map { "case .success(let value): \($0)" } ?? "case .success: throw .invalidPhase"
                    let failed =
                        failure.map { "case .failure(let value): \($0)" }
                        ?? (op.failureType == "Never"
                            ? "case .failure(let value): switch value {}" : "case .failure: throw .invalidPhase")
                    return """
                        case (.\(op.effect)(let completion), .\(p)(let source)):
                            switch completion.result {
                            \(succeeded)
                            \(failed)
                            }
                        """
                }
            }
        if completionCases.count < schema.operations.count * schema.phases.count { completionCases.append(missing) }
        let completion =
            hasOperations
            ? """
            fileprivate static func _stateMachineCompletion(_ completion: Completion, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
                switch (completion, snapshot) { \(completionCases.joined(separator: "\n")) }
            }
            """ : ""
        return """
            fileprivate static var _stateMachineEligibility: [[Int]] { [\(eligibility)] }
            fileprivate static func _stateMachinePrepare(
                on record: _StateMachineEngine.Snapshot, next: \(name), effects: [Effect], from: Int, to: Int,
                invalidates: [Int], requiring ticket: RuntimeTicket?, claim: RuntimeDeliveryClaim?
            ) -> Prepared {
                do throws(PlanRejection) {
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
                    return Prepared(.candidate(try _StateMachineEngine.prepare(on: record, next: next, requiring: ticket.map { [$0] } ?? [],
                        plan: .init(scopes: edits, retire: ticket.map { [$0] } ?? [], starts: starts,
                            controlCount: invalidates.count, finishingClaims: claim.map { [$0] } ?? []))))
                } catch { return Prepared(.defective(.init(error, preparedOn: record))) }
            }
            /// Routes an input against a historical snapshot, rejecting a missing phase edge explicitly.
            ///
            /// A plan defect is not a routing rejection: it travels inside the result, and admission reports it.
            \(access)static func prepare(_ input: Input, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
                \(schema.inputs.isEmpty ? "" : "switch (input, snapshot) { \(inputCases.joined(separator: "\n")) }")
            }
            \(completion)
            """
    }

    /// The dispatch of one (source phase, trigger) pair, or `nil` when the pair has no edge or router.
    ///
    /// An input dispatches to the phase's edge method, and a completion to its fileprivate edge with the
    /// completion's authority. A routed pair runs its router inline and dispatches to the edge it selects.
    func dispatch(from: String, trigger: Schema.Trigger, source: String, payload: String?) -> String? {
        let isInput = trigger.kind == .input
        let arguments = isInput ? payload ?? "" : "\(payload!), authority: completion.authority"
        let edges = schema.transitions.filter { $0.from == from && $0.trigger == trigger }
        guard let route = schema.routes.first(where: { $0.from == from && $0.trigger == trigger }) else {
            return edges.first.map { dispatchEdge($0, source: source, arguments: arguments) }
        }
        // A router sees plain values only; a completion's authority goes to the edge it selects. Each
        // function's failure becomes its own `PreparationRejection` case.
        let call = "\(name).\(route.name)(\(source).value\(payload.map { ", " + $0 } ?? ""))"
        guard let namespace = route.namespace else {
            return "do { try \(call) } catch { throw .\(route.name)(error) }"
        }
        let selection =
            route.failureType == nil
            ? "let selection: Route.\(namespace) = \(call)"
            : "let selection: Route.\(namespace)\ndo { selection = try \(call) } catch { throw .\(route.name)(error) }"
        let cases = edges.map { "case .\($0.name): \(dispatchEdge($0, source: source, arguments: arguments))" }
            .joined(separator: "\n")
        return """
            \(selection)
            switch selection { \(cases) }
            """
    }

    /// The phases saved data may restore, and the validated root for each owner's `restoring:` initializer.
    func restoration() -> String {
        let cases = schema.restorablePhases.map { "case \($0.caseName)(\($0.typeName))" }.joined(separator: "\n")
        let declaration = """
            /// A phase saved data can restore: one in which no operation is active, or one the
            /// `@Restoration` function lists in `allows:`. A restored owner has no outstanding work.
            \(access)enum Restoration\(sendable) {
                \(cases)
            }
            """
        guard let validator = schema.restoration else { return declaration }
        let roots = schema.restorablePhases
            .map {
                "case .\($0.caseName)(let payload): return (.\($0.caseName)(payload), [\(scopes(in: $0.caseName))])"
            }
            .joined(separator: "\n")
        return """
            \(declaration)
            fileprivate static func _stateMachineRestored(_ saved: \(validator.archiveType))\(restorationThrows) -> (model: \(name), scopes: [RuntimeScopeID]) {
                switch \(validator.failureType == nil ? "" : "try ")\(name).\(validator.name)(saved) { \(roots) }
            }
            """
    }
    /// The typed throws clause of every `restoring:` initializer.
    private var restorationThrows: String { schema.restoration?.failureType.map { " throws(\($0))" } ?? "" }
    /// Validates saved data before an owner creates any authority.
    private var restoredRoot: String {
        "let restored = \(schema.restoration?.failureType == nil ? "" : "try ")_stateMachineRestored(saved)"
    }
    /// The documentation of every `restoring:` initializer.
    private var restoringDocumentation: String {
        "/// Creates fresh authority at revision zero in the phase `\(schema.restoration?.name ?? "")` validates from saved data."
    }

    var ledger: String { "RuntimeDeliveryLedger<\(name), Effect, Completion, PreparationRejection>" }

    /// The pending-completion vocabulary shared by every owner of a schema with operations.
    func pendingDeclarations() -> String {
        let outcomes = schema.operations
            .map { op in
                let value = op.isInfallible ? "\(op.name).Output" : "Result<\(op.name).Output, \(op.failure)>"
                return "case \(op.effect)(\(value))"
            }
            .joined(separator: "\n")
        let projections = schema.operations
            .map {
                "case .\($0.effect)(let completion): outcome = .\($0.effect)(completion.\($0.isInfallible ? "value" : "result"))"
            }
            .joined(separator: "\n")
        return """
            fileprivate typealias _StateMachineLedger = \(ledger)
            /// The opaque identity of one retained terminal outcome of this schema's owners.
            \(access)struct PendingCompletionID: Hashable, Sendable {
                fileprivate let raw: RuntimePendingID
            }
            /// A retained terminal outcome and its delivery diagnostics.
            ///
            /// The outcome is an inert value: only `reconcile(id:)`, `retryAdmission(id:)`, or
            /// `discardPending(id:)` can settle the retained completion it describes.
            \(access)struct PendingCompletion\(sendable) {
                /// The retained terminal value of one operation.
                \(access)enum Outcome\(sendable) {
                    \(outcomes)
                }
                /// Why the last preparation or admission of a retained outcome did not commit.
                \(access)enum Rejection\(sendable) {
                    /// The router or completion edge rejected the outcome.
                    case preparation(PreparationRejection)
                    /// The owner refused the prepared candidate, or its effect plan is defective.
                    case admission(CommitRejection)
                }
                /// The opaque identity of this retained outcome.
                \(access)let id: PendingCompletionID
                /// The first retained terminal outcome.
                \(access)let outcome: Outcome
                /// The delivery state when this record was captured.
                \(access)let status: PendingStatus
                /// The last failed preparation or admission, when present.
                \(access)let lastRejection: Rejection?
                /// The saturating count of claimed preparations; capacity retries do not increment it.
                \(access)let attempts: UInt64
                /// Whether the preparation count has reached its representable limit.
                \(access)var attemptsSaturated: Bool { attempts == UInt64.max }
                fileprivate init(_ pending: _StateMachineLedger.Pending) {
                    id = PendingCompletionID(raw: pending.id)
                    switch pending.outcome { \(projections) }
                    status = pending.status
                    lastRejection = pending.lastRejection.map { reason in
                        switch reason {
                        case .preparation(let rejection): .preparation(rejection)
                        case .admission(let rejection): .admission(rejection)
                        }
                    }
                    attempts = pending.attempts
                }
            }
            /// The decision `deliver` made about one terminal outcome.
            \(access)enum DeliveryResult\(sendable) {
                /// The outcome committed.
                case committed(Receipt)
                /// The outcome is retained; its status says what admission is waiting for.
                case pending(PendingCompletionID, PendingStatus)
                /// The operation's authority is inactive or its outcome was already settled.
                case stale
                /// The completion was issued by a different owner.
                case foreignOwner
            }
            /// The result of one more attempt to admit a retained outcome.
            \(access)enum ReconcileResult\(sendable) {
                /// The retained outcome committed.
                case committed(Receipt)
                /// The outcome is still retained; its status says what admission is waiting for.
                case pending(PendingCompletionID, PendingStatus)
                /// Another attempt holds the only preparation claim.
                case inProgress
                /// No outcome with this identity is retained.
                case notPending
            }
            /// The result of revoking a retained outcome's operation.
            \(access)enum DiscardResult\(sendable) {
                /// The authority-only commit revoked the operation and disposed of its outcome.
                case discarded(Receipt)
                /// The owner refused the authority-only commit; the outcome stays retained.
                case rejected(CommitRejection)
                /// No outcome with this identity is retained.
                case notPending
            }
            fileprivate static func _stateMachineFinish(_ result: _StateMachineLedger.Finish) -> ReconcileResult {
                switch result {
                case .committed(let record): return .committed(Receipt(record))
                case .pending(let id, let status): return .pending(PendingCompletionID(raw: id), status)
                case .notPending: return .notPending
                }
            }
            fileprivate static func _stateMachineDeliveryPreparation(_ attempt: _StateMachineLedger.Attempt) -> _StateMachineLedger.Preparation {
                let prepared: Prepared
                do {
                    prepared = try _stateMachineCompletion(attempt.outcome, on: _stateMachineSnapshot(attempt.snapshot, claim: attempt.claim))
                } catch { return .failure(.preparation(error)) }
                switch prepared.candidate {
                case .candidate(let candidate): return .success(candidate)
                case .defective(let defect): return .failure(.admission(defect.rejection(against: attempt.snapshot)))
                }
            }
            """
    }

    /// The members of `Local` that drain commands, acknowledge execution, and settle retained outcomes.
    func localDelivery() -> String {
        """
        /// Transfers whole FIFO batches; physical execution occurs after mutating access ends.
        \(access)mutating func drainCommands(limit: Int) -> [CommandBatch] {
            engine.drain(limit: limit).map { _stateMachineBatch($0) }
        }
        /// Records actual termination independently of cancellation and completion delivery.
        \(access)mutating func acknowledgeExecution(_ execution: ExecutionHandle, disposition: ExecutionDisposition) -> AcknowledgmentResult {
            switch engine.acknowledge(execution.authority, skippedBeforeStart: disposition == .skippedBeforeStart) {
            case .recorded: return .recorded
            case .duplicate: return .duplicate
            case .foreignOwner: return .foreignOwner
            }
        }
        /// Retains the first outcome and attempts one typed preparation against the current root.
        ///
        /// This is the only way to submit a terminal outcome. A later outcome for the same work never
        /// replaces the retained one; it reports that outcome's status instead.
        \(access)mutating func deliver(_ completion: Completion) -> DeliveryResult {
            switch ledger.retain(completion, for: completion.authority, in: &engine) {
            case .stale: return .stale
            case .foreignOwner: return .foreignOwner
            case .pending(let raw):
                let id = PendingCompletionID(raw: raw)
                guard let pending = ledger.pending.first(where: { $0.id == raw }) else { return .stale }
                if pending.status != .awaitingAdmission { return .pending(id, pending.status) }
                switch reconcile(id: id) {
                case .committed(let receipt): return .committed(receipt)
                case .pending(let id, let status): return .pending(id, status)
                case .inProgress: return .pending(id, .preparing)
                case .notPending: return .stale
                }
            }
        }
        \(operationDeliveries(prefix: "mutating ", asynchronous: "", awaiting: ""))
        /// Claims one retained outcome before evaluating domain code.
        \(access)mutating func reconcile(id: PendingCompletionID) -> ReconcileResult {
            switch ledger.claim(id.raw, in: &engine) {
            case .inProgress: return .inProgress
            case .notPending: return .notPending
            case .claimed(let attempt):
                let preparation = _stateMachineDeliveryPreparation(attempt)
                return _stateMachineFinish(ledger.finish(attempt, preparation: preparation, in: &engine))
            }
        }
        /// Retries admission of a retained candidate that was waiting for capacity, without preparing it again.
        ///
        /// Draining and acknowledging never admit a retained completion; call this after they free capacity.
        \(access)mutating func retryAdmission(id: PendingCompletionID) -> ReconcileResult {
            _stateMachineFinish(ledger.retryAdmission(id.raw, in: &engine))
        }
        /// Queries immutable first-outcome records without claiming preparation.
        \(access)borrowing func pendingCompletions() -> [PendingCompletion] { ledger.pending.map(PendingCompletion.init) }
        /// Revokes one retained operation using an atomic authority-only commit.
        \(access)mutating func discardPending(id: PendingCompletionID) -> DiscardResult {
            guard let result = ledger.discard(id.raw, in: &engine) else { return .notPending }
            switch result {
            case .committed(let record): return .discarded(Receipt(record))
            case .rejected(let reason, _): return .rejected(reason)
            }
        }
        """
    }

    /// The shutdown and flush vocabulary shared by every managed owner.
    func lifetimeDeclarations() -> String {
        let operationFields =
            hasOperations
            ? """
            /// Whether an automatic retry of a retained completion is still scheduled.
            \(access)let isRetrying: Bool
            /// The identities of the retained terminal outcomes.
            \(access)let pendingCompletions: [PendingCompletionID]
            /// The executions, deliveries, and preparations that remain tracked.
            \(access)let outstandingExecutions: [OutstandingExecution]
            """ : ""
        let operationProjections =
            hasOperations
            ? """
            isRetrying = raw.isRetrying
            pendingCompletions = raw.pendingCompletions.map { PendingCompletionID(raw: $0) }
            outstandingExecutions = raw.outstandingExecutions
            """ : ""
        return """
            /// The obligations a managed owner still tracked when its shutdown deadline expired.
            ///
            /// It is captured in the same observation that found the deadline expired, so it always names
            /// at least one unsettled obligation. It holds no model data and no authority over the owner.
            \(access)struct ShutdownDiagnostics: Equatable, Sendable {
                \(hasOperations ? "/// An execution and delivery obligation that remained tracked.\n\(access)typealias OutstandingExecution = StateMachine.ShutdownDiagnostics.OutstandingExecution" : "")
                /// The owner's last accepted revision at the observation.
                \(access)let acceptedRevision: UInt64
                /// The revision of the last fully processed FIFO batch.
                \(access)let processedThrough: UInt64
                /// Whether accepted ordinary or terminal batches still await processing.
                \(access)let hasQueuedBatches: Bool
                /// Whether a FIFO processing turn still owns responsibility.
                \(access)let isDraining: Bool
                \(operationFields)
                fileprivate init(_ raw: StateMachine.ShutdownDiagnostics) {
                    acceptedRevision = raw.acceptedRevision
                    processedThrough = raw.processedThrough
                    hasQueuedBatches = raw.hasQueuedBatches
                    isDraining = raw.isDraining
                    \(operationProjections)
                }
            }
            /// Whether shutdown joined every obligation or stopped waiting at its deadline.
            ///
            /// A timeout leaves the owner closed and its outstanding work tracked.
            \(access)enum ShutdownResult: Equatable, Sendable {
                /// Every execution, delivery, and preparation obligation settled.
                case quiescent
                /// The deadline passed first; the diagnostics describe what was still outstanding.
                case timedOut(ShutdownDiagnostics)
                fileprivate init(_ raw: StateMachine.ShutdownDiagnostics?) {
                    self = raw.map { .timedOut(ShutdownDiagnostics($0)) } ?? .quiescent
                }
            }
            /// Whether `flush(through:)` waited for a receipt's batch to be processed.
            \(access)enum FlushResult: Equatable, Sendable {
                /// \(hasOperations ? "Cancellation and launch decisions through the receipt have been processed." : "The owner offered every snapshot through the receipt to its subscriptions.")
                case processed
                /// The receipt was issued by a different owner, so there was nothing to wait for.
                case foreignOwner
            }
            """
    }

    func local() -> String {
        let ops = hasOperations
        // A Local queues only batches that carry a command, and the terminal batch; every other
        // receipt is the return value of `send` or `commit`. A run of plain edits needs no draining.
        let batches = ", recording: .commands"
        let restoring = schema.restoration.map { validator in
            """

            \(restoringDocumentation)
            \(access)init(restoring saved: \(validator.archiveType), configuration: LocalConfiguration = .default)\(restorationThrows) {
                \(restoredRoot)
                engine = _StateMachineEngine(restored.model, scopes: restored.scopes, limits: configuration\(batches))
            }
            """
        }
        return """
            \(ops ? pendingDeclarations() : "")
            \(lifetimeDeclarations())
            /// A noncopyable manually driven owner with an embedded value engine.
            \(access)struct Local: ~Copyable {
                fileprivate var engine: _StateMachineEngine
                \(ops ? "fileprivate var ledger = _StateMachineLedger()" : "")
                /// Creates fresh authority only in the declared initial phase.
                \(access)init(_ initial: \(initialType)\(initialDefault), configuration: LocalConfiguration = .default) {
                    engine = _StateMachineEngine(.\(schema.initial)(initial), scopes: [\(initialScopes)], limits: configuration\(batches))
                }\(restoring ?? "")
                /// Returns an immutable historical observation.
                \(access)borrowing func snapshot() -> Snapshot { _stateMachineSnapshot(engine.snapshot) }
                /// Consumes and atomically accepts or rejects a complete candidate.
                \(access)mutating func commit(_ prepared: consuming Prepared) -> CommitResult {
                    switch prepared.candidate {
                    case .defective(let defect): return _stateMachineAdmission(engine.reject(defect))
                    case .candidate(let candidate):
                        let result = engine.commit(candidate)
                        \(ops ? "ledger.prune(in: engine)" : "")
                        return _stateMachineAdmission(result)
                    }
                }
                /// Routes, prepares and admits one input against the current root.
                @discardableResult
                \(access)mutating func send(_ input: Input) throws(SendRejection) -> Receipt {
                    let prepared: Prepared
                    do { prepared = try \(name).prepare(input, on: snapshot()) } catch { throw .preparation(error) }
                    switch commit(prepared) {
                    case .committed(let receipt): return receipt
                    case .rejected(let reason, _): throw .commit(reason)
                    }
                }
                \(ops ? localDelivery() : "")
                /// Ends admission while retaining historical read access.
                @discardableResult
                \(access)mutating func close() -> Receipt {
                    let result = engine.close()
                    \(ops ? "ledger.prune(in: engine)" : "")
                    return Receipt(result)
                }
                \(ops ? """
                /// Closure, FIFO transfer, and all actual execution and delivery obligations have settled.
                \(access)var isQuiescent: Bool { engine.isQuiescent }
                """ : "")
            }
            """
    }
    /// The parameters after the initial payload or saved data in every managed owner's designated initializer.
    private func managedParameters(drivers: String) -> String {
        guard hasOperations else { return "configuration: Configuration = .default" }
        return
            "drivers: \(drivers), configuration: Configuration = .default, completionPolicy: CompletionPolicy = .retryPure"
    }

    /// The type of one operation's driver: the bare output when it cannot fail, otherwise a `Result`.
    ///
    /// A fallible driver returns `Result` rather than throwing, because a typed-throws closure literal
    /// does not infer its thrown type.
    func driverType(_ op: Schema.Operation, isolation: String) -> String {
        let output = op.isInfallible ? "\(op.name).Output" : "Result<\(op.name).Output, \(op.failure)>"
        return "\(isolation) (\(op.name).Input) async -> \(output)"
    }

    /// A managed owner's completion policy, which carries an optional handler in the owner's isolation.
    ///
    /// It begins with a line break so that a schema without operations gains no blank line.
    private func completionPolicy(isolation: String, sendable: Bool) -> String {
        guard hasOperations else { return "" }
        let handler = "\(isolation) (PendingCompletion) -> Void"
        return "\n" + """
            /// How this owner settles a retained completion that cannot commit when it is delivered.
            ///
            /// The default, `.retryPure`, evaluates a completion's router and edge again after another
            /// commit wins the race, so it assumes those functions are pure. Choose
            /// `.manual(onReconciliationRequired:)` when they are not.
            ///
            /// A handler, when given, runs outside the owner's critical section each time a retained
            /// completion's status becomes `reconciliationRequired`: its completion edge or router threw,
            /// its effect plan is defective, the owner refused its admission, or an explicit
            /// `reconcile(id:)` did not commit. Settle it with `reconcile(id:)` or `discardPending(id:)`.
            \(access)struct CompletionPolicy\(sendable ? ": Sendable" : "") {
                fileprivate let runtime: RuntimeCompletionPolicy
                fileprivate let reconciliationRequired: \(isolation) (_StateMachineLedger.Pending) -> Void
                private init(_ runtime: RuntimeCompletionPolicy, handler: @escaping \(handler)) {
                    self.runtime = runtime
                    reconciliationRequired = { handler(PendingCompletion($0)) }
                }
                /// Prepares a completion again against the current state when another commit wins the race,
                /// at most four times per turn before yielding to other work, and notifies no one.
                ///
                /// Choose it only when every completion edge and router is deterministic and free of side
                /// effects; the compiler does not check that. A completion retained for any other reason
                /// stays visible only through `pendingCompletions()`.
                \(access)static var retryPure: CompletionPolicy { CompletionPolicy(.retryPure, handler: { _ in }) }
                /// Retries lost races as `retryPure` does, and passes every completion that still needs
                /// reconciliation to `handler`.
                \(access)static func retryPure(onReconciliationRequired handler: @escaping \(handler)) -> CompletionPolicy {
                    CompletionPolicy(.retryPure, handler: handler)
                }
                /// Never prepares a completion again on its own: every completion that needs reconciliation,
                /// including one whose preparation lost a race with another commit, goes to `handler`.
                \(access)static func manual(onReconciliationRequired handler: @escaping \(handler)) -> CompletionPolicy {
                    CompletionPolicy(.manualOnConflict, handler: handler)
                }
            }
            """
    }

    /// The runtime host arguments after `configuration`, which wire execution and delivery or, without
    /// operations, close over the uninhabited outcome.
    private var managedHooks: String {
        guard hasOperations else {
            return """
                driver: { raw in switch raw.descriptor {} },
                ticket: { (outcome: Never) -> RuntimeTicket in },
                prepare: { attempt in switch attempt.outcome {} }
                """
        }
        return """
            policy: completionPolicy.runtime, driver: { raw in
                switch raw.descriptor { \(managedExecutions) }
            }, ticket: { (outcome: Completion) -> RuntimeTicket in outcome.authority },
            prepare: { _stateMachineDeliveryPreparation($0) },
            reconciliationRequired: completionPolicy.reconciliationRequired
            """
    }

    /// The pending-completion members of a managed owner; a managed owner offers no `deliver`, because
    /// no caller holds its work.
    private func managedPending(asynchronous: String, awaiting: String, delivery: String) -> String {
        guard hasOperations else { return "" }
        return """
            /// Reads immutable retained first-outcome diagnostics.
            \(access)func pendingCompletions()\(asynchronous) -> [PendingCompletion] { \(awaiting)host.pendingCompletions().map(PendingCompletion.init) }
            /// Explicitly claims a fresh preparation attempt for a retained outcome.
            \(access)func reconcile(id: PendingCompletionID)\(asynchronous) -> ReconcileResult { Self.reconciled(\(awaiting)host.reconcile(id: id.raw)) }
            /// Revokes retained delivery with an authority-only admission.
            \(access)func discardPending(id: PendingCompletionID)\(asynchronous) -> DiscardResult { Self.discarded(\(awaiting)host.discardPending(id: id.raw)) }
            // The raw host reports only the cases each operation can produce; the rest cannot occur.
            private static func reconciled(_ result: \(delivery)) -> ReconcileResult {
                switch result {
                case .committed(let record): return .committed(Receipt(record))
                case .pending(let id, let status): return .pending(PendingCompletionID(raw: id), status)
                case .inProgress: return .inProgress
                default: return .notPending
                }
            }
            private static func discarded(_ result: \(delivery)) -> DiscardResult {
                switch result {
                case .discarded(let record): return .discarded(Receipt(record))
                case .rejected(let reason): return .rejected(reason)
                default: return .notPending
                }
            }
            """
    }

    /// The flush and shutdown members every managed owner shares.
    private var lifetimeMembers: String {
        let flush =
            hasOperations
            ? "/// Waits until cancellation and launch decisions through this owner's receipt have been processed."
            : "/// Waits until this owner has offered every snapshot through its receipt to its subscriptions."
        let obligations =
            hasOperations
            ? "every execution, delivery, and preparation obligation settles" : "every accepted batch is processed"
        return """
            \(flush)
            \(access)func flush(through receipt: Receipt) async -> FlushResult {
                await host.flush(through: receipt.snapshot.record) ? .processed : .foreignOwner
            }
            /// Closes admission, then waits until \(obligations).
            ///
            /// With a `deadline`, it stops waiting once the deadline passes and reports what was still
            /// outstanding at that moment; the owner stays closed and that work stays tracked. Without one,
            /// it always returns `.quiescent`.
            @discardableResult
            \(access)func shutdown(deadline: ContinuousClock.Instant? = nil) async -> ShutdownResult {
                ShutdownResult(await host.shutdown(deadline: deadline))
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
                "/// Executes this operation within the selected isolation.\n\(access)let \($0.effect): \(driverType($0, isolation: "@MainActor"))"
            }
            .joined(separator: "\n")
        let params = schema.operations
            .map { "\($0.effect): @escaping \(driverType($0, isolation: "@MainActor"))" }
            .joined(separator: ", ")
        let assignments = schema.operations.map { "self.\($0.effect) = \($0.effect)" }.joined(separator: "\n")
        let driverDeclaration =
            mainActor && hasOperations
            ? """
            /// Immutable operation selections whose non-Sendable values stay within MainActor.
            @MainActor \(access)struct MainActorDrivers {
                \(fields)
                /// Selects every driver for this owner's lifetime.
                \(access)init(\(params)) { \(assignments) }
            }
            """ : ""
        let confined = mainActor && schema.mode != .shared
        let projection =
            mainActor
            ? [
                "/// Registers a single-pass sequence of the latest `Sendable` projections of complete snapshots.",
                "///",
                "/// `transform` runs on the main actor when a snapshot is delivered. The sequence supports every",
                "/// `AsyncSequence` operator on every supported OS version.",
                "\(access)func snapshots<Projection: Sendable>(",
                "    _ transform: @escaping @MainActor (Snapshot) -> Projection",
                ") throws(SubscriptionFailure) -> StateMachine.SnapshotSequence<Projection> {",
                "    try host.sendableSnapshots { transform(_stateMachineSnapshot($0)) }",
                "}",
            ]
            .joined(separator: "\n")
            : ""
        func construction(model: String, scopes: String) -> String {
            """
            host = Host(\(model), scopes: \(scopes), configuration: configuration,
                        \(managedHooks))
            """
        }
        let restoring = schema.restoration.map { validator in
            """

                \(restoringDocumentation)
                \(access)init(restoring saved: \(validator.archiveType), \(managedParameters(drivers: drivers)))\(restorationThrows) {
                    \(restoredRoot)
                    \(construction(model: "restored.model", scopes: "restored.scopes"))
                }
            """
        }
        return """
            \(driverDeclaration)
            /// A sealed sole-writer \(mainActor ? "MainActor" : "native actor") owner with managed execution.
            \(mainActor ? "@MainActor " : "")\(access)final class \(facade): \(mainActor ? "MainActorStateMachineHost" : "Sendable") {
                private typealias Host = \(runtime)<\(name), Effect, \(outcome), PreparationRejection>
                private let host: Host\(completionPolicy(isolation: isolation, sendable: !mainActor))
                /// Creates fresh authority\(hasOperations ? " and immutable execution selections" : "").
                \(access)init(_ initial: \(initialType)\(initialDefault), \(managedParameters(drivers: drivers))) {
                    \(construction(model: ".\(schema.initial)(initial)", scopes: "[\(initialScopes)]"))
                }\(restoring ?? "")\(closureInitializers(drivers: drivers, isolation: isolation))
                /// Captures a complete historical observation.
                \(access)func snapshot()\(asynchronous) -> Snapshot { _stateMachineSnapshot(\(awaiting)host.snapshot()) }
                /// Routes, prepares and admits one input in a single isolated turn without suspension.
                @discardableResult
                \(access)func send(_ input: Input)\(asynchronous) throws(SendRejection) -> Receipt {
                    let result = \(awaiting)host.prepareAndCommit { raw -> Result<_StateMachineEngine.Candidate, SendRejection> in
                        let prepared: Prepared
                        do throws(PreparationRejection) {
                            prepared = try \(name).prepare(input, on: _stateMachineSnapshot(raw))
                        } catch { return .failure(.preparation(error)) }
                        switch prepared.candidate {
                        case .candidate(let candidate): return .success(candidate)
                        case .defective(let defect): return .failure(.commit(defect.rejection(against: raw)))
                        }
                    }
                    switch result {
                    case .success(.committed(let record)): return Receipt(record)
                    case .success(.rejected(let reason, _)): throw .commit(reason)
                    case .failure(let reason): throw reason
                    }
                }
                /// Consumes an explicitly prepared historical candidate, rechecking freshness.
                \(access)func commit(_ prepared: consuming Prepared)\(asynchronous) -> CommitResult {
                    switch prepared.candidate {
                    case .candidate(let candidate): return _stateMachineAdmission(\(awaiting)host.commit(candidate))
                    case .defective(let defect): return _stateMachineAdmission(\(awaiting)host.reject(defect))
                    }
                }
                /// Subscribes to initial, accepted and terminal complete snapshots.
                \(access)func subscribe(_ receive: @escaping \(isolation) (Snapshot) -> Void,
                    onFinish: @escaping \(isolation) () -> Void = {})\(asynchronous) throws(SubscriptionFailure) -> \(token) {
                    try \(awaiting)host.subscribe({ receive(_stateMachineSnapshot($0)) }, onFinish: onFinish)
                }
                /// Registers a single-pass sequence of the latest complete snapshots.
                ///
                /// The sequence ends after the closed snapshot, when its task is cancelled, or when this owner is released.
                \(access)func snapshots()\(asynchronous) throws(SubscriptionFailure) -> \(confined ? "MainActorSnapshots" : "Snapshots") {
                    try \(awaiting)host.\(mainActor && !confined ? "sendableSnapshots" : "snapshots") { _stateMachineSnapshot($0) }
                }
                \(projection)
                \(managedPending(asynchronous: asynchronous, awaiting: awaiting, delivery: "RuntimeHostDelivery<\(name), Effect>"))
                /// Closes admission while preserving historical model data.
                @discardableResult
                \(access)func close()\(asynchronous) -> Receipt { Receipt(\(awaiting)host.close()) }
                \(lifetimeMembers)
                \(hasOperations ? "/// Actual workers whose joined termination has not yet been processed." : "")
                \(hasOperations ? "\(access)var runningCount: Int { \(mainActor ? "host.runningCount" : "get async { await host.runningCount }") }" : "")
                /// Live observer registrations.
                \(access)var subscriberCount: Int { \(mainActor ? "host.subscriberCount" : "get async { await host.subscriberCount }") }
                /// Whether closure and all managed obligations have settled.
                \(access)var isQuiescent: Bool { \(mainActor ? "host.isQuiescent" : "get async { await host.isQuiescent }") }
            }
            """
    }

    func shared() -> String {
        let fields = schema.operations
            .map {
                "/// Executes one typed operation outside admission locks.\n\(access)let \($0.effect): \(driverType($0, isolation: "@Sendable"))"
            }
            .joined(separator: "\n")
        let params = schema.operations
            .map { "\($0.effect): @escaping \(driverType($0, isolation: "@Sendable"))" }
            .joined(separator: ", ")
        let assignments = schema.operations.map { "self.\($0.effect) = \($0.effect)" }.joined(separator: "\n")
        let raw = "RuntimeSharedHost<\(name), Effect, \(outcome), PreparationRejection>"
        func construction(model: String, scopes: String) -> String {
            """
            host = RuntimeSharedHost(\(model), scopes: \(scopes), limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
                        \(managedHooks))
            """
        }
        let restoring = schema.restoration.map { validator in
            """

                \(restoringDocumentation)
                \(access)init(restoring saved: \(validator.archiveType), \(managedParameters(drivers: "Drivers")))\(restorationThrows) {
                    \(restoredRoot)
                    \(construction(model: "restored.model", scopes: "restored.scopes"))
                }
            """
        }
        let driverDeclaration =
            hasOperations
            ? """
            /// Immutable typed execution selection for one managed owner's lifetime.
            \(access)struct Drivers: Sendable {
                \(fields)
                /// Selects all drivers for this owner.
                \(access)init(\(params)) { \(assignments) }
            }
            """ : ""
        return """
            \(driverDeclaration)
            /// A synchronous shared owner with managed physical execution and terminal delivery.
            \(access)final class Shared: Sendable {
                private let host: \(raw)\(completionPolicy(isolation: "@Sendable", sendable: true))
                /// Creates fresh initial authority\(hasOperations ? " and retains the driver selection immutably" : "").
                \(access)init(_ initial: \(initialType)\(initialDefault), \(managedParameters(drivers: "Drivers"))) {
                    \(construction(model: ".\(schema.initial)(initial)", scopes: "[\(initialScopes)]"))
                }\(restoring ?? "")\(closureInitializers(drivers: "Drivers", isolation: "@Sendable"))
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
                    let prepared: Prepared
                    do { prepared = try \(name).prepare(input, on: snapshot()) } catch { throw .preparation(error) }
                    switch commit(prepared) {
                    case .committed(let receipt): return receipt
                    case .rejected(let reason, _): throw .commit(reason)
                    }
                }
                /// Consumes one candidate into an atomic admission attempt.
                \(access)func commit(_ prepared: consuming Prepared) -> CommitResult {
                    switch prepared.candidate {
                    case .candidate(let candidate): return _stateMachineAdmission(host.commit(candidate))
                    case .defective(let defect): return _stateMachineAdmission(host.reject(defect))
                    }
                }
                \(managedPending(asynchronous: "", awaiting: "", delivery: "\(raw).Delivery"))
                /// Ends admission and schedules cancellation in FIFO order.
                @discardableResult
                \(access)func close() -> Receipt { Receipt(host.close()) }
                \(lifetimeMembers)
                \(hasOperations ? "/// Actual workers whose joined termination has not yet been processed." : "")
                \(hasOperations ? "\(access)var runningCount: Int { get async { await host.runningCount } }" : "")
                /// Live observer registrations.
                \(access)var subscriberCount: Int { host.subscriberCount }
                /// Whether closure and all managed obligations have settled.
                \(access)var isQuiescent: Bool { host.isQuiescent }
            }
            """
    }

    /// The convenience initializers of a managed owner that take each operation's driver as its own parameter.
    ///
    /// Each label is the operation's effect case followed by `Driver`, so no operation name can collide with
    /// another parameter. A schema without operations has none.
    private func closureInitializers(drivers: String, isolation: String) -> String {
        guard !schema.operations.isEmpty else { return "" }
        let closures = schema.operations
            .map { "\($0.effect)Driver: @escaping \(driverType($0, isolation: isolation))" }
            .joined(separator: ",\n")
        let selection = schema.operations.map { "\($0.effect): \($0.effect)Driver" }.joined(separator: ", ")
        let restoring = schema.restoration.map { validator in
            """

                /// Creates fresh authority in the phase `\(validator.name)` validates from saved data, selecting one driver closure per operation.
                \(access)convenience init(restoring saved: \(validator.archiveType),
                    \(closures),
                    configuration: Configuration = .default,
                    completionPolicy: CompletionPolicy = .retryPure)\(restorationThrows) {
                    \(validator.failureType == nil ? "" : "try ")self.init(restoring: saved, drivers: \(drivers)(\(selection)),
                        configuration: configuration, completionPolicy: completionPolicy)
                }
            """
        }
        return """

                /// Creates fresh initial authority, selecting one driver closure per operation.
                \(access)convenience init(_ initial: \(initialType)\(initialDefault),
                    \(closures),
                    configuration: Configuration = .default,
                    completionPolicy: CompletionPolicy = .retryPure) {
                    self.init(initial, drivers: \(drivers)(\(selection)),
                        configuration: configuration, completionPolicy: completionPolicy)
                }\(restoring ?? "")
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
    private var initialScopes: String { scopes(in: schema.initial) }

    /// The scope identifiers a fresh owner activates in a phase, matching `_stateMachineEligibility`.
    private func scopes(in phase: String) -> String {
        schema.scopeKeys.enumerated()
            .compactMap { i, scope -> String? in
                let operation = schema.operations.first { $0.scopeKey == scope }
                guard operation == nil || operation!.activeIn.contains(phase) else { return nil }
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
                    return .\(op.effect)(\(op.name)Completion(\(op.isInfallible ? "value" : "result"): await drivers.\(op.effect)(input), authority: raw.ticket))
                """
            }
            .joined(separator: "\n")
    }

}
