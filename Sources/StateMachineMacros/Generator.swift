import Foundation
import SwiftParser
import SwiftSyntax
import SwiftSyntaxBuilder

struct Generator {
    let schema: Schema
    /// The names of throwing functions whose `PreparationRejection` cases are told apart by phase.
    let distinguishedRejections: Set<String>

    /// Creates a generator of the members of `schema`.
    ///
    /// Generated code spells each authored type that a nested generated scope would capture through its
    /// schema-level alias, as ``Schema/shieldedSpellings`` lists them.
    init(schema: Schema) {
        self.schema = schema.shieldingAuthoredSpellings()
        distinguishedRejections = self.schema.namesThrowingDifferentFailures
    }
    var name: String { schema.name }
    var access: String {
        let declared = schema.access == .private ? Schema.Access.fileprivate : schema.access
        return declared.rawValue + " "
    }
    var sendable: String { schema.mode == .shared ? ": Swift::Sendable" : "" }
    var initialType: String { phase(schema.initial) }
    /// The default of every fresh entry point's initial parameter, when the schema declares one.
    var initialDefault: String { schema.initialDefault.map { " = \($0)" } ?? "" }
    var engine: String { "StateMachine::RuntimeState<\(name), Effect>" }
    /// Whether the schema declares any operation, and so generates work, completion, and delivery surfaces.
    var hasOperations: Bool { !schema.operations.isEmpty }
    /// Whether the schema declares any event, so its managed owners take handlers.
    var hasEvents: Bool { !schema.events.isEmpty }
    /// Whether a `Local` owner drains command batches because it has work to start or events to emit.
    var hasCommands: Bool { schema.generates(.local) && (hasOperations || hasEvents) }
    /// The retained-outcome type of the runtime hosts (`Completion`, or `Never` without operations).
    var outcome: String { hasOperations ? "Completion" : "Swift::Never" }
    func declaration(_ source: String) -> DeclSyntax { DeclSyntax(stringLiteral: source) }
    /// How generated code names the schema in an expression, where a local value of the schema's name,
    /// such as a parameter `input` of a schema named `input`, would hide the type.
    var schemaReference: String { "_StateMachineSchema" }
    /// A generated spelling of a schema member, such as `Load.Output`, spelled from the schema's name for
    /// a generated scope that declares a type of the member's name.
    ///
    /// Module-qualified spellings stay as-is.
    func qualified(_ spelling: String) -> String { spelling.hasPrefix("Swift::") ? spelling : "\(name).\(spelling)" }

    /// How generated code names the type whose static function it calls for an authored function, using
    /// either the schema or, for a deprecated function, the protocol requirement it witnesses so the call
    /// draws no warning.
    func authored(_ deprecation: Schema.Deprecation?) -> String {
        deprecation == nil ? schemaReference : "\(schemaReference)._stateMachineDeprecated"
    }

    /// The deprecation a generated public member named for an authored function repeats, before its modifiers.
    func deprecated(_ deprecation: Schema.Deprecation?) -> String { deprecation.map { $0.attribute + " " } ?? "" }

    /// The authored functions' deprecations, each once, in declaration order, paired with whether a call
    /// to the function needs `try`.
    ///
    /// A call needs `try` when the function declares `throws` and the macro reads its failure as other
    /// than `Never`. An edge that returns `Advance` reports its failure without throwing.
    var deprecations: [(deprecation: Schema.Deprecation, throwing: Bool)] {
        var seen: Set<String> = []
        let all =
            schema.transitions.map { ($0.deprecation, $0.failureType != nil) }
            + schema.routes.map { ($0.deprecation, $0.failureType != nil) }
            + [(schema.restoration?.deprecation, schema.restoration?.failureType != nil)]
        return all.compactMap { deprecation, throwing in deprecation.map { ($0, throwing && $0.declaresThrows) } }
            .filter { seen.insert($0.deprecation.declaration).inserted }
    }

    /// The protocol through which generated code calls each deprecated authored function, and the type whose
    /// deprecated members witness it.
    ///
    /// Calling through a protocol requirement draws no deprecation warning, so only the generated public
    /// members named for a function repeat its deprecation.
    func deprecatedCalls() -> String {
        guard !deprecations.isEmpty else { return "" }
        return """
            fileprivate protocol _StateMachineDeprecatedFunctions {
                \(deprecations.map(\.deprecation.declaration).joined(separator: "\n"))
            }
            fileprivate enum _StateMachineDeprecatedCalls: _StateMachineDeprecatedFunctions {
                \(deprecations.map { "@available(*, deprecated)\n\($0.deprecation.declaration) { \($0.throwing ? "try " : "")\(schemaReference).\($0.deprecation.call) }" }
                .joined(separator: "\n"))
            }
            fileprivate static var _stateMachineDeprecated: any _StateMachineDeprecatedFunctions.Type {
                _StateMachineDeprecatedCalls.self
            }
            """
    }

    func members() throws -> [DeclSyntax] {
        var result = [witnesses(), effects(), requests(), deprecatedCalls()]
        if schema.generates(.owned) { result.append(owned()) }
        if schema.generatesObservingOwner {
            result.append(values())
            if hasOperations || hasCommands { result.append(operations()) }
            result += [preparation(), restoration()]
            if hasOperations { result.append(pendingDeclarations()) }
            if schema.generatesManagedOwner { result.append(lifetimeDeclarations()) }
            if schema.generates(.local) { result.append(local()) }
            if schema.generates(.mainActorHost) { result.append(managed(mainActor: true)) }
            if hasOperations, schema.generates(.shared) || schema.generates(.actorHost) { result.append(drivers()) }
            if schema.generates(.shared) { result.append(shared()) }
            if schema.generates(.actorHost) { result.append(managed(mainActor: false)) }
            if schema.generates(.isolatedHost) { result.append(isolatedHost()) }
        } else {
            // Routers' choice types are part of the authored signatures even when only `Owned` exists.
            result.append(routeNamespace())
        }
        result.append(graph())
        let declarations = result.flatMap { source in
            Parser.parse(source: source).statements.compactMap { $0.item.as(DeclSyntax.self) }
        }
        guard !schema.spellingAliases.isEmpty else { return declarations }
        let shielded = SpellingShield(
            aliases: schema.spellingAliases,
            schemaAccess: schema.access,
            authoredIdentifiers: schema.authoredIdentifiers,
            parse: schema.spellings.type
        )
        .apply(to: declarations)
        return shielded.declarations + shielded.aliases.map { DeclSyntax(stringLiteral: spellingAlias($0)) }
    }

    /// The schema-level alias of an authored spelling that a nested generated scope would capture.
    ///
    /// Its documentation shows the spelling on one line, as the graph does, so authored text that spans
    /// lines or holds comments cannot end the comment.
    func spellingAlias(_ alias: SpellingShield.Alias) -> String {
        """
        /// `\(Schema.displaySpelling(schema.spellings.type(alias.spelling)))` as the schema resolves it, for generated code in scopes that declare another type of its name.
        \(alias.access.rawValue) typealias \(alias.name) = \(alias.spelling)
        """
    }

    /// The body of a `send`, or nothing for an `Input` without cases, whose value no caller can
    /// construct so no statement after it could run.
    ///
    /// Every owner's template places the body two levels inside the owner, so its continuation lines
    /// are indented to match.
    func sendBody(_ body: String) -> String {
        schema.inputs.isEmpty ? "" : body.replacingOccurrences(of: "\n", with: "\n        ")
    }

    /// The effect type an edge returns, or `Never` when it starts nothing.
    func authoredEffect(_ edge: Schema.Transition) -> String { schema.effectType(edge) ?? "Swift::Never" }

    /// The arguments of a call to an authored function, consisting of the source when it takes one, then
    /// the trigger payload, then a completion's request labeled `request:` when it takes one.
    func authoredArguments(
        _ edge: Schema.Transition,
        source: String,
        payload: String?,
        request: String? = nil
    ) -> String {
        ((edge.takesSource ? [source] : []) + (payload.map { [$0] } ?? [])
            + (edge.takesRequest ? ["request: \(request ?? "request")"] : []))
            .joined(separator: ", ")
    }

    /// The statement that compares a completion parameter of `role`, spelled `authored`, with the type
    /// its operation declares for that role.
    func completionWitness(_ role: Schema.CompletionRole, declared: String, authored: String) -> String {
        "\(role.witness)(_TriggerPayloadMatchesDeclaration<\(declared)>(), _TriggerPayloadMatchesDeclaration<\(authored)>())"
    }

    func witnesses() -> String {
        /// The witness that a function's trigger payload parameter takes the trigger's payload.
        ///
        /// An `Input` case's payload is inferred from the value a pattern of the case binds alone, which
        /// has the type `Input` declares, so a name an extension of `Input` declares is read as Swift
        /// reads it. The parameter is then compared with it in a statement of its own where no conversion
        /// can adapt one to the other. The pattern matches an input a local function consumes, which
        /// binds a payload of any kind, a noncopyable one included, and type-checks each witness on its
        /// own.
        ///
        /// A completion's outcome parameter, and its `request:` parameter, are compared with the declared
        /// type through a function whose exact overload takes the same type twice and whose unavailable
        /// one takes any two, with a message that names the parameter's role.
        func payloadWitness(_ trigger: Schema.Trigger, _ payload: String) -> String {
            guard trigger.kind == .input else {
                // The operation's alias names its outcome where the namespace declares it.
                let success = trigger.kind == .success
                return completionWitness(
                    success ? .output : .failure,
                    declared: success ? operation(trigger.name).output : operation(trigger.name).failure,
                    authored: payload
                )
            }
            return
                "do { func witness(_ input: consuming Input) { switch consume input { case .\(trigger.name)(let bound): let payload = _stateMachineInputPayload(bound); let _: _TriggerPayloadMatchesDeclaration<\(payload)> = payload; case _: break } } }"
        }
        // A transition that lists several sources is one authored function, witnessed once.
        var witnessed = Set<Int>()
        let edges = schema.transitions.filter { witnessed.insert($0.declaration).inserted }
            .map { edge in
                let before = phase(edge.from)
                let result: String
                switch edge.shape {
                case .destination: result = phase(edge.to)
                case .change: result = "StateMachine::Change<\(phase(edge.to)), \(authoredEffect(edge))>"
                case .advance:
                    result =
                        "StateMachine::Advance<\(before), \(phase(edge.to)), \(authoredEffect(edge)), \(edge.failureType ?? "Swift::Never")>"
                }
                var lines =
                    edge.sourceType.map {
                        ["let _: _TransitionSourceIsPhasePayload<\(before)> = _TransitionSourceIsPhasePayload<\($0)>()"]
                    } ?? []
                lines.append(
                    "let _: _TransitionReturnsDeclaredResult<\(result)> = _TransitionReturnsDeclaredResult<\(edge.returnType)>()"
                )
                if let payload = edge.payloadType { lines.append(payloadWitness(edge.trigger, payload)) }
                if let request = edge.requestType {
                    lines.append(
                        completionWitness(.request, declared: operation(edge.trigger.name).request, authored: request)
                    )
                }
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n")
        // A failure a router pins must be an error, as an operation's declared failure must, and every
        // function of its group that throws must throw it regardless of which owners and methods the
        // expansion generates, because a typed throw converts only to its own type.
        // A key is hashed and compared outside every lock, and crosses into the runtime's key table.
        let pinnedWitnesses = schema.routes.compactMap { route -> String? in
            guard let pinned = route.pinnedFailure else { return nil }
            let members = throwers(route).map { "let _ = { (failure: \($0.type)) throws(\(pinned)) in throw failure }" }
            return (["let _ = _OperationFailureIsError<\(pinned)>()"] + members).joined(separator: "\n")
        }
        let operationWitnesses =
            (schema.operations.filter(\.declaresFailure)
            .map { "let _ = _OperationFailureIsError<\($0.name).Failure>()" }
            + pinnedWitnesses
            + schema.operations.filter(\.isKeyed).map { "let _ = _OperationKeyIsHashable<\($0.key)>()" })
            .joined(separator: "\n")
        let routeWitnesses = schema.routes
            .map { route in
                var lines = [
                    "let _: _RouterSourceIsPhasePayload<\(phase(route.from))> = _RouterSourceIsPhasePayload<\(route.sourceType)>()"
                ]
                if let payload = route.payloadType { lines.append(payloadWitness(route.trigger, payload)) }
                if let request = route.requestType {
                    lines.append(
                        completionWitness(.request, declared: operation(route.trigger.name).request, authored: request)
                    )
                }
                return lines.joined(separator: "\n")
            }
            .joined(separator: "\n")
        var plan = schema.checkPlan
        // A type read as the standard library's `Void` or `Never` through a reading the macro cannot
        // confirm is checked with an exact overload that accepts the standard library's type and an
        // unavailable generic overload that rejects any other with a message.
        let standardWitnesses = plan.standards
            .map { standard, message, function in
                let message =
                    message
                    ?? "The macro reads this type as the standard library's \(standard), but it resolves to a different type; spell that type with its module name, or write Swift::\(standard)."
                return """
                    fileprivate static func \(function)(_ type: Swift::\(standard).Type) {}
                    @available(*, unavailable, message: \(literal(message)))
                    fileprivate static func \(function)<Value: ~Swift::Copyable>(_ type: Value.Type) {}
                    """
            }
            .joined(separator: "\n")
        // A type read as one with values through a reading the macro cannot confirm is checked not to be
        // `Never`. The probe's exact overload matches only `Never`, and its result selects the
        // unavailable overload of the second stage, which rejects it with a message. Any other type
        // takes the generic overloads.
        var probeLines: [String] = []
        if plan.probesNever || plan.probesPairs { probeLines.append("fileprivate enum _StateMachineReadsNever {}") }
        if plan.probesNever {
            probeLines.append(
                """
                fileprivate static func _stateMachineNeverProbe<Value: ~Swift::Copyable>(_ type: Value.Type) -> Swift::Bool { true }
                fileprivate static func _stateMachineNeverProbe(_ type: Swift::Never.Type) -> _StateMachineReadsNever.Type { _StateMachineReadsNever.self }
                """
            )
        }
        if plan.probesPairs {
            probeLines.append(
                """
                fileprivate static func _stateMachineNeverPairProbe<First: ~Swift::Copyable, Second: ~Swift::Copyable>(_ first: First.Type, _ second: Second.Type) -> Swift::Bool { true }
                fileprivate static func _stateMachineNeverPairProbe(_ first: Swift::Never.Type, _ second: Swift::Never.Type) -> _StateMachineReadsNever.Type { _StateMachineReadsNever.self }
                """
            )
        }
        if plan.readsCasePayloads {
            probeLines.append(
                "fileprivate static func _stateMachineCasePayload<Value: ~Swift::Copyable>(_ value: borrowing Value) -> Value.Type { Value.self }"
            )
        }
        for (message, function) in plan.stages {
            let message =
                message
                ?? "The macro reads this type as one with values, but it names Never through a declaration the macro cannot read, such as one outside the schema, in an extension, or inherited from a superclass; write Never or Swift::Never in the schema, so the macro reads it as Never."
            probeLines.append(
                """
                fileprivate static func \(function)(_ probe: Swift::Bool) {}
                @available(*, unavailable, message: \(literal(message)))
                fileprivate static func \(function)(_ probe: _StateMachineReadsNever.Type) {}
                """
            )
        }
        // The schema conforms to each standard protocol its inheritance clause names by a name another
        // protocol could take. The constrained overload accepts it, and the unavailable one rejects it.
        for name in plan.conformances {
            let function = Schema.CheckPlan.conformanceWitness(name)
            probeLines.append(
                """
                fileprivate static func \(function)<Value: Swift::\(name)>(_ type: Value.Type) {}
                @available(*, unavailable, message: \(literal("The schema's inheritance clause names \(name), which the macro reads as the standard library's Swift::\(name) that generated effects and restorations repeat, but the schema does not conform to it; write Swift::\(name) in the inheritance clause, or name the protocol through its module.")))
                fileprivate static func \(function)<Value: ~Swift::Copyable>(_ type: Value.Type) {}
                """
            )
        }
        if plan.requiresSendable {
            probeLines.append(
                """
                /// Generated code passes a value of this type to a `sending` parameter while it keeps the value or passes it on again, which only a `Sendable` value allows.
                fileprivate struct _SendingValueIsSendable<Value: Swift::Sendable & ~Swift::Copyable> {}
                """
            )
        }
        // What an `Owned` router's method may give away depends on which types are `Sendable`. Each type
        // is sorted by whether it is, and only an unshared value, or a pair of two, selects the
        // unavailable overload, whose message names the cause and the repairs.
        if plan.sortsSharing {
            probeLines.append(
                """
                fileprivate enum _StateMachineShared {}
                fileprivate enum _StateMachineUnshared {}
                fileprivate static func _stateMachineSharing<Value: Swift::Sendable & ~Swift::Copyable>(_ type: Value.Type) -> _StateMachineShared.Type { _StateMachineShared.self }
                fileprivate static func _stateMachineSharing<Value: ~Swift::Copyable>(_ type: Value.Type) -> _StateMachineUnshared.Type { _StateMachineUnshared.self }
                """
            )
        }
        for reason in plan.routedShares {
            let function = Schema.CheckPlan.sharingWitness(reason)
            let message =
                switch reason {
                case .routerSends:
                    "An Owned router takes this value as sending, which gives it away, and the edge it selects then takes the value too, which is safe only when the value's type is Sendable; take the value without sending in the router, or make its type Sendable."
                case .edgesDiffer:
                    "One edge an Owned router may select takes this value as sending and another takes it without, so the router's method keeps a value it may give away, which is safe only when the value's type is Sendable; take the value the same way in every edge the router may select, or make its type Sendable."
                }
            probeLines.append(
                """
                fileprivate static func \(function)(_ value: _StateMachineShared.Type) {}
                @available(*, unavailable, message: \(literal(message)))
                fileprivate static func \(function)(_ value: _StateMachineUnshared.Type) {}
                """
            )
        }
        for joined in plan.routedJoins {
            let function = Schema.CheckPlan.joinWitness(joined)
            let message =
                switch joined {
                case .source:
                    "An Owned router reads this value with its source phase, which joins the two, and then passes it to an edge it selects that takes it as sending, which is safe only when the value's type or the phase's payload is Sendable; make one of the two types Sendable, take the value without sending in every edge the router may select, or, for the operation's request, leave the request out of the router."
                case .value:
                    "An Owned router reads this value with the other value it passes on, which joins the two, and then passes this one to an edge it selects that takes it as sending while the other is still in use, which is safe only when one of the two types is Sendable; make one of them Sendable, take this value without sending in every edge the router may select, or leave the request out of the router."
                }
            probeLines.append(
                """
                fileprivate static func \(function)(_ other: _StateMachineShared.Type, _ value: _StateMachineShared.Type) {}
                fileprivate static func \(function)(_ other: _StateMachineShared.Type, _ value: _StateMachineUnshared.Type) {}
                fileprivate static func \(function)(_ other: _StateMachineUnshared.Type, _ value: _StateMachineShared.Type) {}
                @available(*, unavailable, message: \(literal(message)))
                fileprivate static func \(function)(_ other: _StateMachineUnshared.Type, _ value: _StateMachineUnshared.Type) {}
                """
            )
        }
        // Each check names its type through a local alias, which resolves a spelling of any form at the
        // schema's scope. The alias takes a name the schema's source never spells.
        let checked = schema.checkedAlias
        let checkLines = schema.typeChecks
            .map { check in
                let alias = "typealias \(checked) = \(check.reference); "
                switch check.kind {
                case .isStandard(let name, let message):
                    return "do { \(alias)\(plan.function(name, message))(\(checked).self) }\n"
                case .isNotNever(let message):
                    return
                        "do { \(alias)let probe = _stateMachineNeverProbe(\(checked).self); \(plan.stage(message))(probe) }\n"
                case .casePayloadIsNotNever(let message):
                    return
                        "do { func witness(_ input: consuming Input) { switch consume input { case .\(check.reference)(let bound): let probe = _stateMachineNeverProbe(_stateMachineCasePayload(bound)); \(plan.stage(message))(probe); case _: break } } }\n"
                case .finishes(let message):
                    // An omitted alias is never named and defaults to `Void` or `Never`.
                    let operation = schema.tables.operationsByName[check.reference]
                    let output = operation?.output ?? "Swift::Void"
                    let failure = operation?.failure ?? "Swift::Never"
                    return
                        "do { let probe = _stateMachineNeverPairProbe(\(output).self, \(failure).self); \(plan.stage(message))(probe) }\n"
                case .conformsToStandard(let name):
                    return "\(Schema.CheckPlan.conformanceWitness(name))(Self.self)\n"
                case .isSendable:
                    return "do { \(alias)let _ = _SendingValueIsSendable<\(checked)>() }\n"
                case .sharedAfterRouter(let reason):
                    // The type is sorted in a statement of its own, so the witness's overloads cannot
                    // decide which sorting overload applies.
                    return
                        "do { \(alias)let value = _stateMachineSharing(\(checked).self); \(Schema.CheckPlan.sharingWitness(reason))(value) }\n"
                case .transfersAfterRouter(let other, let joined):
                    // The other value is named through an alias of its own, which resolves any spelling.
                    return
                        "do { \(alias)typealias \(checked)Other = \(other); let other = _stateMachineSharing(\(checked)Other.self); let value = _stateMachineSharing(\(checked).self); \(Schema.CheckPlan.joinWitness(joined))(other, value) }\n"
                }
            }
            .joined()
        let inputPayloads =
            schema.witnessesInputPayloads
            ? "fileprivate static func _stateMachineInputPayload<Value: ~Swift::Copyable>(_ value: borrowing Value) -> _TriggerPayloadMatchesDeclaration<Value> { _TriggerPayloadMatchesDeclaration<Value>() }"
            : ""
        // A generic struct converts to no other specialization, so the exact overload applies only when
        // the parameter's type is the declared one.
        let completionParameters = schema.completionRoles
            .map { role in
                """
                fileprivate static func \(role.witness)<Value: ~Swift::Copyable>(_ declared: _TriggerPayloadMatchesDeclaration<Value>, _ authored: _TriggerPayloadMatchesDeclaration<Value>) {}
                @available(*, unavailable, message: \(literal(role.message)))
                fileprivate static func \(role.witness)<Declared: ~Swift::Copyable, Authored: ~Swift::Copyable>(_ declared: _TriggerPayloadMatchesDeclaration<Declared>, _ authored: _TriggerPayloadMatchesDeclaration<Authored>) {}
                """
            }
            .joined(separator: "\n")
        // An `Owned` router that takes as its own a payload its method still passes on gets an implicit
        // copy, which only a copyable payload has. The check names the type rather than passing the value,
        // which a closure would have to give up to reach a generic parameter.
        let copies =
            schema.generates(.owned) && schema.routes.contains(where: schema.requiresCopyableRoutedPayload)
            ? """
            fileprivate static func _stateMachineCopy<Value>(_ payload: _TriggerPayloadMatchesDeclaration<Value>) {}
            @available(*, unavailable, message: \(literal("This router takes its payload as its own, consuming, __owned, or sending, but the edge it selects takes the payload after it, and a noncopyable payload cannot be both given away and passed on; take the payload borrowing in the router.")))
            fileprivate static func _stateMachineCopy<Value: ~Swift::Copyable>(_ payload: _TriggerPayloadMatchesDeclaration<Value>) {}
            """ : ""
        // Generated code names the schema by its name, so its name must name a type at its own scope, where
        // an extension could declare a member of that name. The check names it through the alias that
        // spells it in type position, where a value of that name, such as a static property, is no candidate.
        let schemaName = """
            fileprivate static func _stateMachineNamesSchema(_ type: Self.Type) {}
            @available(*, unavailable, message: \(literal("'\(name)' names another type inside the schema, where an extension declares a member of that name; rename that member, because generated code names the schema '\(name)'.")))
            fileprivate static func _stateMachineNamesSchema<Value: ~Swift::Copyable>(_ type: Value.Type) {}
            """
        return """
            fileprivate struct _TransitionSourceIsPhasePayload<Value: ~Swift::Copyable> {}
            fileprivate struct _TransitionReturnsDeclaredResult<Value: ~Swift::Copyable> {}
            fileprivate struct _TriggerPayloadMatchesDeclaration<Value: ~Swift::Copyable> {}
            fileprivate struct _RouterSourceIsPhasePayload<Value: ~Swift::Copyable> {}
            fileprivate struct _SharedModeRequiresSendable<Value: Swift::Sendable & ~Swift::Copyable> {}
            fileprivate struct _OperationFailureIsError<Value: Swift::Error> {}
            fileprivate struct _OperationKeyIsHashable<Value: Swift::Hashable & Swift::Sendable> {}
            fileprivate struct _EffectIsCopyable<Value> {}
            /// The schema type, used by generated code where a local value could shadow its name.
            \(access)typealias _StateMachineSchema = \(name)
            fileprivate typealias _StateMachineScopeID = StateMachine::RuntimeScopeID
            fileprivate typealias _StateMachineOperation = StateMachine::RuntimeOperation
            fileprivate typealias _StateMachineKey = StateMachine::RuntimeKey
            \(schemaName)
            \(inputPayloads)
            \(completionParameters)
            \(copies)
            \(standardWitnesses)
            \(probeLines.joined(separator: "\n"))
            fileprivate static func _stateMachineWitnesses() {
                _stateMachineNamesSchema(_StateMachineSchema.self)
                \(checkLines)\(edges)
                \(operationWitnesses)
                \(routeWitnesses)
                let _ = _EffectIsCopyable<Effect>()
                \(schema.mode == .shared ? "let _ = _SharedModeRequiresSendable<Input>(); let _ = _SharedModeRequiresSendable<Effect>()" : "")
            }
            """
    }

    /// The kind of sequence an owner's observation returns, which decides what cancelling it does.
    enum SequenceKind {
        /// A `SnapshotSequence`, which any isolation domain can cancel.
        case transferable
        /// A `MainActorSnapshotSequence`, confined to the main actor.
        case mainActorStream
        /// An `IsolatedSnapshotSequence`, confined to the actor that owns the host.
        case isolatedStream
    }

    /// What a sequence of this kind is called, the cancellation a consumer that keeps it after it stops
    /// reading calls, and the two lines that finish saying what that call does, as generated
    /// documentation spells them.
    func sequenceTerms(_ kind: SequenceKind) -> (sequence: String, cancel: String, ending: (String, String)) {
        switch kind {
        case .transferable:
            (
                "single-pass sequence", "cancel()",
                (
                    "calls `cancel()` from any isolation domain, which frees its subscriber slot before it",
                    "returns. A read that already received an element still returns it."
                )
            )
        case .mainActorStream:
            (
                "single-consumer stream", "cancel()",
                ("calls `cancel()` on the main actor, which removes its registration before it", "returns.")
            )
        case .isolatedStream:
            (
                "single-consumer stream, read with `next()` on the owning actor,", "cancel(isolation:)",
                ("calls `cancel(isolation:)` on the owning actor, which removes its registration", "before it returns.")
            )
        }
    }

    /// A string literal of `text`, escaped.
    func literal(_ text: String) -> String { StringLiteralExprSyntax(content: text).description }

    /// The conformance clause of a generated value type, combining the mode's `Sendable` requirement with
    /// each value conformance the schema lists.
    func conformances(_ base: [String]) -> String {
        let all = base + schema.valueConformances.map { "Swift::\($0)" }
        return all.isEmpty ? "" : ": " + all.joined(separator: ", ")
    }

    /// The schema-wide effect vocabulary and one narrowed vocabulary per edge that starts work.
    ///
    /// Every edge's vocabulary is named `Effect.<Phase>.<Edge>` for each of its source phases. When every
    /// edge of a name starts the same operations, they share one type, also named `Effect.<Edge>`.
    func effects() -> String {
        let base: [String]
        switch schema.mode {
        case .shared: base = ["Swift::Sendable"]
        case .isolated: base = ["~Swift::Sendable"]
        case .ownedOnly: base = []
        }
        let conformance = conformances(base)
        // Names are schema-qualified because a per-edge type such as `Effect.Save` would otherwise
        // shadow an operation namespace of the same name.
        func cases(
            _ operations: [Schema.Operation],
            cancelling cancelled: [Schema.Operation] = [],
            _ events: [Schema.Event] = []
        ) -> String {
            let starts = operations.map { op in
                switch (op.isKeyed, op.takesInput) {
                case (true, true): "case \(op.effect)(key: \(name).\(op.key), input: \(name).\(op.name).Input)"
                case (true, false): "case \(op.effect)(key: \(name).\(op.key))"
                case (false, true): "case \(op.effect)(\(name).\(op.name).Input)"
                case (false, false): "case \(op.effect)"
                }
            }
            let cancellations = cancelled.flatMap { op in
                [
                    "/// Cancels the active `\(op.name)` work for one key. Cancelling a key with no active work does nothing.",
                    "case \(op.cancelEffect)(key: \(name).\(op.key))",
                    "/// Cancels all active `\(op.name)` work.",
                    "case \(op.cancelAllEffect)",
                ]
            }
            let emissions = events.map {
                $0.takesPayload ? "case \($0.effect)(\(name).\($0.name).Payload)" : "case \($0.effect)"
            }
            return (starts + cancellations + emissions).joined(separator: "\n")
        }
        func vocabulary(_ edge: Schema.Transition) -> String {
            let started = edge.starts.map(operation)
            let cancelled = edge.cancels.map(operation)
            let emitted = edge.emits.map(event)
            let lowering =
                (started.map { op -> (String, [String]) in
                    (op.effect, (op.isKeyed ? ["key"] : []) + (op.takesInput ? ["input"] : []))
                }
                + cancelled.flatMap { [($0.cancelEffect, ["key"]), ($0.cancelAllEffect, [])] }
                + emitted.map { ($0.effect, $0.takesPayload ? [""] : []) })
                .map { effect, labels in
                    guard !labels.isEmpty else { return "case .\(effect): return .\(effect)" }
                    // An event's payload is unlabeled; every other associated value is labeled.
                    guard labels != [""] else { return "case .\(effect)(let payload): return .\(effect)(payload)" }
                    if labels == ["input"] { return "case .\(effect)(let input): return .\(effect)(input)" }
                    let bindings = labels.map { "let \($0)" }.joined(separator: ", ")
                    let arguments = labels.map { "\($0): \($0)" }.joined(separator: ", ")
                    return "case .\(effect)(\(bindings)): return .\(effect)(\(arguments))"
                }
                .joined(separator: "\n")
            let phrases = [
                started.isEmpty ? nil : ("operations", "start"), cancelled.isEmpty ? nil : ("work", "cancel"),
                emitted.isEmpty ? nil : ("events", "emit"),
            ]
            .compactMap { $0 }
            .enumerated()
            .map { index, phrase in
                index == 0
                    ? "The \(phrase.0) `\(edge.name)` may \(phrase.1)" : "the \(phrase.0) it may \(phrase.1)"
            }
            let summary =
                "/// "
                + (phrases.count < 3
                    ? phrases.joined(separator: " and ")
                    : phrases.dropLast().joined(separator: ", ") + ", and " + (phrases.last ?? "")) + "."
            return """
                \(summary)
                \(access)enum \(edge.effectNamespace ?? Schema.companion(edge.name))\(conformance) {
                    \(cases(started, cancelling: cancelled, emitted))
                    /// The schema-wide effect this value describes.
                    \(access)var effect: \(name).Effect { switch self { \(lowering) } }
                }
                """
        }
        let starting = schema.transitions.filter { $0.effectNamespace != nil }
        var shared = Set<String>()
        let short = starting.filter { schema.sharesEffect($0.name) && shared.insert($0.name).inserted }
            .map(vocabulary)
        let startingBySource = Dictionary(grouping: starting, by: \.from)
        let namespaces = schema.effectPhases
            .map { phase in
                let members = (startingBySource[phase.caseName] ?? [])
                    .map { edge in
                        // A vocabulary lives at its short name when it has one, and otherwise with its first source.
                        guard schema.sharesEffect(edge.name) || edge.sources.first != phase.caseName else {
                            return vocabulary(edge)
                        }
                        return
                            "\(access)typealias \(edge.effectNamespace ?? Schema.companion(edge.name)) = \(name).\(authoredEffect(edge))"
                    }
                return """
                    /// The effect vocabularies of the edges from `\(phase.typeName)`.
                    \(access)enum \(phase.typeName) {
                        \(members.joined(separator: "\n"))
                    }
                    """
            }
        let declaration = """
            /// Inert descriptions of the operations this workflow can start\(hasEvents ? " and the events it can emit" : "").
            \(access)enum Effect\(conformance) {
                \(cases(schema.operations, cancelling: schema.cancelledOperations, schema.events))
                \((short + namespaces).joined(separator: "\n"))
            }
            """
        return declaration
    }

    /// The request type of each operation that has a key or an input, recording what the work started with.
    ///
    /// It is plain data with a public initializer. Admission captures it when it accepts the start, and
    /// the work, its completion, and a retained outcome carry that capture. Constructing one grants no
    /// authority, so an `Owned` caller can pass one to a completion edge that takes it.
    ///
    /// A request that carries an input is the runtime's `OperationRequest`, or `KeyedOperationRequest`
    /// for a keyed operation, specialized at the operation's namespace and `Input`, so it stores an input
    /// of any type, a closure included, without the macro deciding whether the type is a function type,
    /// and it is `Sendable`, `Equatable`, and `Hashable` exactly when its input is, which the compiler
    /// checks. A request that carries only a key is a struct of its own, `Hashable` and `Sendable` as
    /// every key is.
    func requests() -> String {
        schema.operations.filter(\.hasRequest)
            .map { op in
                let documentation = "/// What one `\(op.name)` execution was started with, as admission accepted it."
                guard op.takesInput else {
                    return """
                        \(documentation)
                        \(access)struct \(op.request): Swift::Hashable, Swift::Sendable {
                            /// The key the work was started for.
                            \(access)let key: \(op.key)
                            /// Creates a request value. Requests are plain data and grant no authority.
                            \(access)init(key: \(op.key)) {
                                self.key = key
                            }
                        }
                        """
                }
                let storage =
                    op.isKeyed
                    ? "StateMachine::KeyedOperationRequest<\(op.name), \(op.key), \(op.name).Input>"
                    : "StateMachine::OperationRequest<\(op.name), \(op.name).Input>"
                return """
                    \(documentation)
                    \(access)typealias \(op.request) = \(storage)
                    """
            }
            .joined(separator: "\n")
    }

    /// The schema's declared structure as a `StateMachineGraph` constant.
    ///
    /// Every element is constructed through its explicitly named type, so the literal type-checks in
    /// time proportional to its size. The constant's own initializer is an implicit member, because a
    /// module interface would otherwise spell its type with the file-private alias.
    func graph() -> String {
        // Every string the graph holds is escaped, so authored text, even text that spans lines, stays
        // one literal.
        func list(_ values: [String]) -> String { "[" + values.map(literal).joined(separator: ", ") + "]" }
        func optional(_ value: String?) -> String { value.map(literal) ?? "nil" }
        // The parser keeps each spelling the graph shows on one line, as the author wrote it.
        func type(_ spelling: String) -> String { literal(spelling) }
        func trigger(_ trigger: Schema.Trigger) -> String {
            switch trigger.kind {
            case .input: ".input(\(literal(trigger.name)))"
            case .success: ".success(\(literal(operation(trigger.name).name)))"
            case .failure: ".failure(\(literal(operation(trigger.name).name)))"
            case .direct: ".direct"
            }
        }
        // Each element is appended in its own statement because one literal holding every element is
        // type-checked as one expression, at a cost that grows faster than its length.
        var builders: [String] = []
        func elements(_ name: String, _ type: String, _ values: [String]) -> String {
            guard !values.isEmpty else { return "[]" }
            builders.append(
                "var \(name): [_StateMachineGraph.\(type)] = []\n"
                    + values.map { "\(name).append(\($0))" }.joined(separator: "\n")
            )
            return name
        }
        let phases = schema.phases.map {
            "_StateMachineGraph.Phase(id: \(literal($0.caseName)), payload: \(type($0.payloadSpelling)))"
        }
        let inputs = schema.inputs.map {
            "_StateMachineGraph.Input(id: \(literal($0.caseName)), payload: \($0.payloadType.map(type) ?? "nil"))"
        }
        let scopes = schema.scopes.map {
            "_StateMachineGraph.Scope(id: \(literal($0)), activeIn: \(list(schema.scopePhases($0))))"
        }
        let operations = schema.operations.map { op in
            let admission: String
            switch op.admission {
            case .latest: admission = ".latest"
            case .rejectWhenActive: admission = ".rejectWhenActive"
            case .parallel(let limit): admission = ".parallel(limit: \(limit))"
            }
            return """
                _StateMachineGraph.Operation(id: \(literal(op.name)), effect: \(literal(op.effect)), scope: \(optional(op.scope)),
                    requires: \(list(op.requires)), activeIn: \(list(op.activeIn)), admission: \(admission),
                    key: \(op.keyType.map(type) ?? "nil"), input: \(type(op.inputType)), output: \(type(op.outputType)),
                    failure: \(type(op.failureType)), canFail: \(!op.isInfallible), canSucceed: \(!op.neverSucceeds))
                """
        }
        let events = schema.events.map {
            "_StateMachineGraph.Event(id: \(literal($0.name)), effect: \(literal($0.effect)), payload: \(type($0.payloadType)))"
        }
        let edges = schema.transitions.map { edge in
            let router = router(of: edge).map { "\($0.from).\($0.name)" }
            return """
                _StateMachineGraph.Edge(id: \(literal("\(edge.from).\(edge.name)")), name: \(literal(edge.name)),
                    source: \(literal(edge.from)), destination: \(literal(edge.to)), trigger: \(trigger(edge.trigger)),
                    router: \(optional(router)), starts: \(list(edge.starts.map { operation($0).name })),
                    cancels: \(list(edge.cancels.map { operation($0).name })),
                    emits: \(list(edge.emits.map { event($0).name })), invalidates: \(list(edge.invalidates)))
                """
        }
        let routers = schema.routes.map { route in
            """
            _StateMachineGraph.Router(id: \(literal("\(route.from).\(route.name)")), name: \(literal(route.name)),
                source: \(literal(route.from)), trigger: \(trigger(route.trigger)),
                candidates: \(list(route.choices.map { "\(route.from).\($0)" })))
            """
        }
        let arguments = [
            "phases: \(elements("phases", "Phase", phases))",
            "inputs: \(elements("inputs", "Input", inputs))",
            "scopes: \(elements("scopes", "Scope", scopes))",
            "operations: \(elements("operations", "Operation", operations))",
            "events: \(elements("events", "Event", events))",
            "edges: \(elements("edges", "Edge", edges))",
            "routers: \(elements("routers", "Router", routers))",
        ]
        return """
            fileprivate typealias _StateMachineGraph = StateMachine::StateMachineGraph
            /// The declared phases, inputs, scopes, operations, events, edges, and routers of this graph,
            /// without payloads or authority.
            \(access)nonisolated static let graph: StateMachine::StateMachineGraph = _stateMachineGraph()
            nonisolated private static func _stateMachineGraph() -> StateMachine::StateMachineGraph {
                \(builders.joined(separator: "\n"))
                return .init(
                    name: \(literal(name)),
                    mode: .\(schema.mode.rawValue),
                    owners: [\(Schema.Owner.allCases.filter(schema.generates).map { ".\($0.rawValue)" }.joined(separator: ", "))],
                    initial: \(literal(schema.initial)),
                    terminal: \(list(schema.phases.filter(\.isTerminal).map(\.caseName))),
                    restorable: \(list(schema.restorationEntrances)),
                    \(arguments.joined(separator: ",\n"))
                )
            }
            """
    }

    /// The router that selects among the edges sharing this edge's source phase and trigger, if any.
    func router(of edge: Schema.Transition) -> Schema.Route? { schema.router(of: edge) }

    /// The access of an edge's own `Owned` or `Observed` method.
    ///
    /// A routed edge is reached only through its router's method, so a typed call obeys the router. An
    /// observation's completion edge is reached only through delivery, so the first retained outcome is
    /// the only one that can commit. An unrouted `Owned` completion edge stays callable because `Owned`
    /// holds no work authority and retains no outcome, making it the caller's only way to finish its
    /// own typestate.
    func edgeAccess(_ edge: Schema.Transition, observed: Bool) -> String {
        schema.hasOwnMethod(edge, observed: observed) ? access : "fileprivate "
    }

    /// The input routers with candidate edges that become `Observed` methods.
    var inputRouters: [Schema.Route] { schema.routes.filter { schema.hasMethod($0, observed: true) } }

    /// The routers with candidate edges, for an input or a completion, that become `Owned` methods.
    var ownedRouters: [Schema.Route] { schema.routes.filter { schema.hasMethod($0, observed: false) } }

    /// A router's candidate edges in declaration order.
    func branches(_ route: Schema.Route) -> [Schema.Transition] { schema.branches(route) }

    /// The passing convention of a routed method's payload parameter, combining every convention that the
    /// router or an edge it may choose declares so the method can pass the payload on to each of them.
    func routedConvention(_ route: Schema.Route) -> String {
        let declared = ([route.payloadConvention] + branches(route).map(\.payloadConvention)).joined()
        return ["sending", "@escaping"].filter { declared.contains($0 + " ") }.map { $0 + " " }.joined()
    }

    /// The statement with which an `Owned` routed method checks its payload is copyable, as
    /// ``Schema/requiresCopyableRoutedPayload(_:)`` decides, or empty.
    func routedCopyCheck(_ route: Schema.Route) -> String {
        guard schema.requiresCopyableRoutedPayload(route), let payload = route.payloadType else { return "" }
        return
            "\(schemaReference)._stateMachineCopy(\(schemaReference)._TriggerPayloadMatchesDeclaration<\(payload)>())\n"
    }

    /// The passing convention of a routed method's request parameter, combining every convention that the
    /// router or an edge it may choose declares for its request.
    func routedRequestConvention(_ route: Schema.Route) -> String {
        let declared = ([route.requestConvention] + branches(route).map(\.requestConvention)).joined()
        return ["sending"].filter { declared.contains($0 + " ") }.map { $0 + " " }.joined()
    }

    /// The functions of a routed group that can throw, as (function name, failure type) pairs.
    func throwers(_ route: Schema.Route) -> [(name: String, type: String)] {
        (route.failureType.map { [(route.name, $0)] } ?? [])
            + branches(route).compactMap { edge in edge.failureType.map { (edge.name, $0) } }
    }

    /// The failure type of a router's `Observed` method, or `nil` when no function of its group throws.
    ///
    /// It is the failure the router pins with `failure:`, which the compiler checks every throwing function
    /// of the group against. Without one, it is the type every throwing function of the group shares,
    /// however many of them throw, and `PreparationRejection`, whose cases are named for each throwing
    /// function, when their types differ.
    func routedFailure(_ route: Schema.Route) -> String? {
        if let pinned = route.pinnedFailure { return pinned }
        let types = throwers(route).map(\.type)
        guard let first = types.first else { return nil }
        let key = schema.failureKey(first)
        return types.allSatisfy { schema.failureKey($0) == key } ? first : "PreparationRejection"
    }

    /// Whether a router's `Observed` method wraps each function's failure in `PreparationRejection`.
    func routedFailureWraps(_ route: Schema.Route) -> Bool { routedFailure(route) == "PreparationRejection" }

    /// The typed throws clause of a router's `Observed` method.
    func routedThrows(_ route: Schema.Route) -> String { routedFailure(route).map { " throws(\($0))" } ?? "" }

    /// What an edge's `Owned` method returns, with its own source spelled `source`.
    func ownedResult(_ edge: Schema.Transition, source: String) -> String { schema.ownedResult(edge, source: source) }

    /// The type a router's `Owned` method returns.
    ///
    /// When the router cannot throw and every candidate edge returns the same type, it returns that type
    /// directly. Otherwise it returns `Route.<Router>Result`, which has one case per candidate edge and,
    /// when the router can throw, a `rejected` case that returns the source.
    func ownedRoutedResult(_ route: Schema.Route) -> String {
        guard !schema.needsOwnedResult(route), let first = branches(route).first else {
            return schema.resultType(route)
        }
        return ownedResult(first, source: "Self")
    }

    /// The `<Router>Result` declaration of a router whose `Owned` method needs one.
    ///
    /// The `Route` namespace's phase namespaces shadow the phase payload types, so it spells the schema's
    /// own types from the schema's name.
    func ownedRoutedResultDeclaration(_ route: Schema.Route) -> String {
        let source = "\(name).Owned<\(name).\(phase(route.from))>"
        var cases = branches(route)
            .map { "case \($0.name)(\(schema.ownedResult($0, source: source, qualified: true)))" }
        if route.failureType != nil, let failure = schema.routerFailure(route) {
            cases.append(
                "/// The router declined and returned the source unchanged.\ncase rejected(\(schema.qualify(failure)), \(source))"
            )
        }
        return """
            /// The result of calling `\(route.name)` on an owned `\(phase(route.from))`, with one case per edge it may select.
            \(access)enum \(route.namespace ?? Schema.companion(route.name))Result: ~Swift::Copyable\(schema.mode == .shared ? ", Swift::Sendable" : "") {
                \(cases.joined(separator: "\n"))
            }
            """
    }

    /// The choice type of a router, with one payload-free case per candidate edge.
    func choiceDeclaration(_ route: Schema.Route) -> String {
        let cases = route.choices.map { "case \($0)" }.joined(separator: "\n")
        return """
            /// The edges `\(route.name)` may choose.
            \(access)enum \(route.namespace ?? Schema.companion(route.name)): Swift::Sendable, Swift::Equatable, Swift::Hashable, Swift::CaseIterable { \(cases) }
            """
    }

    /// The `Route` namespace, placing each router's choice type and owned result under `Route.<Phase>`
    /// and under `Route.<Router>` when that name is unambiguous.
    func routeNamespace() -> String {
        var short: [String] = []
        var emitted = Set<String>()
        for route in schema.choosingRouters {
            if schema.sharesChoice(route.name), emitted.insert(route.name).inserted {
                short.append(choiceDeclaration(route))
            }
            if schema.generates(.owned), schema.needsOwnedResult(route), schema.ownsResultName(route.name) {
                short.append(ownedRoutedResultDeclaration(route))
            }
        }
        let namespaces = schema.routePhases
            .map { phase in
                let members = schema.choosingRouters(from: phase.caseName)
                    .flatMap { route -> [String] in
                        let namespace = route.namespace ?? Schema.companion(route.name)
                        var members = [
                            schema.sharesChoice(route.name)
                                ? "\(access)typealias \(namespace) = \(name).Route.\(namespace)"
                                : choiceDeclaration(route)
                        ]
                        if schema.generates(.owned), schema.needsOwnedResult(route) {
                            members.append(
                                schema.ownsResultName(route.name)
                                    ? "\(access)typealias \(namespace)Result = \(name).Route.\(namespace)Result"
                                    : ownedRoutedResultDeclaration(route)
                            )
                        }
                        return members
                    }
                return """
                    /// The choice and owned result types of the routers from `\(phase.typeName)`.
                    \(access)enum \(phase.typeName) {
                        \(members.joined(separator: "\n"))
                    }
                    """
            }
        let declarations = short + namespaces
        guard !declarations.isEmpty else { return "" }
        let declaration = """
            /// The edges each router may choose among.
            \(access)enum Route {
                \(declarations.joined(separator: "\n"))
            }
            """
        return declaration
    }

    /// The `PreparationRejection` case of a function, named for it or, when functions of its name throw
    /// different types, for its source phase and name.
    func rejectionCase(_ name: String, from: String) -> String {
        schema.workCounter.work.rejectionCases += 1
        return Schema.rejectionCase(name, from: from, distinguished: distinguishedRejections)
    }

    /// The `Owned` method that runs a router and then advances through the edge it selects.
    func ownedRoutedMethod(_ route: Schema.Route) -> String {
        // The method takes a completion's request when the router or any edge it may choose needs it.
        let request =
            route.takesRequest || branches(route).contains(where: \.takesRequest)
            ? "request: \(routedRequestConvention(route))\(operation(route.trigger.name).request)" : nil
        // A success without output has no payload parameter, as `succeeded()` seals such a result.
        let takesPayload = route.payloadType != nil
        let parameter = [
            route.payloadType.map { "_ input: \(schema.routedOwnership(route))\(routedConvention(route))\($0)" },
            request,
        ]
        .compactMap { $0 }.joined(separator: ", ")
        let payloadArgument = takesPayload ? ", input" : ""
        let argument = payloadArgument + (route.takesRequest ? ", request: request" : "")
        let result = ownedRoutedResult(route)
        let wraps = schema.needsOwnedResult(route)
        let call = "\(authored(route.deprecation)).\(route.name)(phase\(argument))"
        let choice = schema.choiceType(route) ?? "Route.\(Schema.companion(route.name))"
        let selection =
            route.failureType == nil
            ? "let selection: \(choice) = \(call)"
            : "let selection: \(choice)\ndo { selection = try \(call) } catch { return .rejected(error, self) }"
        let cases = branches(route)
            .map { edge in
                let choice = edge.name
                let branchArgument =
                    ((takesPayload ? ["input"] : [])
                    + (edge.takesRequest ? ["request: request"] : []))
                    .joined(separator: ", ")
                // The method's own parameters may share an edge's name, so the edge is called through `self`.
                return wraps
                    ? "case .\(choice): return .\(choice)(self.\(choice)(\(branchArgument)))"
                    : "case .\(choice): return self.\(choice)(\(branchArgument))"
            }
            .joined(separator: "\n")
        return """
            /// Runs the router `\(route.name)`, then advances through the edge it selects.
            \(deprecated(route.deprecation))\(access)consuming func \(route.name)(\(parameter)) -> \(result) where Phase == \(phase(route.from)) {
                \(routedCopyCheck(route))\(selection)
                switch selection { \(cases) }
            }
            """
    }

    /// The `Observed` method that runs a router and then prepares the edge it selects.
    func observedRoutedMethod(_ route: Schema.Route) -> String {
        let parameter = route.payloadType.map { "_ input: \(routedConvention(route))\($0)" } ?? ""
        let argument = route.payloadType == nil ? "" : ", input"
        let branchArgument = route.payloadType == nil ? "" : "input"
        let wraps = routedFailureWraps(route)
        let call = "\(authored(route.deprecation)).\(route.name)(payload\(argument))"
        let choice = schema.choiceType(route) ?? "Route.\(Schema.companion(route.name))"
        let selection: String
        switch (route.failureType != nil, wraps) {
        case (false, _): selection = "let selection: \(choice) = \(call)"
        case (true, false): selection = "let selection: \(choice) = try \(call)"
        case (true, true):
            selection =
                "let selection: \(choice)\ndo { selection = try \(call) } catch { throw .\(rejectionCase(route.name, from: route.from))(error) }"
        }
        let cases = branches(route)
            .map { edge in
                // The method's own parameter may share an edge's name, so the edge is called through `self`.
                let branch = "self.\(edge.name)(\(branchArgument))"
                switch (edge.failureType != nil, wraps) {
                case (false, _): return "case .\(edge.name): return \(branch)"
                case (true, false): return "case .\(edge.name): return try \(branch)"
                case (true, true):
                    return
                        "case .\(edge.name): do { return try \(branch) } catch { throw .\(rejectionCase(edge.name, from: edge.from))(error) }"
                }
            }
            .joined(separator: "\n")
        return """
            /// Runs the router `\(route.name)`, then prepares the edge it selects.
            \(deprecated(route.deprecation))\(access)func \(route.name)(\(parameter))\(routedThrows(route)) -> Prepared where Phase == \(phase(route.from)) {
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
                // A routed edge's method is the router's to call, so only an edge's own public method is deprecated.
                let marked = visibility == "fileprivate " ? "" : deprecated(edge.deprecation)
                // The method passes the payload on once, so it repeats the authored ownership, which a
                // noncopyable payload needs.
                let payload = [
                    edge.payloadType.map { "_ input: \(edge.payloadOwnership)\(edge.payloadConvention)\($0)" },
                    edge.takesRequest
                        ? "request: \(edge.requestConvention)\(operation(edge.trigger.name).request)" : nil,
                ]
                .compactMap { $0 }.joined(separator: ", ")
                let arguments = authoredArguments(
                    edge,
                    source: "phase",
                    payload: edge.payloadType == nil ? nil : "input"
                )
                let call = "\(authored(edge.deprecation)).\(edge.name)(\(arguments))"
                // The edge's own effect type, so a caller switches over only what this edge can start.
                let result = ownedResult(edge, source: "Self")
                switch edge.shape {
                case .advance:
                    return """
                        /// Consumes the predecessor and preserves it on authored rejection.
                        \(marked)\(visibility)consuming func \(edge.name)(\(payload)) -> \(result) where Phase == \(before) {
                            switch \(call) {
                            case .advanced(let next, let effects): return .advanced(Owned<\(after)>(next), effects: effects)
                            case .rejected(let failure, let original): return .rejected(failure, Owned<\(before)>(original))
                            }
                        }
                        """
                case .change where edge.failureType != nil:
                    return """
                        /// Advances through the authored edge or returns the original predecessor.
                        \(marked)\(visibility)consuming func \(edge.name)(\(payload)) -> \(result) where Phase == \(before) {
                            do {
                                let change = try \(call)
                                return .advanced(Owned<\(after)>(change.next), effects: change.effects)
                            } catch { return .rejected(error, self) }
                        }
                        """
                case .change:
                    return """
                        /// Advances through the authored edge, preserving effect order.
                        \(marked)\(visibility)consuming func \(edge.name)(\(payload)) -> \(result) where Phase == \(before) {
                            let change = \(call)
                            return .init(Owned<\(after)>(change.next), effects: change.effects)
                        }
                        """
                case .destination where edge.failureType != nil:
                    return """
                        /// Advances through the authored edge or returns the original predecessor.
                        \(marked)\(visibility)consuming func \(edge.name)(\(payload)) -> \(result) where Phase == \(before) {
                            do { return .advanced(Owned<\(after)>(try \(call)), effects: []) } catch { return .rejected(error, self) }
                        }
                        """
                case .destination:
                    return """
                        /// Advances through the authored edge, which starts no operation.
                        \(marked)\(visibility)consuming func \(edge.name)(\(payload)) -> \(result) where Phase == \(before) {
                            Owned<\(after)>(\(call))
                        }
                        """
                }
            }
            .joined(separator: "\n")
        let routed = ownedRouters.map(ownedRoutedMethod).joined(separator: "\n")
        return """
            /// Unique authority over one declared workflow phase.
            \(access)struct Owned<Phase: ~Swift::Copyable\(schema.mode == .shared ? " & Swift::Sendable" : "")>: ~Swift::Copyable\(schema.mode == .shared ? ", Swift::Sendable" : "") {
                fileprivate let phase: Phase
                fileprivate init(_ phase: consuming Phase) { self.phase = phase }
                /// Borrows the payload without copying a unique resource, returning what `body` returns or throws.
                \(access)borrowing func withValue<Result: ~Swift::Copyable, Failure: Swift::Error>(
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
        let bound = schema.mode == .shared ? ": Swift::Sendable" : ""
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
        // Functions of one name that throw one type share a case.
        var rejectionCases = Set<String>()
        let edgeFailures = schema.throwingFunctions
            .compactMap { function -> String? in
                let rejection = rejectionCase(function.name, from: function.from)
                guard rejectionCases.insert(rejection).inserted else { return nil }
                return "case \(rejection)(\(function.failure))"
            }
            .joined(separator: "\n")
        let methods = (schema.transitions.map(observedMethod) + inputRouters.map(observedRoutedMethod))
            .joined(separator: "\n")
        // The runtime's short type names are module-qualified, so a client's own `Subscription`, such as
        // Combine's, cannot capture them. The rest of the expansion names them through these aliases.
        let policies =
            hasOperations
            ? """
            /// The disposition of a retained completion.
            \(access)typealias PendingStatus = StateMachine::PendingStatus
            """ : ""
        // Each alias exists only for the owners that name it.
        var aliases: [String] = []
        if schema.generatesManagedOwner {
            aliases.append(
                "/// Validated bounds for managed admission and serial subscriptions.\n\(access)typealias Configuration = StateMachine::ManagedConfiguration"
            )
        }
        if schema.generates(.local) {
            aliases.append(
                "/// Admission bounds for a manual local owner, with no subscriptions or runner policy.\n\(access)typealias LocalConfiguration = StateMachine::Limits"
            )
        }
        if schema.generates(.shared) || schema.generates(.actorHost) {
            aliases.append(
                "/// A live observation registration. Cancelling or releasing it stops delivery.\n\(access)typealias Subscription = StateMachine::SnapshotSubscription"
            )
        }
        if schema.generates(.isolatedHost) {
            aliases.append(
                "/// A live observation registration for an owner confined to `Owner`. Only that actor can cancel and remove it, and releasing it stops delivery.\n\(access)typealias IsolatedSubscription<Owner: Swift::Actor> = StateMachine::IsolatedSnapshotSubscription<Owner>"
            )
        }
        if schema.generates(.mainActorHost) {
            aliases.append(
                "/// A live `MainActor` observation registration. Cancelling or releasing it stops delivery.\n\(access)typealias MainActorSubscription = StateMachine::MainActorSnapshotSubscription"
            )
        }
        if schema.generatesManagedOwner {
            aliases.append(
                "/// Failure to register another live observer.\n\(access)typealias SubscriptionFailure = StateMachine::SubscriptionFailure"
            )
        }
        if schema.mode == .shared && schema.generatesManagedOwner {
            aliases.append(
                "/// A single-pass latest-value sequence of an owner's snapshots.\n\(access)typealias Snapshots = StateMachine::SnapshotSequence<Snapshot>"
            )
        }
        if schema.mode != .shared && schema.generates(.mainActorHost) {
            aliases.append(
                "/// A single-consumer latest-value stream of a `MainActor` owner's snapshots.\n\(access)typealias MainActorSnapshots = StateMachine::MainActorSnapshotSequence<Snapshot>"
            )
        }
        if schema.mode != .shared && schema.generates(.isolatedHost) {
            aliases.append(
                "/// A single-consumer latest-value stream of the snapshots of an owner confined to one actor.\n\(access)typealias IsolatedSnapshots = StateMachine::IsolatedSnapshotSequence<Snapshot>"
            )
        }
        return """
            fileprivate typealias _StateMachineEngine = \(engine)
            \(aliases.joined(separator: "\n"))
            \(policies)
            /// Why an owner refused a prepared candidate, in precedence order.
            \(access)typealias CommitRejection = StateMachine::CommitRejection
            /// An immutable historical payload with sealed complete-root provenance.
            \(access)struct Observed<Phase\(bound)>: \(schema.mode == .shared ? "Swift::Sendable, " : "")Swift::CustomStringConvertible {
                fileprivate let payload: Phase
                fileprivate let record: _StateMachineEngine.Snapshot
                fileprivate let claim: StateMachine::RuntimeDeliveryClaim?
                /// The copied historical payload.
                \(access)var value: Phase { payload }
                /// The owner-lifetime accepted revision.
                \(access)var revision: Swift::UInt64 { record.revision }
                /// The phase, revision, and closure of this observation, without its payload.
                \(access)var description: Swift::String { "\\(Phase.self), revision \\(record.revision)\\(record.isClosed ? ", closed" : "")" }
                \(methods)
            }
            /// A complete historical root observation with sealed provenance.
            \(access)enum Snapshot: \(schema.mode == .shared ? "Swift::Sendable, " : "")StateMachine::StateMachineSnapshot, Swift::CustomStringConvertible {
                \(cases)
                fileprivate var record: _StateMachineEngine.Snapshot { switch self { \(recordCases) } }
                /// The accepted revision of this observation.
                \(access)var revision: Swift::UInt64 { record.revision }
                /// Whether this historical root records closure.
                \(access)var isClosed: Swift::Bool { record.isClosed }
                /// The ordinary model data. Constructing a model value directly confers no installation authority.
                \(access)var model: \(name) { record.model }
                /// The phase, revision, and closure of this observation, without its payload.
                \(access)var description: Swift::String { switch self { \(descriptionCases) } }
            }
            fileprivate static func _stateMachineSnapshot(_ record: _StateMachineEngine.Snapshot, claim: StateMachine::RuntimeDeliveryClaim? = nil) -> Snapshot {
                switch record.model { \(observationCases) }
            }
            \(refusingRoute())
            /// A sealed inert candidate consumed by admission.
            ///
            /// A plan defect found while preparing travels inside it with the snapshot it was prepared on,
            /// so admission installs nothing and reports `CommitRejection.plan` unless the snapshot is
            /// another owner's or the owner is closed, which it reports first.
            \(access)struct Prepared: ~Swift::Copyable\(schema.mode == .shared ? ", Swift::Sendable" : "") {
                fileprivate let candidate: _StateMachineEngine.Proposal
                fileprivate init(_ candidate: _StateMachineEngine.Proposal) { self.candidate = candidate }
            }
            /// A closed typed dynamic routing rejection.
            \(access)enum PreparationRejection: Swift::Error {
                /// The input or outcome has no edge from the observed phase.
                case invalidPhase
                \(edgeFailures)
            }
            \(routeNamespace())
            /// A historical receipt for an atomic acceptance.
            \(access)struct Receipt: \(schema.mode == .shared ? "Swift::Sendable, " : "")StateMachine::StateMachineReceipt, Swift::CustomStringConvertible {
                /// The accepted historical observation.
                \(access)let snapshot: Snapshot
                fileprivate init(_ record: _StateMachineEngine.Snapshot) {
                    snapshot = _stateMachineSnapshot(record)
                    edgeID = record.edge
                }
                /// The identifier of the graph edge the acceptance took, as `graph` names it, or `nil` for a
                /// change that takes no edge, such as a reset, closure, or the authority-only commit of
                /// `discardPending(id:)`.
                \(access)let edgeID: Swift::String?
                /// The owner-lifetime accepted revision.
                \(access)var revision: Swift::UInt64 { snapshot.revision }
                /// The accepted phase, revision, and closure, without the payload.
                \(access)var description: Swift::String { snapshot.description }
            }
            /// Why `send` did not admit an input.
            \(access)enum SendRejection: Swift::Error {
                /// Routing or the authored transition declined the input before a candidate existed.
                case preparation(PreparationRejection)
                /// The owner refused the prepared candidate, or its effect plan is defective (`.plan`).
                /// Read `snapshot()` for the current root.
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

    func phase(_ caseName: String) -> String { schema.phaseType(caseName) }
    // The parser resolves every effect that a trigger, `starts:`, `cancels:`, or `emits:` names to a
    // declared operation or event before generation reads it.
    func operation(_ effect: String) -> Schema.Operation { schema.tables.operations[effect]! }
    func event(_ effect: String) -> Schema.Event { schema.tables.events[effect]! }
    func observedMethod(_ edge: Schema.Transition) -> String {
        let before = phase(edge.from)
        let after = phase(edge.to)
        let argument: String
        let parameter: String
        let ticket: String
        let documentation: String
        if edge.trigger.kind == .input {
            parameter = edge.payloadType.map { "_ input: \(edge.payloadConvention)\($0)" } ?? ""
            argument = authoredArguments(edge, source: "payload", payload: edge.payloadType == nil ? nil : "input")
            ticket = "nil"
            documentation =
                router(of: edge).map { "/// Prepares the declared edge that the router `\($0.name)` selects." }
                ?? "/// Prepares the declared edge with phase authority preserved."
        } else {
            let op = operation(edge.trigger.name)
            let value = edge.trigger.kind == .success ? op.output : op.failure
            parameter =
                "_ value: \(edge.payloadConvention)\(value), \(edge.takesRequest ? "request: \(edge.requestConvention)\(op.request), " : "")authority: StateMachine::RuntimeTicket"
            // A success without output passes nothing on.
            argument = authoredArguments(edge, source: "payload", payload: edge.payloadType == nil ? nil : "value")
            ticket = "authority"
            documentation =
                "/// Prepares the completion edge that delivery selects, with operation authority preserved."
        }
        let call = "\(edge.failureType == nil ? "" : "try ")\(authored(edge.deprecation)).\(edge.name)(\(argument))"
        let starts = edge.effectNamespace != nil
        let result = starts ? "change" : "next"
        let resultType = starts ? "StateMachine::Change<\(after), \(authoredEffect(edge))>" : after
        let throwsClause = edge.failureType.map { " throws(\($0))" } ?? ""
        // The public method of a deprecated edge repeats its deprecation and calls the method `prepare` calls.
        let visibility = edgeAccess(edge, observed: true)
        let forwarded =
            observedName(edge) == edge.name
            ? ""
            : """
            \(documentation)
            \(deprecated(edge.deprecation))\(visibility)func \(edge.name)(\(parameter))\(throwsClause) -> Prepared where Phase == \(before) {
                \(edge.failureType == nil ? "" : "try ")\(observedName(edge))(\(edge.payloadType == nil ? "" : "input"))
            }

            """
        return forwarded + """
            \(documentation)
            \(forwarded.isEmpty ? visibility : "fileprivate ")func \(observedName(edge))(\(parameter))\(throwsClause) -> Prepared where Phase == \(before) {
                let \(result): \(resultType) = \(call)
                return _stateMachinePrepare(on: record, next: .\(edge.to)(\(starts ? "change.next" : "next")),
                    effects: \(starts ? "change.effects.map(\\.effect)" : "[]"),
                    from: \(index(edge.from)), to: \(index(edge.to)), invalidates: \(scopeIndices(edge.invalidates)),
                    requiring: \(ticket), claim: claim, edge: \(literal("\(edge.from).\(edge.name)")))
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
    func index(_ phase: String) -> Int { schema.phaseIndex(phase) }
    func scopeIndices(_ scopes: [String]) -> String {
        "[" + scopes.compactMap { schema.scopeIndex($0).map(String.init) }.joined(separator: ", ") + "]"
    }

    /// The sealed completions of each operation and, for a `Local` owner, its work and command batches.
    func operations() -> String {
        let local = schema.generates(.local)
        // Only `Local` hands completions to its caller. A managed owner seals and admits its own, so
        // without `Local` the completion types stay private to the expansion.
        let sealed = local ? access : "fileprivate "
        let declarations = schema.operations
            .map { op in
                let carried = op.hasRequest ? " request: request," : ""
                // A work that can succeed is a generic struct specialized at the operation's `Output`, so its
                // `succeeded(_:)` stores an output of any type, a closure included.
                let succeeds = !op.neverSucceeds
                let output = succeeds ? "_StateMachineOutput" : op.output
                let pinned = succeeds ? " where _StateMachineOutput == \(op.output)" : ""
                let workType = succeeds ? "\(op.workStorage)<_StateMachineOutput>" : op.work
                let work =
                    local
                    ? """
                    \(succeeds ? "/// Work issued exclusively from an accepted command batch.\n\(access)typealias \(op.work) = \(op.workStorage)<\(op.output)>" : "")
                    /// \(succeeds ? "The work of `\(op.name)`, generic over its output so that it seals an output of any type." : "Work issued exclusively from an accepted command batch.")
                    \(access)struct \(workType)\(sendable) {
                        \(op.hasRequest ? "/// What admission started this work with.\n\(access)let request: \(op.request)" : "")
                        \(op.isKeyed ? "/// The key this work was started for.\n\(access)var key: \(op.key) { request.key }" : "")
                        \(op.takesInput ? "/// The immutable declared input.\n\(access)var input: \(op.name).Input { request.input }" : "")
                        fileprivate let authority: StateMachine::RuntimeTicket
                        /// The sealed identity for acknowledging physical execution termination.
                        \(access)var execution: ExecutionHandle { ExecutionHandle(authority: authority) }
                        \(succeeds ? "/// Seals a successful terminal result for this exact work.\n    \(access)func succeeded(_ value: \(output)) -> \(op.name)Completion\(pinned) {\n        \(op.name)Completion(\(op.isInfallible ? "value: value" : "result: .success(value)"),\(carried) authority: authority)\n    }" : "")
                        \(succeeds && op.producesVoid ? "/// Seals a successful terminal result that carries no value.\n\(access)func succeeded() -> \(op.name)Completion\(pinned) { succeeded(()) }" : "")
                        \(op.isInfallible ? "" : "/// Seals a failed terminal result for this exact work.\n\(access)func failed(_ value: \(op.failure)) -> \(op.name)Completion {\n\(op.name)Completion(result: .failure(value),\(carried) authority: authority)\n}")
                    }
                    """ : ""
                return """
                    \(work)
                    /// The sealed terminal result of one execution, which only its owner\(local ? "'s `deliver`" : "") admits.
                    \(sealed)struct \(op.name)Completion\(sendable) {
                        \(op.isInfallible ? "/// The value the operation produced. This operation cannot fail." : "/// The typed terminal value.")
                        \(sealed)let \(op.isInfallible ? "value: \(op.output)" : "result: Swift::Result<\(op.output), \(op.failure)>")
                        \(op.hasRequest ? "/// What admission started the work with.\n\(sealed)let request: \(op.request)" : "")
                        fileprivate let authority: StateMachine::RuntimeTicket
                    }
                    """
            }
            .joined(separator: "\n")
        let cases = schema.operations.map { "case \($0.effect)(\($0.name)Completion)" }.joined(separator: "\n")
        let tickets = schema.operations.map { "case .\($0.effect)(let value): return value.authority" }
            .joined(separator: "\n")
        let completions =
            hasOperations
            ? """
            /// Closed typed terminal outcomes for this domain.
            \(sealed)enum Completion\(sendable) {
                \(cases)
                fileprivate var authority: StateMachine::RuntimeTicket { switch self { \(tickets) } }
            }
            """ : ""
        let handles =
            hasOperations && local
            ? """
            /// A sealed handle to actual execution bookkeeping.
            \(access)struct ExecutionHandle: Swift::Equatable, Swift::Sendable {
                fileprivate let authority: StateMachine::RuntimeTicket
            }
            /// How an execution ended, independently of cancellation or completion delivery.
            \(access)typealias ExecutionDisposition = StateMachine::ExecutionDisposition
            /// Whether a physical execution acknowledgment was recorded.
            \(access)typealias AcknowledgmentResult = StateMachine::AcknowledgmentResult
            """ : ""
        return """
            \(declarations)
            \(completions)
            \(handles)
            \(hasCommands ? commandBatches() : "")
            """
    }

    /// A `Local` owner's command and batch vocabulary, and the projection of the engine's batches into it.
    func commandBatches() -> String {
        let starts = schema.operations
            .map { op in
                guard op.hasRequest else {
                    return "case .\(op.effect): return .\(op.effect)(\(op.name)Work(authority: work.ticket))"
                }
                return
                    "case .\(op.effect)\(requestBindings(op)): return .\(op.effect)(\(op.name)Work(request: \(requestConstruction(op)), authority: work.ticket))"
            }
        // A cancellation revokes work at admission and is never started or emitted.
        let cancelOnly = schema.cancelledOperations.map {
            "case .\($0.cancelEffect), .\($0.cancelAllEffect): Swift::preconditionFailure(\"A cancellation is never started or emitted.\")"
        }
        // An emission never carries an operation's effect, and a start never carries an event's.
        let emissions = schema.events
            .map {
                $0.takesPayload
                    ? "case .\($0.effect)(let payload): return .\($0.effect)(payload)"
                    : "case .\($0.effect): return .\($0.effect)"
            }
        let startOnly = schema.operations.map {
            "case .\($0.effect): Swift::preconditionFailure(\"A start is never emitted.\")"
        }
        let emitOnly = schema.events.map {
            "case .\($0.effect): Swift::preconditionFailure(\"An emission is never started.\")"
        }
        let commands =
            schema.operations.map { "case \($0.effect)(\($0.name)Work)" }
            + schema.events.map {
                $0.takesPayload ? "case \($0.effect)(\(name).\($0.name).Payload)" : "case \($0.effect)"
            }
        let engineCommands =
            hasOperations
            ? """
            case .cancel(let ticket): return .cancel(ExecutionHandle(authority: ticket))
            case .start(let work): switch work.descriptor { \((starts + cancelOnly + emitOnly).joined(separator: "\n")) }
            """
            : "case .cancel, .start: Swift::preconditionFailure(\"A schema without operations issues no work.\")"
        let emit =
            hasEvents
            ? "case .emit(let effect): switch effect { \((startOnly + cancelOnly + emissions).joined(separator: "\n")) }"
            : "case .emit: Swift::preconditionFailure(\"A schema without events emits nothing.\")"
        let order =
            hasEvents
            ? "Cancellation commands, then starts and events in authored effect order."
            : "Cancellation commands followed by starts in authored effect order."
        let summary =
            !hasEvents
            ? "A closed accepted start or cancellation command."
            : hasOperations
                ? "A closed accepted start or cancellation command, or an emitted event."
                : "A closed accepted emitted event."
        return """
            /// \(summary)
            \(access)enum Command\(sendable) {
                \(hasOperations ? "case cancel(ExecutionHandle)" : "")
                \(commands.joined(separator: "\n"))
            }
            /// One whole FIFO batch with its historical receipt.
            \(access)struct CommandBatch: \(schema.mode == .shared ? "Swift::Sendable, " : "")StateMachine::LocalCommandBatch {
                /// The atomic acceptance represented by this batch.
                \(access)let receipt: Receipt
                /// \(order)
                \(access)let commands: [Command]
                /// Whether this is the separately reserved close batch.
                \(access)let terminal: Swift::Bool
                fileprivate init(receipt: Receipt, commands: [Command], terminal: Swift::Bool) {
                    self.receipt = receipt
                    self.commands = commands
                    self.terminal = terminal
                }
            }
            fileprivate static func _stateMachineBatch(_ batch: _StateMachineEngine.Batch) -> CommandBatch {
                let commands = batch.commands.map { command -> Command in
                    switch command {
                    \(engineCommands)
                    \(emit)
                    }
                }
                return CommandBatch(receipt: Receipt(batch.snapshot), commands: commands, terminal: batch.terminal)
            }
            """
    }

    /// The pattern that binds a keyed or input-taking operation's effect case, such as `(let key, let input)`.
    func requestBindings(_ op: Schema.Operation) -> String {
        let names = (op.isKeyed ? ["key"] : []) + (op.takesInput ? ["input"] : [])
        return names.isEmpty ? "" : "(" + names.map { "let \($0)" }.joined(separator: ", ") + ")"
    }

    /// The construction of an operation's request from the names `requestBindings` binds.
    func requestConstruction(_ op: Schema.Operation) -> String {
        let arguments = (op.isKeyed ? ["key: key"] : []) + (op.takesInput ? ["input: input"] : [])
        return "\(op.request)(\(arguments.joined(separator: ", ")))"
    }

    /// The `Observed` method that `prepare` calls for an edge.
    ///
    /// For a deprecated edge whose own method is public, this returns the nondeprecated helper method
    /// that the public method forwards to.
    func observedName(_ edge: Schema.Transition) -> String {
        guard edge.deprecation != nil, edgeAccess(edge, observed: true) != "fileprivate " else { return edge.name }
        return "_stateMachineDeprecated\(edge.declaration)"
    }

    /// The dispatch of one prepared edge from `source`, mapping an authored failure into `PreparationRejection`.
    func dispatchEdge(_ edge: Schema.Transition, source: String, arguments: String) -> String {
        let call = "\(source).\(observedName(edge))(\(arguments))"
        guard edge.failureType != nil else { return "return \(call)" }
        return "do { return try \(call) } catch { throw .\(rejectionCase(edge.name, from: edge.from))(error) }"
    }

    func preparation() -> String {
        let eligibility = schema.scopeKeys
            .map { scope in
                let phases = schema.scopePhases(scope)
                guard phases.count < schema.phases.count else { return "Swift::Array(0..<\(schema.phases.count))" }
                return "[" + phases.map { String(index($0)) }.joined(separator: ", ") + "]"
            }
            .joined(separator: ", ")
        let starts = schema.operations.enumerated()
            .map { i, op in
                let scope = schema.scopeIndex(op.scopeKey) ?? 0
                let dependencies = op.requires
                    .compactMap { schema.scopeIndex($0).map { "_StateMachineScopeID(kind: \($0))" } }
                    .joined(separator: ", ")
                let admission = policy(op.admission)
                // A keyed operation's multiplicity is per key, which the runtime checks after resolving keys.
                guard op.isKeyed else {
                    return """
                        case .\(op.effect)\(op.takesInput ? "(let input)" : ""):
                            \(op.takesInput ? "let _: \(op.name).Input = input" : "")
                            counts[\(i)] += 1
                            guard counts[\(i)] <= \(op.admission.maxNewIntents) else { throw .invalidPlan }
                            starts.append(.init(_StateMachineOperation(kind: \(i), scope: _StateMachineScopeID(kind: \(scope)),
                                dependencies: [\(dependencies)], policy: \(admission)), descriptor: effect))
                        """
                }
                return """
                    case .\(op.effect)\(requestBindings(op)):
                        \(op.takesInput ? "let _: \(op.name).Input = input" : "")
                        starts.append(.init(_StateMachineOperation(kind: \(i), scope: _StateMachineScopeID(kind: \(scope)),
                            dependencies: [\(dependencies)], policy: \(admission)), descriptor: effect, key: _StateMachineKey(key)))
                    """
            }
            .joined(separator: "\n")
        // A cancellation names its operation's kind and, unless it cancels all of its work, the key.
        let kinds = Dictionary(
            schema.operations.enumerated().map { ($1.effect, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let cancellations = schema.cancelledOperations
            .map { op in
                let kind = kinds[op.effect] ?? 0
                return """
                    case .\(op.cancelEffect)(let key): cancellations.append(.init(kind: \(kind), key: _StateMachineKey(key)))
                    case .\(op.cancelAllEffect): cancellations.append(.init(kind: \(kind), key: nil))
                    """
            }
            .joined(separator: "\n")
        // Only an unkeyed operation's starts are counted here, and only declared collections are mutated.
        let locals =
            (schema.operations.contains { !$0.isKeyed }
                ? ["var counts = Swift::Array(repeating: 0, count: \(schema.operations.count))"] : [])
            + (cancellations.isEmpty ? [] : ["var cancellations: [_StateMachineEngine.Cancellation] = []"])
            + (hasEvents ? ["var emissions: [_StateMachineEngine.Emission] = []"] : [])
        // An event starts nothing. It keeps its place among the starts and admission publishes it.
        let emissions = schema.events
            .map { "case .\($0.effect): emissions.append(.init(effect, position: starts.count))" }
            .joined(separator: "\n")
        // Each trigger's switch on the snapshot names the phases with an edge or router for it, in declaration
        // order, and a default covers the rest. Nesting single-subject switches, rather than switching on a
        // (trigger, snapshot) tuple, keeps the compiler's exhaustiveness check linear in the cases. The outer
        // switch names every trigger and has no default, so a trigger without a case fails to compile.
        let index = DispatchIndex(schema)
        let phasePositions = Dictionary(
            schema.phases.enumerated().map { ($1.caseName, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        func phaseSwitch(_ cases: [String]) -> String {
            guard !cases.isEmpty else { return "throw .invalidPhase" }
            let missing = cases.count < schema.phases.count ? "\ndefault: throw .invalidPhase" : ""
            return "switch snapshot { \(cases.joined(separator: "\n"))\(missing) }"
        }
        let inputCases = schema.inputs
            .map { input in
                let binding = input.payloadType == nil ? "" : "(let input)"
                let phases = index.sources(receiving: input.caseName, position: phasePositions)
                    .compactMap { p -> String? in
                        dispatch(
                            from: p,
                            trigger: Schema.Trigger(kind: .input, name: input.caseName),
                            source: "source",
                            payload: input.payloadType == nil ? nil : "input",
                            index: index
                        )
                        .map { "case .\(p)(let source): \($0)" }
                    }
                return "case .\(input.caseName)\(phases.isEmpty ? "" : binding): \(phaseSwitch(phases))"
            }
        let completionCases = schema.operations
            .map { op in
                let phases = index.sources(completing: op.effect, position: phasePositions)
                    .compactMap { p -> String? in
                        let success = dispatch(
                            from: p,
                            trigger: Schema.Trigger(kind: .success, name: op.effect),
                            source: "source",
                            payload: "value",
                            index: index
                        )
                        let failure = dispatch(
                            from: p,
                            trigger: Schema.Trigger(kind: .failure, name: op.effect),
                            source: "source",
                            payload: "value",
                            index: index
                        )
                        guard success != nil || failure != nil else { return nil }
                        // An infallible completion carries its value directly and has no failure edge.
                        if op.isInfallible, let success {
                            return """
                                case .\(p)(let source):
                                    let value: \(op.output) = completion.value
                                    \(success)
                                """
                        }
                        let succeeded =
                            success.map { "case .success(let value): \($0)" } ?? "case .success: throw .invalidPhase"
                        let failed =
                            failure.map { "case .failure(let value): \($0)" }
                            ?? (op.isInfallible
                                ? "case .failure(let value): switch value {}" : "case .failure: throw .invalidPhase")
                        return """
                            case .\(p)(let source):
                                switch completion.result {
                                \(succeeded)
                                \(failed)
                                }
                            """
                    }
                return "case .\(op.effect)\(phases.isEmpty ? "" : "(let completion)"): \(phaseSwitch(phases))"
            }
        let completion =
            hasOperations
            ? """
            fileprivate static func _stateMachineCompletion(_ completion: Completion, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
                switch completion { \(completionCases.joined(separator: "\n")) }
            }
            """ : ""
        return """
            fileprivate static var _stateMachineEligibility: [[Swift::Int]] { [\(eligibility)] }
            fileprivate static func _stateMachinePrepare(
                on record: _StateMachineEngine.Snapshot, next: \(name), effects: [Effect], from: Swift::Int, to: Swift::Int,
                invalidates: [Swift::Int], requiring ticket: StateMachine::RuntimeTicket?, claim: StateMachine::RuntimeDeliveryClaim?, edge: Swift::String
            ) -> Prepared {
                do throws(StateMachine::PlanRejection) {
                    var edits: [_StateMachineEngine.ScopeEdit] = []
                    for (scope, phases) in _stateMachineEligibility.enumerated() {
                        let before = phases.contains(from)
                        let after = phases.contains(to)
                        if after && (!before || invalidates.contains(scope)) { edits.append(.activate(_StateMachineScopeID(kind: Swift::UInt32(scope)))) }
                        else if before && !after { edits.append(.remove(_StateMachineScopeID(kind: Swift::UInt32(scope)))) }
                    }
                    \(schema.operations.isEmpty ? "let" : "var") starts: [_StateMachineEngine.Start] = []
                    \(locals.joined(separator: "\n"))
                    for effect in effects { switch effect { \([starts, cancellations, emissions].filter { !$0.isEmpty }.joined(separator: "\n")) } }
                    return Prepared(.candidate(try _StateMachineEngine.prepare(on: record, next: next, requiring: ticket.map { [$0] } ?? [],
                        plan: .init(scopes: edits, retire: ticket.map { [$0] } ?? [],\(cancellations.isEmpty ? "" : " cancellations: cancellations,") starts: starts,\(hasEvents ? " emissions: emissions," : "")
                            controlCount: invalidates.count, finishingClaims: claim.map { [$0] } ?? [], edge: edge))))
                } catch { return Prepared(.defective(.init(error, preparedOn: record))) }
            }
            /// Routes an input against a historical snapshot, rejecting a missing phase edge explicitly.
            ///
            /// A plan defect travels inside the returned `Prepared` value rather than throwing here, so
            /// admission reports it.
            \(access)static func prepare(_ input: Input, on snapshot: Snapshot) throws(PreparationRejection) -> Prepared {
                \(schema.inputs.isEmpty ? "" : "switch input { \(inputCases.joined(separator: "\n")) }")
            }
            \(completion)
            """
    }

    /// The edges and router of each (source phase, trigger) pair of a schema, gathered once.
    struct DispatchIndex {
        struct Pair: Hashable {
            let from: String
            let trigger: Schema.Trigger
        }

        /// Each pair's edges, in declaration order.
        let edges: [Pair: [Schema.Transition]]
        /// Each pair's router, the first declared.
        let routes: [Pair: Schema.Route]
        /// The source phases with an edge or router for each input.
        private let inputSources: [String: Set<String>]
        /// The source phases with a success or failure edge or router for each operation.
        private let completionSources: [String: Set<String>]

        init(_ schema: Schema) {
            edges = Dictionary(grouping: schema.transitions) { Pair(from: $0.from, trigger: $0.trigger) }
            routes = Dictionary(
                schema.routes.map { (Pair(from: $0.from, trigger: $0.trigger), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var inputSources: [String: Set<String>] = [:]
            var completionSources: [String: Set<String>] = [:]
            for pair in Array(edges.keys) + Array(routes.keys) {
                switch pair.trigger.kind {
                case .input: inputSources[pair.trigger.name, default: []].insert(pair.from)
                case .success, .failure: completionSources[pair.trigger.name, default: []].insert(pair.from)
                case .direct: break
                }
            }
            self.inputSources = inputSources
            self.completionSources = completionSources
        }

        /// The source phases with an edge or router for input `name`, ordered by `position`, each phase's
        /// place in declaration order.
        func sources(receiving name: String, position: [String: Int]) -> [String] {
            (inputSources[name] ?? []).sorted { (position[$0] ?? 0) < (position[$1] ?? 0) }
        }

        /// The source phases with a success or failure edge or router for operation `effect`, ordered by
        /// `position`, each phase's place in declaration order.
        func sources(completing effect: String, position: [String: Int]) -> [String] {
            (completionSources[effect] ?? []).sorted { (position[$0] ?? 0) < (position[$1] ?? 0) }
        }
    }

    /// The dispatch of one (source phase, trigger) pair, or `nil` when the pair has no edge or router.
    ///
    /// An input dispatches to the phase's edge method, and a completion to its fileprivate edge with the
    /// completion's authority. A routed pair runs its router inline and dispatches to the edge it selects.
    func dispatch(
        from: String,
        trigger: Schema.Trigger,
        source: String,
        payload: String?,
        index: DispatchIndex
    ) -> String? {
        let isInput = trigger.kind == .input
        // A completion edge receives the retained request when it takes one, and the work's authority.
        func arguments(_ edge: Schema.Transition) -> String {
            guard !isInput else { return payload ?? "" }
            return
                "\(payload ?? "value"), \(edge.takesRequest ? "request: completion.request, " : "")authority: completion.authority"
        }
        let pair = DispatchIndex.Pair(from: from, trigger: trigger)
        let edges = index.edges[pair] ?? []
        schema.workCounter.work.dispatchedPairs += 1
        schema.workCounter.work.dispatchedEdges += edges.count
        guard let route = index.routes[pair] else {
            return edges.first.map { dispatchEdge($0, source: source, arguments: arguments($0)) }
        }
        // A router sees plain values only, while a completion's authority goes to the edge it selects.
        // Each function's failure becomes its own `PreparationRejection` case.
        let request = route.takesRequest ? ", request: completion.request" : ""
        // A completion router of a success without output takes no output.
        let routed = isInput || route.payloadType != nil ? payload : nil
        let call =
            "\(authored(route.deprecation)).\(route.name)(\(source).value\(routed.map { ", " + $0 } ?? "")\(request))"
        let rejection = rejectionCase(route.name, from: route.from)
        guard let choice = schema.choiceType(route) else {
            return "do { try \(call) } catch { throw .\(rejection)(error) }"
        }
        let selection =
            route.failureType == nil
            ? "let selection: \(choice) = \(call)"
            : "let selection: \(choice)\ndo { selection = try \(call) } catch { throw .\(rejection)(error) }"
        let cases = edges.map { "case .\($0.name): \(dispatchEdge($0, source: source, arguments: arguments($0)))" }
            .joined(separator: "\n")
        return """
            \(selection)
            switch selection { \(cases) }
            """
    }

    /// The phases saved data may restore, and the validated root for each owner's `restoring:` initializer.
    func restoration() -> String {
        let cases = schema.restorablePhases.map { "case \($0.caseName)(\($0.typeName))" }.joined(separator: "\n")
        // Each variant names only the attribute arguments the schema actually wrote.
        let documentation =
            if schema.restoration?.only != nil {
                "/// A phase that saved data can restore, matching the phases listed in `@Restoration(only:)`."
            } else if schema.restoration?.allows.isEmpty == false {
                "/// A phase that saved data can restore, covering phases with no active operations and those\n/// listed in `@Restoration(allows:)`."
            } else {
                "/// A phase that saved data can restore, covering phases with no active operations."
            }
        let declaration = """
            \(documentation) A restored owner has no outstanding work.
            \(access)enum Restoration\(conformances(schema.mode == .shared ? ["Swift::Sendable"] : [])) {
                \(cases)
            }
            """
        guard let validator = schema.restoration else { return declaration }
        let rejection =
            validator.failureType.map { failure in
                """
                /// Why `reset(restoring:)` did not replace an owner's model.
                \(access)enum ResetRejection: Swift::Error {
                    /// The `@Restoration` function rejected the saved data.
                    case restoration(\(failure))
                    /// The owner refused the reset because it is closed, its revisions are exhausted, or it had no queue slot for the reset's batch.
                    case commit(CommitRejection)
                }
                """
            } ?? ""
        let roots = schema.restorablePhases
            .map {
                "case .\($0.caseName)(let payload): return (.\($0.caseName)(payload), [\(scopes(in: $0.caseName))])"
            }
            .joined(separator: "\n")
        return """
            \(declaration)
            \(rejection)
            fileprivate static func _stateMachineRestored(_ saved: \(validator.archiveParameter))\(restorationThrows) -> (model: \(name), scopes: [StateMachine::RuntimeScopeID]) {
                switch \(validator.failureType == nil ? "" : "try ")\(authored(validator.deprecation)).\(validator.name)(saved) { \(roots) }
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

    var ledger: String { "StateMachine::RuntimeDeliveryLedger<\(name), Effect, Completion, PreparationRejection>" }

    /// The pending-completion vocabulary shared by every owner of a schema with operations.
    func pendingDeclarations() -> String {
        // `PendingCompletion` declares `Outcome` and `Rejection`, which would capture an operation of
        // either name, so the outcome's cases spell each operation's types from the schema's name.
        let outcomes = schema.operations
            .map { op in
                let output = qualified(op.output)
                let value = op.isInfallible ? output : "Swift::Result<\(output), \(qualified(op.failure))>"
                return "case \(op.effect)(\(value)\(op.hasRequest ? ", request: \(qualified(op.request))" : ""))"
            }
            .joined(separator: "\n")
        let projections = schema.operations
            .map {
                "case .\($0.effect)(let completion): outcome = .\($0.effect)(completion.\($0.isInfallible ? "value" : "result")\($0.hasRequest ? ", request: completion.request" : ""))"
            }
            .joined(separator: "\n")
        return """
            fileprivate typealias _StateMachineLedger = \(ledger)
            \(schema.mode == .shared ? (schema.generatesManagedOwner ? """
            /// A single-pass latest-value sequence of a managed owner's retained completions.
            \(access)typealias PendingCompletionUpdates = StateMachine::SnapshotSequence<[PendingCompletion]>
            """ : "") : (schema.generates(.mainActorHost) ? """
            /// A single-consumer latest-value stream of a `MainActor` owner's retained completions.
            \(access)typealias PendingCompletionUpdates = StateMachine::MainActorSnapshotSequence<[PendingCompletion]>
            """ : ""))
            \(schema.mode != .shared && schema.generates(.isolatedHost) ? """
            /// A single-consumer latest-value stream of the retained completions of an owner confined to one actor.
            \(access)typealias IsolatedPendingCompletionUpdates = StateMachine::IsolatedSnapshotSequence<[PendingCompletion]>
            """ : "")
            /// The opaque identity of one retained terminal outcome of this schema's owners.
            \(access)struct PendingCompletionID: Swift::Hashable, Swift::Sendable {
                fileprivate let raw: StateMachine::RuntimePendingID
            }
            /// A retained terminal outcome and its delivery diagnostics.
            ///
            /// The outcome is an inert value. Only `reconcile(id:)`, `retryAdmission(id:)`, or
            /// `discardPending(id:)` can settle the retained completion it describes.
            \(access)struct PendingCompletion\(sendable) {
                /// The retained terminal value of one operation, with the request its work was started with.
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
                /// The saturating count of claimed preparations. Capacity retries do not increment it.
                \(access)let attempts: Swift::UInt64
                /// Whether the preparation count has reached its representable limit.
                \(access)var attemptsSaturated: Swift::Bool { attempts == Swift::UInt64.max }
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
            \(schema.generates(.local) ? """
            /// The decision `deliver` made about one terminal outcome.
            \(access)enum DeliveryResult\(sendable) {
                /// The outcome committed.
                case committed(Receipt)
                /// The outcome is retained, and its status describes what admission is waiting for.
                case pending(PendingCompletionID, PendingStatus)
                \(refusedCase)
                /// The operation's authority is inactive or its outcome was already settled.
                case stale
                /// The completion was issued by a different owner.
                case foreignOwner
            }
            """ : "")
            /// The result of one more attempt to admit a retained outcome.
            \(access)enum ReconcileResult\(sendable) {
                /// The retained outcome committed.
                case committed(Receipt)
                /// The outcome is still retained, and its status describes what admission is waiting for.
                case pending(PendingCompletionID, PendingStatus)
                \(refusedCase)
                /// Another attempt holds the only preparation claim.
                case inProgress
                /// No outcome with this identity is retained.
                case notPending
            }
            /// The result of revoking a retained outcome's operation.
            \(access)enum DiscardResult\(sendable) {
                /// The authority-only commit revoked the operation and disposed of its outcome.
                case discarded(Receipt)
                /// The owner refused the authority-only commit, leaving the outcome retained.
                case rejected(CommitRejection)
                /// No outcome with this identity is retained.
                case notPending
            }
            /// The refusal of the outcome retained as `id`, whose preparation from `record` threw `rejection`.
            fileprivate static func _stateMachineRefused(_ id: StateMachine::RuntimePendingID, _ rejection: PreparationRejection, on record: _StateMachineEngine.Snapshot) -> ReconcileResult {
                .refused(PendingCompletionID(raw: id), rejection, routeID: _stateMachineRefusingRoute(rejection, in: _stateMachinePhase(of: record)))
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

    /// The `reset(to:)` and `reset(to:expecting:)` members of an owner and, with a `@Restoration`
    /// function, `reset(restoring:)` and `reset(restoring:expecting:)`.
    ///
    /// `reset` spells the owner's raw reset of a model, its scopes, and an `expecting:` argument or
    /// nothing, and `after` runs once it returns.
    private func resetMembers(
        mutating: Bool,
        asynchronous: String,
        isolation: String = "",
        reset: (_ model: String, _ scopes: String, _ expecting: String) -> String,
        after: String = ""
    ) -> String {
        let modifier = mutating ? "mutating " : ""
        // A schema without operations has no work to revoke and no completion to dispose of.
        let work =
            hasOperations
            ? """
            /// Every outstanding operation is revoked, with its cancellation published in the reset's
            /// batch, and every retained completion is disposed of, so a late result is stale. The owner
            /// keeps its identity and subscribers, and its revision advances. Work that is still running
            /// keeps its execution reservation until it terminates.
            """
            : """
            /// The owner keeps its identity and subscribers, and its revision advances.
            """
        let finish = after.isEmpty ? "" : "\n" + after
        // A manual owner queues a batch only for commands, while a managed owner queues every acceptance.
        let queueing =
            mutating
            ? (hasOperations
                ? "It queues a batch only to cancel the work it revokes, so it needs a slot only then."
                : "It queues no batch, so it needs no slot.")
            : "It queues every reset to publish it, so it always needs a slot."
        let isolated = isolation.isEmpty ? "" : ", " + isolation
        let expectation = ", expecting: expected.record"
        var members = """
            /// Replaces the model with `initial` in a fresh incarnation, as a fresh owner starts.
            ///
            \(work)
            ///
            /// A reset expects no revision, so no concurrent commit can make it conflict. It throws
            /// `.closed` once the owner is closed, `.revisionExhausted` when no ordinary revision remains,
            /// or `.capacityExceeded(.commitQueue)` when it must queue a batch while the commit queue is
            /// full, leaving state unchanged. \(queueing)
            @discardableResult
            \(access)\(modifier)func reset(to initial: \(initialType)\(initialDefault)\(isolated))\(asynchronous) throws(CommitRejection) -> Receipt {
                let result = \(reset(".\(schema.initial)(initial)", "[\(initialScopes)]", ""))\(finish)
                switch result {
                case .committed(let record): return Receipt(record)
                case .rejected(let reason, _): throw reason
                }
            }
            /// Replaces the model with `initial` exactly as `reset(to:)` does, but only while the owner
            /// still holds the root `expected` observed, so a decision made on that snapshot cannot
            /// discard a change accepted since.
            ///
            /// Otherwise it leaves state unchanged and throws the same errors as a commit prepared on
            /// `expected`, in precedence order. It reports `.foreignOwner` for another owner's snapshot,
            /// `.closed` after closure, `.obsoleteIncarnation` after another reset, `.conflict` after any
            /// other acceptance, and then the same errors as `reset(to:)`.
            @discardableResult
            \(access)\(modifier)func reset(to initial: \(initialType)\(initialDefault), expecting expected: Snapshot\(isolated))\(asynchronous) throws(CommitRejection) -> Receipt {
                let result = \(reset(".\(schema.initial)(initial)", "[\(initialScopes)]", expectation))\(finish)
                switch result {
                case .committed(let record): return Receipt(record)
                case .rejected(let reason, _): throw reason
                }
            }
            """
        guard let validator = schema.restoration else { return members }
        let validation: String
        let rejection: String
        let refusal: String
        if let failure = validator.failureType {
            validation = """
                let restored: (model: \(name), scopes: [StateMachine::RuntimeScopeID])
                do throws(\(failure)) { restored = try _stateMachineRestored(saved) } catch { throw .restoration(error) }
                """
            rejection = "ResetRejection"
            refusal = ".commit(reason)"
        } else {
            validation = "let restored = _stateMachineRestored(saved)"
            rejection = "CommitRejection"
            refusal = "reason"
        }
        members += """

            /// Replaces the model with the phase `\(validator.name)` validates from saved data in a fresh
            /// incarnation, as `reset(to:)` does. Restoring saved data never resumes prior work.
            @discardableResult
            \(deprecated(schema.restoration?.deprecation))\(access)\(modifier)func reset(restoring saved: \(validator.archiveParameter)\(isolated))\(asynchronous) throws(\(rejection)) -> Receipt {
                \(validation)
                let result = \(reset("restored.model", "restored.scopes", ""))\(finish)
                switch result {
                case .committed(let record): return Receipt(record)
                case .rejected(let reason, _): throw \(refusal)
                }
            }
            /// Replaces the model with the phase `\(validator.name)` validates from saved data exactly as
            /// `reset(restoring:)` does, but only while the owner still holds the root `expected`
            /// observed, refusing otherwise as `reset(to:expecting:)` does.
            @discardableResult
            \(deprecated(schema.restoration?.deprecation))\(access)\(modifier)func reset(restoring saved: \(validator.archiveParameter), expecting expected: Snapshot\(isolated))\(asynchronous) throws(\(rejection)) -> Receipt {
                \(validation)
                let result = \(reset("restored.model", "restored.scopes", expectation))\(finish)
                switch result {
                case .committed(let record): return Receipt(record)
                case .rejected(let reason, _): throw \(refusal)
                }
            }
            """
        return members
    }

    /// The member of `Local` that transfers command batches.
    func localDrain() -> String {
        let summary =
            hasOperations
            ? "Physical execution occurs after mutating access ends."
            : "Handle their events after mutating access ends."
        return """
            /// Transfers at most `limit` whole FIFO batches. \(summary)
            \(access)mutating func drainCommands(limit: Swift::Int = .max) -> [CommandBatch] {
                engine.drain(limit: limit).map { _stateMachineBatch($0) }
            }
            /// How many whole batches a drain would transfer, including the terminal batch, without
            /// transferring any.
            \(access)var queuedBatchCount: Swift::Int { engine.queuedBatchCount }
            """
    }

    /// The members of `Local` that acknowledge execution and settle retained outcomes.
    func localDelivery() -> String {
        """
        /// Records actual termination independently of cancellation and completion delivery.
        ///
        /// Pass `.skippedBeforeStart` for work the caller never began.
        \(access)mutating func acknowledgeExecution(_ execution: ExecutionHandle, disposition: ExecutionDisposition = .terminated) -> AcknowledgmentResult {
            switch engine.acknowledge(execution.authority, skippedBeforeStart: disposition == .skippedBeforeStart) {
            case .recorded: return .recorded
            case .duplicate: return .duplicate
            case .foreignOwner: return .foreignOwner
            }
        }
        /// Retains the first outcome and attempts one typed preparation against the current root.
        ///
        /// This is the only way to submit a terminal outcome. A later outcome for the same work never
        /// replaces the retained one and reports the retained outcome's status instead.
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
                case .refused(let id, let rejection, let routeID): return .refused(id, rejection, routeID: routeID)
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
                let finish = ledger.finish(attempt, preparation: preparation, in: &engine)
                if case .failure(.preparation(let rejection)) = preparation, case .pending(let raw, .reconciliationRequired) = finish {
                    return _stateMachineRefused(raw, rejection, on: attempt.snapshot)
                }
                return _stateMachineFinish(finish)
            }
        }
        /// Retries admission of a retained candidate that was waiting for capacity, without preparing it again.
        ///
        /// Draining and acknowledging never admit a retained completion. Call this after they free capacity.
        \(access)mutating func retryAdmission(id: PendingCompletionID) -> ReconcileResult {
            _stateMachineFinish(ledger.retryAdmission(id.raw, in: &engine))
        }
        /// Queries immutable first-outcome records without claiming preparation.
        \(access)borrowing func pendingCompletions() -> [PendingCompletion] { ledger.pending.map(PendingCompletion.init) }
        /// Revokes one retained operation using an atomic authority-only commit.
        ///
        /// The operation's work already returned the outcome it settles, so the commit issues no
        /// cancellation for it. By contrast, a reset or closure cancels every ticket it revokes.
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
            \(access)let isRetrying: Swift::Bool
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
            \(access)struct ShutdownDiagnostics: Swift::Equatable, Swift::Sendable {
                \(hasOperations ? "/// An execution and delivery obligation that remained tracked.\n\(access)typealias OutstandingExecution = StateMachine::ShutdownDiagnostics.OutstandingExecution" : "")
                /// The owner's last accepted revision at the observation.
                \(access)let acceptedRevision: Swift::UInt64
                /// The revision of the last fully processed FIFO batch.
                \(access)let processedThrough: Swift::UInt64
                /// Whether accepted ordinary or terminal batches still await processing.
                \(access)let hasQueuedBatches: Swift::Bool
                /// Whether a FIFO processing turn still owns responsibility.
                \(access)let isDraining: Swift::Bool
                \(operationFields)
                fileprivate init(_ raw: StateMachine::ShutdownDiagnostics) {
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
            \(access)enum ShutdownResult: Swift::Equatable, Swift::Sendable {
                /// Every execution, delivery, and preparation obligation settled.
                case quiescent
                /// The deadline passed first, and the diagnostics describe what remained outstanding.
                case timedOut(ShutdownDiagnostics)
                fileprivate init(_ raw: StateMachine::ShutdownDiagnostics?) {
                    self = raw.map { .timedOut(ShutdownDiagnostics($0)) } ?? .quiescent
                }
            }
            /// Whether `flush(through:)` waited for a receipt's batch to be processed.
            \(access)typealias FlushResult = StateMachine::FlushResult
            """
    }

    /// The protocols through which a harness drives a `Local` owner, covering commands and deliveries
    /// when it has them, plus initial defaults and `@Restoration` when declared.
    var localConformance: String {
        let base =
            hasOperations
            ? "StateMachine::DeliveringLocalStateMachine"
            : hasCommands ? "StateMachine::DrainingLocalStateMachine" : "StateMachine::LocalStateMachine"
        return base + (schema.initialDefault == nil ? "" : ", StateMachine::DefaultingLocalStateMachine")
            + (schema.restoration == nil ? "" : ", StateMachine::RestoringLocalStateMachine")
    }

    /// The type witnesses and graph metadata of a `Local` owner's conformance.
    ///
    /// The type witnesses are explicit because `deliver` is overloaded per operation. A restoring
    /// owner's saved data and rejection are inferred from its `reset(restoring:)`. The metadata reads
    /// only values the caller already holds and constructs no authority.
    func localWitnesses() -> String {
        var types = [
            "Input = \(name).Input", "Snapshot = \(name).Snapshot", "Receipt = \(name).Receipt",
            "SendRejection = \(name).SendRejection", "Prepared = \(name).Prepared",
            "CommitResult = \(name).CommitResult", "InitialPhase = \(initialType)",
        ]
        if hasCommands { types += ["Command = \(name).Command", "CommandBatch = \(name).CommandBatch"] }
        var delivery = ""
        if hasOperations {
            types += [
                "Completion = \(name).Completion", "ExecutionHandle = \(name).ExecutionHandle",
                "PendingCompletionID = \(name).PendingCompletionID", "PendingCompletion = \(name).PendingCompletion",
                "DeliveryResult = \(name).DeliveryResult", "ReconcileResult = \(name).ReconcileResult",
                "DiscardResult = \(name).DiscardResult",
            ]
            delivery = """
                /// The receipt of a delivery that committed, or `nil` when the outcome was retained or not taken.
                \(access)static func receipt(of result: DeliveryResult) -> Receipt? {
                    if case .committed(let receipt) = result { receipt } else { nil }
                }
                /// The receipt of a retained outcome's admission, or `nil` when it did not commit.
                \(access)static func receipt(of result: ReconcileResult) -> Receipt? {
                    if case .committed(let receipt) = result { receipt } else { nil }
                }
                /// The receipt of a discard's authority-only commit, or `nil` when nothing was discarded.
                \(access)static func receipt(of result: DiscardResult) -> Receipt? {
                    if case .discarded(let receipt) = result { receipt } else { nil }
                }
                /// The identifier of the router or completion edge, as the graph names it, whose authored function
                /// refused the outcome in the call that returned `result`, or `nil` when that call's preparation
                /// did not refuse it.
                \(access)static func rejectingRoute(of result: DeliveryResult) -> Swift::String? {
                    if case .refused(_, _, let routeID) = result { routeID } else { nil }
                }
                /// The identifier of the router or completion edge, as the graph names it, whose authored function
                /// refused the outcome in the call that returned `result`, or `nil` when that call's preparation
                /// did not refuse it.
                \(access)static func rejectingRoute(of result: ReconcileResult) -> Swift::String? {
                    if case .refused(_, _, let routeID) = result { routeID } else { nil }
                }
                """
        }
        // A declared initial default is the payload `reset()` installs, which a harness reaches through it.
        let defaulting =
            schema.initialDefault.map {
                "/// A fresh initial payload, constructed as the schema's declared default constructs it.\n\(access)static func defaultInitialPhase() -> InitialPhase { \($0) }\n"
            } ?? ""
        return """
            \(types.map { "/// A type of this owner's `LocalStateMachine` conformance.\n\(access)typealias \($0)" }.joined(separator: "\n"))
            /// The declared structure of this owner's graph.
            \(access)static var graph: StateMachine::StateMachineGraph { \(schemaReference).graph }
            /// The identifier of the phase a snapshot holds, as the graph names it.
            \(access)static func phase(of snapshot: Snapshot) -> Swift::String { _stateMachinePhase(of: snapshot.record) }
            /// The receipt of an admitted proposal, or `nil` when admission rejected it.
            \(access)static func receipt(of result: CommitResult) -> Receipt? {
                if case .committed(let receipt) = result { receipt } else { nil }
            }
            \(rejectingRoute())
            \(defaulting)\(delivery)
            """
    }

    /// A `Local` owner's witness that names the router or edge whose authored function refused an input.
    func rejectingRoute() -> String {
        """
        /// The identifier of the router or edge, as the graph names it, whose authored function refused an
        /// input that `send` rejected from a snapshot in `phase`, or `nil` when no authored function refused it.
        \(access)static func rejectingRoute(of rejection: SendRejection, in phase: Swift::String) -> Swift::String? {
            guard case .preparation(let preparation) = rejection else { return nil }
            return _stateMachineRefusingRoute(preparation, in: phase)
        }
        """
    }

    /// The `DeliveryResult` and `ReconcileResult` case of an outcome that the call's own preparation refused.
    var refusedCase: String {
        """
        /// This call prepared the outcome, and its routing or an authored function refused it, so the outcome
        /// is retained with status `reconciliationRequired`.
        ///
        /// `routeID` is the identifier of the router or completion edge whose authored function refused it,
        /// as `graph` names it, or `nil` when no authored function refused it.
        case refused(PendingCompletionID, PreparationRejection, routeID: Swift::String?)
        """
    }

    /// The identifier of the phase a root holds, and of the router or edge whose authored function threw a
    /// `PreparationRejection` from a phase, which a `Local` owner and every refused outcome report.
    ///
    /// Each throwing function's `PreparationRejection` case, from each phase it leaves, names that phase's
    /// router or edge of the function's name, as the graph identifies it. Any other rejection names none.
    func refusingRoute() -> String {
        guard schema.generates(.local) || hasOperations else { return "" }
        let phases = schema.phases
            .map { "case .\($0.caseName): return \(literal($0.caseName))" }
            .joined(separator: "\n")
        var seen = Set<String>()
        let cases = schema.throwingFunctions
            .compactMap { function -> String? in
                let rejection = rejectionCase(function.name, from: function.from)
                guard seen.insert("\(rejection) \(function.from)").inserted else { return nil }
                let phase = literal(function.from)
                let route = literal("\(function.from).\(function.name)")
                return "case (.\(rejection), \(phase)): return \(route)"
            }
        let body =
            cases.isEmpty
            ? "nil"
            : (["switch (rejection, phase) {"] + cases + ["default: return nil", "}"])
                .joined(separator: "\n")
        return """
            fileprivate static func _stateMachinePhase(of record: _StateMachineEngine.Snapshot) -> Swift::String {
                switch record.model { \(phases) }
            }
            fileprivate static func _stateMachineRefusingRoute(_ rejection: PreparationRejection, in phase: Swift::String) -> Swift::String? {
                \(body)
            }
            """
    }

    func local() -> String {
        let ops = hasOperations
        // A Local queues only batches that carry a command and the terminal batch. Every other receipt
        // is returned directly by `send` or `commit`, so a run of plain edits needs no draining.
        let batches = ", recording: .commands"
        let restoring = schema.restoration.map { validator in
            """

            \(restoringDocumentation)
            \(deprecated(schema.restoration?.deprecation))\(access)init(restoring saved: \(validator.archiveParameter), configuration: LocalConfiguration = .default)\(restorationThrows) {
                \(restoredRoot)
                engine = _StateMachineEngine(restored.model, scopes: restored.scopes, limits: configuration\(batches))
            }
            """
        }
        return """
            /// A noncopyable manually driven owner with an embedded value engine.
            \(access)struct Local: ~Swift::Copyable, \(localConformance) {
                \(localWitnesses())
                fileprivate var engine: _StateMachineEngine
                \(ops ? "fileprivate var ledger = _StateMachineLedger()" : "")
                /// Creates fresh authority only in the declared initial phase.
                \(access)init(_ initial: \(initialType)\(initialDefault), configuration: LocalConfiguration = .default) {
                    engine = _StateMachineEngine(.\(schema.initial)(initial), scopes: [\(initialScopes)], limits: configuration\(batches))
                }\(restoring ?? "")
                /// Returns an immutable historical observation.
                \(access)borrowing func snapshot() -> Snapshot { _stateMachineSnapshot(engine.snapshot) }
                /// Whether `snapshot` was taken from this owner, in any incarnation.
                ///
                /// A reset keeps the owner, and another owner never matches, even one that holds an equal
                /// model at the same revision. The answer grants no authority.
                \(access)borrowing func owns(_ snapshot: Snapshot) -> Swift::Bool { engine.owns(snapshot.record) }
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
                /// Routes, prepares, and admits one input against the current root.
                @discardableResult
                \(access)mutating func send(_ input: Input) throws(SendRejection) -> Receipt {
                    \(sendBody("""
                    let prepared: Prepared
                    do { prepared = try \(schemaReference).prepare(input, on: snapshot()) } catch { throw .preparation(error) }
                    switch commit(prepared) {
                    case .committed(let receipt): return receipt
                    case .rejected(let reason, _): throw .commit(reason)
                    }
                    """))
                }
                \([hasCommands ? localDrain() : nil, ops ? localDelivery() : nil].compactMap { $0 }.joined(separator: "\n"))
                /// Ends admission while retaining historical read access.
                @discardableResult
                \(access)mutating func close() -> Receipt {
                    let result = engine.close()
                    \(ops ? "ledger.prune(in: engine)" : "")
                    return Receipt(result)
                }
                \(resetMembers(mutating: true, asynchronous: "", reset: { "engine.reset(\($0), scopes: \($1)\($2))" }, after: ops ? "ledger.prune(in: engine)" : ""))
                \(ops ? """
                /// Closure, FIFO transfer, and all actual execution and delivery obligations have settled.
                \(access)var isQuiescent: Swift::Bool { engine.isQuiescent }
                """ : hasCommands ? """
                /// Closure and FIFO transfer of every batch have settled.
                \(access)var isQuiescent: Swift::Bool { engine.isQuiescent }
                """ : "")
            }
            """
    }
    /// The parameters after the initial payload or saved data in every managed owner's designated initializer.
    ///
    /// An `IsolatedHost` takes its owning actor first, and an `ActorHost` takes the actor whose executor
    /// it shares last.
    private func managedParameters(
        drivers: String,
        isolation: String,
        owner: Bool = false,
        executor: Bool = false
    )
        -> String
    {
        let handlers = eventHandlers(isolation: isolation, owner: owner).map { $0 + ", " } ?? ""
        let leading = owner ? "isolation: isolated Owner, " : ""
        let trailing = executor ? ", isolatedTo: (any Swift::Actor)? = nil" : ""
        guard hasOperations else { return "\(leading)\(handlers)configuration: Configuration = .default\(trailing)" }
        return
            "\(leading)drivers: \(drivers), \(handlers)configuration: Configuration = .default, \(completionPolicyParameter)\(trailing)"
    }

    /// An isolation attribute followed by a space, or nothing for a closure confined to its owner's region.
    private func attribute(_ isolation: String) -> String { isolation.isEmpty ? "" : isolation + " " }

    /// The documentation of a managed owner's event handlers, beginning with a line break, or nothing
    /// without events.
    ///
    /// `isolation` names where they run, or `nil` for the owner's serial batch turn.
    private func handlerNote(isolation: String?) -> String {
        guard hasEvents else { return "" }
        let place = isolation.map { "on \($0)" } ?? "from the serial turn that processes its batch"
        return """

            ///
            /// Each event's handler runs once per emission, in commit order, \(place), after the commit and
            /// outside every lock, and before this batch offers its snapshot to existing registrations.
            """
    }

    /// The required handler parameters of a managed owner's initializers, one per event, or `nil` without events.
    ///
    /// An `IsolatedHost` handler (`owner`) is `@Sendable` and receives its owning actor, isolated, before
    /// the payload, as a driver does, so it reaches the actor's state through that parameter and captures
    /// nothing confined.
    private func eventHandlers(isolation: String, owner: Bool = false) -> String? {
        guard hasEvents else { return nil }
        return schema.events
            .map {
                let parameters = (owner ? ["isolated Owner"] : []) + ($0.takesPayload ? ["\($0.name).Payload"] : [])
                let signature = "(\(parameters.joined(separator: ", "))) -> Swift::Void"
                return "\($0.handler): @escaping \(attribute(owner ? "@Sendable" : isolation))\(signature)"
            }
            .joined(separator: ", ")
    }

    /// The runtime host argument that passes each accepted emission to its event's handler.
    private func emitHook(owner: Bool) -> String {
        guard hasEvents else { return "" }
        let actor = owner ? "owner" : ""
        let handled = schema.events.map {
            let arguments = (owner ? ["owner"] : []) + ($0.takesPayload ? ["payload"] : [])
            return $0.takesPayload
                ? "case .\($0.effect)(let payload): \($0.handler)(\(arguments.joined(separator: ", ")))"
                : "case .\($0.effect): \($0.handler)(\(arguments.joined(separator: ", ")))"
        }
        let unemitted =
            schema.operations.map { ".\($0.effect)" }
            + schema.cancelledOperations.flatMap { [".\($0.cancelEffect)", ".\($0.cancelAllEffect)"] }
        let starts = unemitted.isEmpty ? [] : ["case \(unemitted.joined(separator: ", ")): break"]
        let cases = (handled + starts).joined(separator: "\n")
        return ", emit: { \(owner ? actor + ", " : "")effect in switch effect { \(cases) } }"
    }

    /// The type of one operation's driver, returning the bare output when it cannot fail or a `Result`
    /// otherwise.
    ///
    /// A fallible driver returns `Result` rather than throwing, because a typed-throws closure literal
    /// does not infer its thrown type.
    ///
    /// An `IsolatedHost` driver takes its owning actor, isolated, before the key and input. An input the
    /// macro confirms is a function type is `@escaping`, so a driver can keep it or return it. Any other
    /// input is passed as it is, including a closure the macro cannot see, so a driver can call it.
    func driverType(_ op: Schema.Operation, isolation: String, owner: Bool = false) -> String {
        let output = op.isInfallible ? op.output : "Swift::Result<\(op.output), \(op.failure)>"
        let parameters =
            (owner ? ["isolated Owner"] : []) + (op.isKeyed ? [op.key] : [])
            + (op.takesInput ? ["\(op.inputEscapes ? "@escaping " : "")\(op.name).Input"] : [])
        return "\(attribute(isolation))(\(parameters.joined(separator: ", "))) async -> \(output)"
    }

    /// The `completionPolicy:` parameter of every managed initializer, defaulting to `.retry` unless a
    /// completion edge or router can refuse an outcome, in which case the caller must choose.
    private var completionPolicyParameter: String {
        "completionPolicy: CompletionPolicy\(schema.completionCanRefuse ? "" : " = .retry")"
    }

    /// A managed owner's completion policy, which carries an optional handler in the owner's isolation.
    ///
    /// It begins with a line break so that a schema without operations gains no blank line.
    private func completionPolicy(isolation: String, sendable: Bool) -> String {
        guard hasOperations else { return "" }
        let handler = "\(attribute(isolation))(PendingCompletion) -> Swift::Void"
        let choice =
            schema.completionCanRefuse
            ? """
            /// A completion edge or router of this schema can refuse an outcome, so every initializer
            /// takes the policy without a default.
            """
            : """
            /// Initializers default to `.retry`.
            """
        return "\n" + """
            /// How this owner settles a retained completion that does not commit when it is delivered.
            ///
            /// `.retry` prepares a completion again against the newer state when another commit wins the
            /// race. That behaves like the result arriving a moment later, when its edge would run against
            /// the newer phase anyway. Work that must not survive a change is revoked by the edge's
            /// `invalidates:` instead. `.manual` never prepares a completion again on its own. Either form
            /// can pass each completion that needs reconciliation to a handler.
            ///
            \(choice)
            ///
            /// A handler runs outside the owner's critical section each time a retained completion enters
            /// `reconciliationRequired`. This happens when its completion edge or router throws, its
            /// effect plan is defective, the owner refuses its admission, an explicit `reconcile(id:)`
            /// does not commit, or, under `.manual`, its preparation loses a race. Settle it with
            /// `reconcile(id:)` or `discardPending(id:)`.
            \(access)struct CompletionPolicy\(sendable ? ": Swift::Sendable" : "") {
                fileprivate let runtime: StateMachine::RuntimeCompletionPolicy
                fileprivate let reconciliationRequired: \(attribute(isolation))(_StateMachineLedger.Pending) -> Swift::Void
                private init(_ runtime: StateMachine::RuntimeCompletionPolicy, handler: @escaping \(handler)) {
                    self.runtime = runtime
                    reconciliationRequired = { handler(PendingCompletion($0)) }
                }
                /// Prepares a completion again against the current state when another commit wins the race,
                /// at most four times per turn before yielding to other work, and notifies no one.
                ///
                /// Choose it when every completion edge and router is deterministic and free of side
                /// effects, since the compiler does not enforce that. A completion retained for any other
                /// reason stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
                \(access)static var retry: CompletionPolicy { CompletionPolicy(.retry, handler: { _ in }) }
                /// Retries lost races as `retry` does, and passes every completion that still needs
                /// reconciliation to `handler`.
                \(access)static func retry(onReconciliationRequired handler: @escaping \(handler)) -> CompletionPolicy {
                    CompletionPolicy(.retry, handler: handler)
                }
                /// Never prepares a completion again on its own and notifies no one. Every completion that
                /// needs reconciliation, including one whose preparation lost a race with another commit,
                /// stays visible through `pendingCompletions()` and `pendingCompletionUpdates()`.
                \(access)static var manual: CompletionPolicy { CompletionPolicy(.manual, handler: { _ in }) }
                /// Never prepares a completion again on its own. Every completion that needs reconciliation,
                /// including one whose preparation lost a race with another commit, is passed to `handler`.
                \(access)static func manual(onReconciliationRequired handler: @escaping \(handler)) -> CompletionPolicy {
                    CompletionPolicy(.manual, handler: handler)
                }
            }
            """
    }

    /// The runtime host arguments after `configuration`, which wire execution and delivery or, without
    /// operations, close over the uninhabited outcome.
    ///
    /// An `IsolatedHost`'s driver receives its owning actor, isolated, and passes it to each operation's driver.
    /// `isolation` is the attribute of the host's driver type, which its execution of one operation repeats.
    /// An `IsolatedHost`'s execution captures the isolated actor, so it runs isolated to it.
    private func managedHooks(owner: Bool = false, isolation: String = "@Sendable") -> String {
        guard hasOperations else {
            // Without operations, every effect is an event, and no driver can be asked to run one.
            let driver =
                hasEvents
                ? "{ \(owner ? "_, " : "")_ in Swift::preconditionFailure(\"A schema without operations starts no work.\") }"
                : "{ \(owner ? "_, " : "")raw in switch raw.descriptor {} }"
            return """
                driver: \(driver),
                ticket: { (outcome: Swift::Never) -> StateMachine::RuntimeTicket in },
                prepare: { attempt in switch attempt.outcome {} }\(emitHook(owner: owner))
                """
        }
        return """
            policy: completionPolicy.runtime, driver: { \(owner ? "owner, " : "")raw in
                let execution: \(owner ? "" : isolation + " ")() async -> Completion
                switch raw.descriptor { \(managedExecutions(owner: owner)) }
                return await execution()
            }, ticket: { (outcome: Completion) -> StateMachine::RuntimeTicket in outcome.authority },
            prepare: { _stateMachineDeliveryPreparation($0) },
            reconciliationRequired: completionPolicy.reconciliationRequired\(emitHook(owner: owner))
            """
    }

    /// The pending-completion members of a managed owner.
    ///
    /// A managed owner offers no `deliver` because no caller holds its work.
    private func managedPending(
        asynchronous: String,
        awaiting: String,
        delivery: String,
        updates: String,
        projected: String,
        projectionIsolation: String,
        projectionPlace: String
    ) -> String {
        guard hasOperations else { return "" }
        let confined = updates != projected
        return """
            /// Reads immutable retained first-outcome diagnostics.
            \(access)func pendingCompletions()\(asynchronous) -> [PendingCompletion] { \(awaiting)host.pendingCompletions().map(PendingCompletion.init) }
            /// Registers a \(sequenceTerms(confined ? .mainActorStream : .transferable).sequence) of the retained completions, each element the whole collection, taking a subscriber slot when called.
            ///
            /// The first element is the collection current at registration, and each later element is the
            /// collection after a change, in the order of those changes. A newer collection replaces one
            /// not yet read. Closing delivers a final, empty collection, and it then ends. It also ends
            /// when this owner is released, when its `\(sequenceTerms(confined ? .mainActorStream : .transferable).cancel)` is called, or when a read finds its
            /// task cancelled. A consumer that keeps it after it stops reading
            /// \(sequenceTerms(confined ? .mainActorStream : .transferable).ending.0)
            /// \(sequenceTerms(confined ? .mainActorStream : .transferable).ending.1)
            \(access)func pendingCompletionUpdates()\(asynchronous) throws(SubscriptionFailure) -> PendingCompletionUpdates {
                try \(awaiting)host.\(updates) { $0.map(PendingCompletion.init) }
            }
            /// Registers a single-pass sequence of `Sendable` projections of the retained completions, taking a subscriber slot when called.
            ///
            /// `transform` runs \(projectionPlace) with the whole collection after each change, starting with
            /// the collection current at registration. The sequence supports every `AsyncSequence` operator
            /// on every supported OS version, and ends after the projection of the final, empty collection.
            \(access)func pendingCompletionUpdates<Projection: Swift::Sendable>(
                _ transform: @escaping \(projectionIsolation) ([PendingCompletion]) -> Projection
            )\(asynchronous) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
                try \(awaiting)host.\(projected) { transform($0.map(PendingCompletion.init)) }
            }
            /// Explicitly claims a fresh preparation attempt for a retained outcome.
            \(access)func reconcile(id: PendingCompletionID)\(asynchronous) -> ReconcileResult {
                Self.reconciled(\(awaiting)host.reconcileReportingRefusal(id: id.raw))
            }
            /// Revokes retained delivery with an authority-only admission.
            ///
            /// The operation's work already returned the outcome it settles, so the commit issues no
            /// cancellation for it. By contrast, a reset or closure cancels every ticket it revokes.
            \(access)func discardPending(id: PendingCompletionID)\(asynchronous) -> DiscardResult { Self.discarded(\(awaiting)host.discardPending(id: id.raw)) }
            // The raw host reports only the cases each operation can produce; the rest cannot occur.
            private static func reconciled(_ result: (delivery: \(delivery), refusal: Host.Refusal?)) -> ReconcileResult {
                if let refusal = result.refusal, case .pending(let id, .reconciliationRequired) = result.delivery {
                    return _stateMachineRefused(id, refusal.failure, on: refusal.snapshot)
                }
                switch result.delivery {
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

    /// The Combine members of a `MainActorHost`, `ActorHost`, or `Shared` owner.
    ///
    /// A Combine pipeline can move each value to another thread, so every publisher's output is
    /// `Sendable`. Projected publishers are available in all modes, and whole-snapshot publishers
    /// are available only in `shared` mode.
    private func publisherMembers(
        asynchronous: String,
        awaiting: String,
        projectionIsolation: String,
        projectionPlace: String
    ) -> String {
        let lifetime = """
            /// The publisher takes a subscriber slot when it is created and frees it before its subscription's
            /// cancellation returns, from any thread, or when an unsubscribed publisher is released. It keeps
            /// the latest value until demand allows and finishes after the closed snapshot. A unit of demand
            /// reaches the newest value this owner had handed over when the publisher claimed it, or a newer
            /// one. When this owner is released without closing, it finishes at once and discards every
            /// ordinary value it has not yet delivered, so demand made after the release receives only the
            /// completion.
            """
        let whole =
            schema.mode == .shared
            ? """
            /// Registers a Combine publisher of complete snapshots, delivered on the main actor, taking a subscriber
            /// slot when called, before anything subscribes.
            ///
            \(lifetime)
            @Swift::MainActor \(access)func snapshotPublisher()\(asynchronous) throws(SubscriptionFailure) -> StateMachine::SnapshotPublisher<Snapshot> {
                try \(awaiting)host.snapshotPublisher { _stateMachineSnapshot($0) }
            }
            """ : ""
        return """
            #if canImport(Combine)
            \(whole)
            /// Registers a Combine publisher of `Sendable` projections of complete snapshots, delivered on
            /// the main actor, taking a subscriber slot when called, before anything subscribes.
            ///
            /// `transform` runs \(projectionPlace) when a snapshot is delivered.
            \(lifetime)
            @Swift::MainActor \(access)func snapshotPublisher<Projection: Swift::Sendable>(
                _ transform: @escaping \(projectionIsolation) (Snapshot) -> Projection
            )\(asynchronous) throws(SubscriptionFailure) -> StateMachine::SnapshotPublisher<Projection> {
                try \(awaiting)host.snapshotPublisher { transform(_stateMachineSnapshot($0)) }
            }
            #endif
            """
    }

    /// The flush and shutdown members every managed owner shares.
    ///
    /// `isolation` is an `IsolatedHost`'s owning-actor parameter, appended to each signature.
    private func lifetimeMembers(isolation: String = "") -> String {
        let flush =
            hasOperations
            ? "/// Waits until cancellation and launch decisions through this owner's receipt have been processed\(hasEvents ? ", and every event handler they call has returned" : "")."
            : "/// Waits until this owner has offered every snapshot through its receipt to its subscriptions\(hasEvents ? ", and every event handler they call has returned" : "")."
        let obligations =
            hasOperations
            ? "every execution, delivery, and preparation obligation settles" : "every accepted batch is processed"
        return """
            \(flush)
            \(access)func flush(through receipt: Receipt\(isolation.isEmpty ? "" : ", " + isolation)) async -> FlushResult {
                await host.flush(through: receipt.snapshot.record\(isolation.isEmpty ? "" : ", isolation: isolation")) ? .processed : .foreignOwner
            }
            /// Closes admission, then waits until \(obligations).
            ///
            /// With a `deadline`, this method stops waiting once the deadline passes and reports what was
            /// still outstanding at that moment, leaving the owner closed and that work tracked. Without a
            /// deadline, it always returns `.quiescent`.
            @discardableResult
            \(access)func shutdown(deadline: Swift::ContinuousClock.Instant? = nil\(isolation.isEmpty ? "" : ", " + isolation)) async -> ShutdownResult {
                ShutdownResult(await host.shutdown(deadline: deadline\(isolation.isEmpty ? "" : ", isolation: isolation")))
            }
            """
    }

    func managed(mainActor: Bool) -> String {
        let facade = mainActor ? "MainActorHost" : "ActorHost"
        let runtime = mainActor ? "StateMachine::RuntimeMainActorHost" : "StateMachine::RuntimeActorHost"
        let drivers = mainActor ? "MainActorDrivers" : "Drivers"
        let isolation = mainActor ? "@Swift::MainActor" : "@Sendable"
        let asynchronous = mainActor ? "" : " async"
        let awaiting = mainActor ? "" : "await "
        let token = mainActor ? "MainActorSubscription" : "Subscription"
        let fields = schema.operations
            .map {
                "/// Executes this operation within the selected isolation.\n\(access)let \($0.effect): \(driverType($0, isolation: "@Swift::MainActor"))"
            }
            .joined(separator: "\n")
        let params = schema.operations
            .map { "\($0.effect): @escaping \(driverType($0, isolation: "@Swift::MainActor"))" }
            .joined(separator: ", ")
        let assignments = schema.operations.map { "self.\($0.effect) = \($0.effect)" }.joined(separator: "\n")
        let driverDeclaration =
            mainActor && hasOperations
            ? """
            /// Immutable operation selections whose non-`Sendable` values stay on `MainActor`.
            @Swift::MainActor \(access)struct MainActorDrivers {
                \(fields)
                /// Selects every driver for this owner's lifetime.
                \(access)init(\(params)) { \(assignments) }
            }
            """ : ""
        let confined = mainActor && schema.mode != .shared
        let projectionIsolation = mainActor ? "@Swift::MainActor" : "@Sendable"
        let projected = mainActor ? "sendableSnapshots" : "snapshots"
        let distinct = mainActor ? "distinctSendableSnapshots" : "distinctSnapshots"
        let projectionPlace = mainActor ? "on the main actor" : "in this owner's actor turn"
        let projection = """
            /// Registers a single-pass sequence of the latest `Sendable` projections of complete snapshots, taking a subscriber slot when called.
            ///
            /// `transform` runs \(projectionPlace) when a snapshot is delivered, and the sequence offers each
            /// projection, equal to the one before it or not. It supports every `AsyncSequence` operator on
            /// every supported OS version. `distinctSnapshots(_:)` omits repeated values instead.
            \(access)func snapshots<Projection: Swift::Sendable>(
                _ transform: @escaping \(projectionIsolation) (Snapshot) -> Projection
            )\(asynchronous) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
                try \(awaiting)host.\(projected) { transform(_stateMachineSnapshot($0)) }
            }
            /// Registers a single-pass sequence of the latest `Equatable` projections of complete snapshots,
            /// omitting each projection equal to the one before it, taking a subscriber slot when called.
            ///
            /// `transform` and the comparison run \(projectionPlace), outside every lock. A closed snapshot
            /// whose projection is unchanged is omitted too, and the sequence then ends.
            \(access)func distinctSnapshots<Projection: Swift::Sendable & Swift::Equatable>(
                _ transform: @escaping \(projectionIsolation) (Snapshot) -> Projection
            )\(asynchronous) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
                try \(awaiting)host.\(distinct) { transform(_stateMachineSnapshot($0)) }
            }
            """
        let publisher = publisherMembers(
            asynchronous: asynchronous,
            awaiting: awaiting,
            projectionIsolation: projectionIsolation,
            projectionPlace: projectionPlace
        )
        func construction(model: String, scopes: String) -> String {
            """
            host = Host(\(model), scopes: \(scopes), configuration: configuration,
                        \(managedHooks(isolation: isolation))\(mainActor ? "" : ", isolatedTo: isolatedTo"))
            """
        }
        let restoring = schema.restoration.map { validator in
            """

                \(restoringDocumentation)
                \(deprecated(schema.restoration?.deprecation))\(access)init(restoring saved: \(validator.archiveParameter), \(managedParameters(drivers: drivers, isolation: isolation, executor: !mainActor)))\(restorationThrows) {
                    \(restoredRoot)
                    \(construction(model: "restored.model", scopes: "restored.scopes"))
                }
            """
        }
        let summary =
            mainActor
            ? """
            /// A sealed sole-writer `MainActor` owner with managed execution.
            ///
            /// On iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, and Mac Catalyst 17.0 and
            /// later, this owner conforms to `Observable` so a SwiftUI view can read it directly. Each
            /// tracked member registers a read of its own value only, covering \(hasOperations ? "`currentSnapshot` and `snapshot()`, `runningCount`,\n/// `subscriberCount`, and `pendingCompletions()`" : "`currentSnapshot` and `snapshot()`, and `subscriberCount`").
            """
            : """
            /// A sealed sole-writer native actor owner with managed execution.
            """
        let executorNote =
            mainActor
            ? ""
            : """

            ///
            /// With `isolatedTo`, the owner's actor runs on that actor's serial executor so their turns
            /// never overlap, though calls into the owner still await.
            """
        return """
            \(driverDeclaration)
            \(summary)
            \(mainActor ? "@Swift::MainActor " : "")\(access)final class \(facade): \(mainActor ? "StateMachine::ObservableMainActorHost, StateMachine::MainActorStateMachineHost" : "Swift::Sendable, StateMachine::ActorStateMachineHost") {
                private typealias Host = \(runtime)<\(name), Effect, \(outcome), PreparationRejection>
                private let host: Host\(completionPolicy(isolation: isolation, sendable: !mainActor))
                /// Creates fresh authority\(hasOperations ? " and immutable execution selections" : "").\(handlerNote(isolation: mainActor ? "the main actor" : "this owner's actor"))\(executorNote)
                \(access)init(_ initial: \(initialType)\(initialDefault), \(managedParameters(drivers: drivers, isolation: isolation, executor: !mainActor))) {
                    \(construction(model: ".\(schema.initial)(initial)", scopes: "[\(initialScopes)]"))
                }\(restoring ?? "")\(closureInitializers(drivers: drivers, isolation: isolation, executor: !mainActor))
                /// Captures a complete historical observation\(mainActor ? ". Reading it registers a snapshot read with Observation" : "").
                \(access)func snapshot()\(asynchronous) -> Snapshot { _stateMachineSnapshot(\(awaiting)host.snapshot()) }
                \(mainActor ? """
                /// The current complete snapshot. Reading it registers a snapshot read with Observation.
                \(access)var currentSnapshot: Snapshot { _stateMachineSnapshot(host.snapshot()) }
                """ : "")
                /// Routes, prepares, and admits one input in a single isolated turn without suspension.
                @discardableResult
                \(access)func send(_ input: Input)\(asynchronous) throws(SendRejection) -> Receipt {
                    \(sendBody("""
                    let result = \(awaiting)host.prepareAndCommit { raw -> Swift::Result<_StateMachineEngine.Candidate, SendRejection> in
                        let prepared: Prepared
                        do throws(PreparationRejection) {
                            prepared = try \(schemaReference).prepare(input, on: _stateMachineSnapshot(raw))
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
                    """))
                }
                /// Consumes an explicitly prepared historical candidate, rechecking freshness.
                \(access)func commit(_ prepared: consuming Prepared)\(asynchronous) -> CommitResult {
                    switch prepared.candidate {
                    case .candidate(let candidate): return _stateMachineAdmission(\(awaiting)host.commit(candidate))
                    case .defective(let defect): return _stateMachineAdmission(\(awaiting)host.reject(defect))
                    }
                }
                /// Subscribes to initial, accepted, and terminal complete snapshots, taking a subscriber slot when called.
                \(access)func subscribe(_ receive: @escaping \(isolation) (Snapshot) -> Swift::Void,
                    onFinish: @escaping \(isolation) () -> Swift::Void = {})\(asynchronous) throws(SubscriptionFailure) -> \(token) {
                    try \(awaiting)host.subscribe({ receive(_stateMachineSnapshot($0)) }, onFinish: onFinish)
                }
                /// Registers a \(sequenceTerms(confined ? .mainActorStream : .transferable).sequence) of the latest complete snapshots, taking a subscriber slot when called.
                ///
                /// It ends after the closed snapshot, when this owner is released, when its `\(sequenceTerms(confined ? .mainActorStream : .transferable).cancel)` is
                /// called, or when a read finds its task cancelled. A consumer that keeps it after it stops reading
                /// \(sequenceTerms(confined ? .mainActorStream : .transferable).ending.0)
                /// \(sequenceTerms(confined ? .mainActorStream : .transferable).ending.1)
                \(access)func snapshots()\(asynchronous) throws(SubscriptionFailure) -> \(confined ? "MainActorSnapshots" : "Snapshots") {
                    try \(awaiting)host.\(mainActor && !confined ? "sendableSnapshots" : "snapshots") { _stateMachineSnapshot($0) }
                }
                \(projection)
                \(publisher)
                \(managedPending(asynchronous: asynchronous, awaiting: awaiting, delivery: "StateMachine::RuntimeHostDelivery<\(name), Effect>", updates: mainActor && !confined ? "sendablePendingCompletionUpdates" : "pendingCompletionUpdates", projected: mainActor ? "sendablePendingCompletionUpdates" : "pendingCompletionUpdates", projectionIsolation: projectionIsolation, projectionPlace: projectionPlace))
                /// Closes admission while preserving historical model data.
                @discardableResult
                \(access)func close()\(asynchronous) -> Receipt { Receipt(\(awaiting)host.close()) }
                \(resetMembers(mutating: false, asynchronous: asynchronous, reset: { "\(awaiting)host.reset(\($0), scopes: \($1)\($2))" }))
                \(lifetimeMembers())
                \(hasOperations ? "/// Actual workers whose joined termination has not yet been processed." : "")
                \(hasOperations ? "\(access)var runningCount: Swift::Int { \(mainActor ? "host.runningCount" : "get async { await host.runningCount }") }" : "")
                /// The count of live observer registrations\(mainActor ? ". Reading it registers a count read with Observation" : "").
                \(access)var subscriberCount: Swift::Int { \(mainActor ? "host.subscriberCount" : "get async { await host.subscriberCount }") }
                /// Whether closure and all managed obligations have settled.
                \(access)var isQuiescent: Swift::Bool { \(mainActor ? "host.isQuiescent" : "get async { await host.isQuiescent }") }
            }
            """
    }

    /// The managed owner confined to one actor instance that its creator chooses.
    ///
    /// Every method takes the owning actor as a defaulted `isolated` parameter, so a call inside the
    /// actor reads `host.send(input)`, and a call from any other isolation does not compile.
    func isolatedHost() -> String {
        let isolation = "isolation: isolated Owner = #isolation"
        let sharedMode = schema.mode == .shared
        let snapshots = sharedMode ? "Snapshots" : "IsolatedSnapshots"
        let updates = sharedMode ? "PendingCompletionUpdates" : "IsolatedPendingCompletionUpdates"
        let fields = schema.operations
            .map {
                "/// Executes this operation on the owning actor, which it receives isolated.\n\(access)let \($0.effect): \(driverType($0, isolation: "@Sendable", owner: true))"
            }
            .joined(separator: "\n")
        let params = schema.operations
            .map { "\($0.effect): @escaping \(driverType($0, isolation: "@Sendable", owner: true))" }
            .joined(separator: ", ")
        let assignments = schema.operations.map { "self.\($0.effect) = \($0.effect)" }.joined(separator: "\n")
        let driverDeclaration =
            hasOperations
            ? """
            /// Immutable operation selections, each run on the owning actor, which it receives isolated.
            ///
            /// A driver reaches the actor's state through that parameter, so it captures nothing confined.
            \(access)struct Drivers: Swift::Sendable {
                \(fields)
                /// Selects every driver for this owner's lifetime.
                \(access)init(\(params)) { \(assignments) }
            }
            """ : ""
        func construction(model: String, scopes: String) -> String {
            """
            host = Host(\(model), scopes: \(scopes), isolation: isolation, configuration: configuration,
                        \(managedHooks(owner: true)))
            """
        }
        let restoring = schema.restoration.map { validator in
            """

                \(restoringDocumentation)
                \(deprecated(schema.restoration?.deprecation))\(access)init(restoring saved: \(validator.archiveParameter), \(managedParameters(drivers: "Drivers", isolation: "", owner: true)))\(restorationThrows) {
                    \(restoredRoot)
                    \(construction(model: "restored.model", scopes: "restored.scopes"))
                }
            """
        }
        let pending =
            hasOperations
            ? """
            /// Reads immutable retained first-outcome diagnostics.
            \(access)func pendingCompletions(\(isolation)) -> [PendingCompletion] {
                host.pendingCompletions(isolation: isolation).map(PendingCompletion.init)
            }
            /// Registers a \(sequenceTerms(sharedMode ? .transferable : .isolatedStream).sequence) of the retained completions, each element the whole collection, taking a subscriber slot when called.
            ///
            /// The first element is the collection current at registration, and each later element is the
            /// collection after a change, in the order of those changes. A newer collection replaces one
            /// not yet read. Closing delivers a final, empty collection, and it then ends. It also ends
            /// when this owner is released, when its `\(sequenceTerms(sharedMode ? .transferable : .isolatedStream).cancel)` is called, or when a read finds its
            /// task cancelled. A consumer that keeps it after it stops reading
            /// \(sequenceTerms(sharedMode ? .transferable : .isolatedStream).ending.0)
            /// \(sequenceTerms(sharedMode ? .transferable : .isolatedStream).ending.1)
            \(access)func pendingCompletionUpdates(\(isolation)) throws(SubscriptionFailure) -> \(updates) {
                try host.\(sharedMode ? "sendablePendingCompletionUpdates" : "pendingCompletionUpdates")({ $0.map(PendingCompletion.init) }, isolation: isolation)
            }
            /// Registers a single-pass sequence of `Sendable` projections of the retained completions, taking a subscriber slot when called.
            ///
            /// `transform` runs on the owning actor with the whole collection after each change, starting
            /// with the collection current at registration. The sequence supports every `AsyncSequence`
            /// operator, may be consumed anywhere, and ends after the projection of the final, empty collection.
            \(access)func pendingCompletionUpdates<Projection: Swift::Sendable>(
                _ transform: @escaping ([PendingCompletion]) -> Projection, \(isolation)
            ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
                try host.sendablePendingCompletionUpdates({ transform($0.map(PendingCompletion.init)) }, isolation: isolation)
            }
            /// Explicitly claims a fresh preparation attempt for a retained outcome.
            \(access)func reconcile(id: PendingCompletionID, \(isolation)) -> ReconcileResult {
                Self.reconciled(host.reconcileReportingRefusal(id: id.raw, isolation: isolation))
            }
            /// Revokes retained delivery with an authority-only admission.
            ///
            /// The operation's work already returned the outcome it settles, so the commit issues no
            /// cancellation for it. By contrast, a reset or closure cancels every ticket it revokes.
            \(access)func discardPending(id: PendingCompletionID, \(isolation)) -> DiscardResult {
                Self.discarded(host.discardPending(id: id.raw, isolation: isolation))
            }
            // The raw host reports only the cases each operation can produce; the rest cannot occur.
            private static func reconciled(_ result: (delivery: StateMachine::RuntimeHostDelivery<\(name), Effect>, refusal: Host.Refusal?)) -> ReconcileResult {
                if let refusal = result.refusal, case .pending(let id, .reconciliationRequired) = result.delivery {
                    return _stateMachineRefused(id, refusal.failure, on: refusal.snapshot)
                }
                switch result.delivery {
                case .committed(let record): return .committed(Receipt(record))
                case .pending(let id, let status): return .pending(PendingCompletionID(raw: id), status)
                case .inProgress: return .inProgress
                default: return .notPending
                }
            }
            private static func discarded(_ result: StateMachine::RuntimeHostDelivery<\(name), Effect>) -> DiscardResult {
                switch result {
                case .discarded(let record): return .discarded(Receipt(record))
                case .rejected(let reason): return .rejected(reason)
                default: return .notPending
                }
            }
            """ : ""
        let receivers = (hasOperations ? ["Drivers"] : []) + (hasEvents ? ["event handlers"] : [])
        let callbacks = "observation callbacks" + (hasOperations ? " and the completion policy's handler" : "")
        let callbacksNote =
            receivers.isEmpty
            ? """
            /// Its \(callbacks) run on the owning actor.
            """
            : """
            /// \(receivers.joined(separator: " and ")) run on the owning actor and receive it isolated, so they can read and
            /// change its state without capturing the actor.
            /// Its \(callbacks) run there too.
            """
        let lifetimeNote =
            hasOperations
            ? """
            /// The host holds its actor weakly, so an idle actor that stores it is released with it. A running
            /// driver retains the actor while it runs on it. Calling `close()` or `shutdown()` requests
            /// cancellation of running drivers, and the actor is released after each driver returns. A closure
            /// that captures the actor keeps it alive while the host or registration holding the closure lasts,
            /// so a driver or handler, which the host holds for its lifetime, should use the actor it receives
            /// instead.
            """
            : """
            /// The host holds its actor weakly, so an idle actor that stores it is released with it. A closure
            /// that captures the actor keeps it alive while the host or registration holding the closure lasts,
            /// so a handler, which the host holds for its lifetime, should use the actor it receives instead.
            """
        return """
            /// A sealed sole-writer owner confined to one actor instance, with managed execution.
            ///
            /// Create it on the actor that owns it, as `IsolatedHost(isolation: self, …)`, and keep it there.
            /// It is not `Sendable`, so the compiler keeps it in that actor's region, and every method takes
            /// the actor as a defaulted `isolated` parameter. Inside the actor, calls read `host.send(input)`,
            /// while calls from another actor or a nonisolated context do not compile. A method that receives
            /// a different instance of the actor's type stops the program.
            ///
            \(callbacksNote)
            ///
            \(lifetimeNote)
            \(access)final class IsolatedHost<Owner: Swift::Actor>: StateMachine::IsolatedStateMachineHost {
                private typealias Host = StateMachine::RuntimeIsolatedHost<Owner, \(name), Effect, \(outcome), PreparationRejection>
                private let host: Host
                \(driverDeclaration)\(completionPolicy(isolation: "", sendable: false))
                /// Creates fresh authority confined to `isolation`\(hasOperations ? ", with immutable execution selections" : "").\(handlerNote(isolation: "the owning actor, which it receives isolated"))
                \(access)init(_ initial: \(initialType)\(initialDefault), \(managedParameters(drivers: "Drivers", isolation: "", owner: true))) {
                    \(construction(model: ".\(schema.initial)(initial)", scopes: "[\(initialScopes)]"))
                }\(restoring ?? "")\(closureInitializers(drivers: "Drivers", isolation: "", owner: true))
                /// Captures a complete historical observation.
                \(access)func snapshot(\(isolation)) -> Snapshot { _stateMachineSnapshot(host.snapshot(isolation: isolation)) }
                /// Routes, prepares, and admits one input in a single turn of the owning actor, without suspension.
                @discardableResult
                \(access)func send(_ input: Input, \(isolation)) throws(SendRejection) -> Receipt {
                    \(sendBody("""
                    let result = host.prepareAndCommit(isolation: isolation) { raw -> Swift::Result<_StateMachineEngine.Candidate, SendRejection> in
                        let prepared: Prepared
                        do throws(PreparationRejection) {
                            prepared = try \(schemaReference).prepare(input, on: _stateMachineSnapshot(raw))
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
                    """))
                }
                /// Consumes an explicitly prepared historical candidate, rechecking freshness.
                \(access)func commit(_ prepared: consuming Prepared, \(isolation)) -> CommitResult {
                    switch prepared.candidate {
                    case .candidate(let candidate): return _stateMachineAdmission(host.commit(candidate, isolation: isolation))
                    case .defective(let defect): return _stateMachineAdmission(host.reject(defect, isolation: isolation))
                    }
                }
                /// Subscribes to initial, accepted, and terminal complete snapshots, delivered on the owning actor, taking a subscriber slot when called.
                ///
                /// The registration stays in the owning actor's region, and only that actor can cancel it, which
                /// removes the registration before returning, so none of its callbacks begins afterward. Cancelling
                /// releases the callbacks before it returns, except while this owner is delivering a change, such
                /// as when another observer's callback cancels. That delivery keeps the callbacks it selected until
                /// it finishes delivering the change to its other observers, and releases them then. Dropping the
                /// registration stops delivery and frees its slot at once, and this owner releases its callbacks
                /// when it next sweeps its registrations or is destroyed.
                \(access)func subscribe(_ receive: @escaping (Snapshot) -> Swift::Void,
                    onFinish: @escaping () -> Swift::Void = {}, \(isolation)) throws(SubscriptionFailure) -> IsolatedSubscription<Owner> {
                    try host.subscribe({ receive(_stateMachineSnapshot($0)) }, onFinish: onFinish, isolation: isolation)
                }
                /// Registers a \(sequenceTerms(sharedMode ? .transferable : .isolatedStream).sequence) of the latest complete snapshots, taking a subscriber slot when called.
                ///
                /// It ends after the closed snapshot, when this owner is released, when its `\(sequenceTerms(sharedMode ? .transferable : .isolatedStream).cancel)` is
                /// called, or when a read finds its task cancelled. A consumer that keeps it after it stops reading
                /// \(sequenceTerms(sharedMode ? .transferable : .isolatedStream).ending.0)
                /// \(sequenceTerms(sharedMode ? .transferable : .isolatedStream).ending.1)
                \(access)func snapshots(\(isolation)) throws(SubscriptionFailure) -> \(snapshots) {
                    try host.\(sharedMode ? "sendableSnapshots" : "snapshots")({ _stateMachineSnapshot($0) }, isolation: isolation)
                }
                /// Registers a single-pass sequence of the latest `Sendable` projections of complete snapshots, taking a subscriber slot when called.
                ///
                /// `transform` runs on the owning actor when a snapshot is delivered, and the sequence offers
                /// each projection, equal to the one before it or not. It supports every `AsyncSequence`
                /// operator and may be consumed anywhere. `distinctSnapshots(_:)` omits repeated values instead.
                /// Ending it on another actor stops delivery and frees its slot at once, and this owner releases
                /// `transform` when it next sweeps its registrations or is destroyed.
                \(access)func snapshots<Projection: Swift::Sendable>(
                    _ transform: @escaping (Snapshot) -> Projection, \(isolation)
                ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
                    try host.sendableSnapshots({ transform(_stateMachineSnapshot($0)) }, isolation: isolation)
                }
                /// Registers a single-pass sequence of the latest `Equatable` projections of complete snapshots,
                /// omitting each projection equal to the one before it, taking a subscriber slot when called.
                ///
                /// `transform` and the comparison run on the owning actor. A closed snapshot whose projection
                /// is unchanged is omitted too, and the sequence then ends.
                \(access)func distinctSnapshots<Projection: Swift::Sendable & Swift::Equatable>(
                    _ transform: @escaping (Snapshot) -> Projection, \(isolation)
                ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
                    try host.distinctSendableSnapshots({ transform(_stateMachineSnapshot($0)) }, isolation: isolation)
                }
                \(pending)
                /// Closes admission while preserving historical model data.
                @discardableResult
                \(access)func close(\(isolation)) -> Receipt { Receipt(host.close(isolation: isolation)) }
                \(resetMembers(mutating: false, asynchronous: "", isolation: isolation, reset: { "host.reset(\($0), scopes: \($1)\($2), isolation: isolation)" }))
                \(lifetimeMembers(isolation: isolation))
                \(hasOperations ? "/// Actual workers whose joined termination has not yet been processed, read on the owning actor." : "")
                \(hasOperations ? "\(access)func runningCount(\(isolation)) -> Swift::Int { host.runningCount(isolation: isolation) }" : "")
                /// Live observer registrations, read on the owning actor.
                \(access)func subscriberCount(\(isolation)) -> Swift::Int { host.subscriberCount(isolation: isolation) }
                /// Whether closure and all managed obligations have settled, read on the owning actor.
                \(access)func isQuiescent(\(isolation)) -> Swift::Bool { host.isQuiescent(isolation: isolation) }
            }
            """
    }

    /// The `Sendable` driver selection that `Shared` and `ActorHost` share.
    func drivers() -> String {
        let fields = schema.operations
            .map {
                "/// Executes one typed operation outside admission locks.\n\(access)let \($0.effect): \(driverType($0, isolation: "@Sendable"))"
            }
            .joined(separator: "\n")
        let params = schema.operations
            .map { "\($0.effect): @escaping \(driverType($0, isolation: "@Sendable"))" }
            .joined(separator: ", ")
        let assignments = schema.operations.map { "self.\($0.effect) = \($0.effect)" }.joined(separator: "\n")
        return """
            /// Immutable typed execution selection for one managed owner's lifetime.
            \(access)struct Drivers: Swift::Sendable {
                \(fields)
                /// Selects all drivers for this owner.
                \(access)init(\(params)) { \(assignments) }
            }
            """
    }

    func shared() -> String {
        let raw = "StateMachine::RuntimeSharedHost<\(name), Effect, \(outcome), PreparationRejection>"
        func construction(model: String, scopes: String) -> String {
            """
            host = Host(\(model), scopes: \(scopes), limits: configuration.limits, subscriberCapacity: configuration.subscriberCapacity,
                        \(managedHooks()))
            """
        }
        let restoring = schema.restoration.map { validator in
            """

                \(restoringDocumentation)
                \(deprecated(schema.restoration?.deprecation))\(access)init(restoring saved: \(validator.archiveParameter), \(managedParameters(drivers: "Drivers", isolation: "@Sendable")))\(restorationThrows) {
                    \(restoredRoot)
                    \(construction(model: "restored.model", scopes: "restored.scopes"))
                }
            """
        }
        return """
            /// A synchronous shared owner with managed physical execution and terminal delivery.
            \(access)final class Shared: Swift::Sendable, StateMachine::SharedStateMachineHost {
                private typealias Host = \(raw)
                private let host: Host\(completionPolicy(isolation: "@Sendable", sendable: true))
                /// Creates fresh initial authority\(hasOperations ? " and retains the driver selection immutably" : "").\(handlerNote(isolation: nil))
                \(access)init(_ initial: \(initialType)\(initialDefault), \(managedParameters(drivers: "Drivers", isolation: "@Sendable"))) {
                    \(construction(model: ".\(schema.initial)(initial)", scopes: "[\(initialScopes)]"))
                }\(restoring ?? "")\(closureInitializers(drivers: "Drivers", isolation: "@Sendable"))
                /// Captures a coherent historical observation.
                \(access)func snapshot() -> Snapshot { _stateMachineSnapshot(host.snapshot()) }
                /// Registers a serial capacity-one latest-value observation callback, taking a subscriber slot when called.
                \(access)func subscribe(_ receive: @escaping @Sendable (Snapshot) -> Swift::Void,
                    onFinish: @escaping @Sendable () -> Swift::Void = {}) throws(SubscriptionFailure) -> Subscription {
                    try host.subscribe({ receive(_stateMachineSnapshot($0)) }, onFinish: onFinish)
                }
                /// Registers a \(sequenceTerms(.transferable).sequence) of the latest complete snapshots, taking a subscriber slot when called.
                ///
                /// It ends after the closed snapshot, when this owner is released, when its `\(sequenceTerms(.transferable).cancel)` is
                /// called, or when a read finds its task cancelled. A consumer that keeps it after it stops reading
                /// \(sequenceTerms(.transferable).ending.0)
                /// \(sequenceTerms(.transferable).ending.1)
                \(access)func snapshots() throws(SubscriptionFailure) -> Snapshots {
                    try host.snapshots { _stateMachineSnapshot($0) }
                }
                /// Registers a single-pass sequence of the latest `Sendable` projections of complete snapshots, taking a subscriber slot when called.
                ///
                /// `transform` runs on the registration's serial delivery path, outside every lock, and the
                /// sequence offers each projection, equal to the one before it or not. `distinctSnapshots(_:)`
                /// omits repeated values instead.
                \(access)func snapshots<Projection: Swift::Sendable>(
                    _ transform: @escaping @Sendable (Snapshot) -> Projection
                ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
                    try host.snapshots { transform(_stateMachineSnapshot($0)) }
                }
                /// Registers a single-pass sequence of the latest `Equatable` projections of complete snapshots,
                /// omitting each projection equal to the one before it, taking a subscriber slot when called.
                ///
                /// `transform` and the comparison run on the registration's serial delivery path, outside every
                /// lock. A closed snapshot whose projection is unchanged is omitted too, and the sequence then ends.
                \(access)func distinctSnapshots<Projection: Swift::Sendable & Swift::Equatable>(
                    _ transform: @escaping @Sendable (Snapshot) -> Projection
                ) throws(SubscriptionFailure) -> StateMachine::SnapshotSequence<Projection> {
                    try host.distinctSnapshots { transform(_stateMachineSnapshot($0)) }
                }
                \(publisherMembers(asynchronous: "", awaiting: "", projectionIsolation: "@Sendable", projectionPlace: "on the registration's serial delivery path, outside every lock,"))
                /// Routes, prepares, and admits one input in a single attempt.
                ///
                /// Preparation runs outside the lock against one snapshot and is never repeated, so
                /// a concurrent commit surfaces as `.commit(.conflict)` for the caller to resolve.
                @discardableResult
                \(access)func send(_ input: Input) throws(SendRejection) -> Receipt {
                    \(sendBody("""
                    let prepared: Prepared
                    do { prepared = try \(schemaReference).prepare(input, on: snapshot()) } catch { throw .preparation(error) }
                    switch commit(prepared) {
                    case .committed(let receipt): return receipt
                    case .rejected(let reason, _): throw .commit(reason)
                    }
                    """))
                }
                /// Consumes one candidate into an atomic admission attempt.
                \(access)func commit(_ prepared: consuming Prepared) -> CommitResult {
                    switch prepared.candidate {
                    case .candidate(let candidate): return _stateMachineAdmission(host.commit(candidate))
                    case .defective(let defect): return _stateMachineAdmission(host.reject(defect))
                    }
                }
                \(managedPending(asynchronous: "", awaiting: "", delivery: "\(raw).Delivery", updates: "pendingCompletionUpdates", projected: "pendingCompletionUpdates", projectionIsolation: "@Sendable", projectionPlace: "on the registration's serial delivery path, outside every lock,"))
                /// Ends admission and schedules cancellation in FIFO order.
                @discardableResult
                \(access)func close() -> Receipt { Receipt(host.close()) }
                \(resetMembers(mutating: false, asynchronous: "", reset: { "host.reset(\($0), scopes: \($1)\($2))" }))
                \(lifetimeMembers())
                \(hasOperations ? "/// Actual workers whose joined termination has not yet been processed." : "")
                \(hasOperations ? "\(access)var runningCount: Swift::Int { host.runningCount }" : "")
                /// Live observer registrations.
                \(access)var subscriberCount: Swift::Int { host.subscriberCount }
                /// Whether closure and all managed obligations have settled.
                \(access)var isQuiescent: Swift::Bool { host.isQuiescent }
            }
            """
    }

    /// The convenience initializers of a managed owner that take each operation's driver as its own parameter.
    ///
    /// Each label is the operation's effect case followed by `Driver`, so no operation name can collide with
    /// another parameter. A schema without operations has none.
    ///
    /// An `IsolatedHost` (`owner`) takes and forwards its owning actor after the initial payload, and an
    /// `ActorHost` (`executor`) the actor whose executor it shares, last.
    private func closureInitializers(
        drivers: String,
        isolation: String,
        owner: Bool = false,
        executor: Bool = false
    )
        -> String
    {
        guard !schema.operations.isEmpty else { return "" }
        let closures =
            (owner ? "isolation: isolated Owner,\n" : "")
            + schema.operations
            .map {
                "\($0.effect)Driver: @escaping \(driverType($0, isolation: owner ? "@Sendable" : isolation, owner: owner))"
            }
            .joined(separator: ",\n")
        let selection = schema.operations.map { "\($0.effect): \($0.effect)Driver" }.joined(separator: ", ")
        let handlers = eventHandlers(isolation: isolation, owner: owner).map { ",\n" + $0 } ?? ""
        let forwarded = schema.events.map { "\($0.handler): \($0.handler), " }.joined()
        let ownerArgument = owner ? "isolation: isolation, " : ""
        let executorParameter = executor ? ",\nisolatedTo: (any Swift::Actor)? = nil" : ""
        let executorArgument = executor ? ", isolatedTo: isolatedTo" : ""
        let restoring = schema.restoration.map { validator in
            """

                /// Creates fresh authority in the phase `\(validator.name)` validates from saved data, selecting one driver closure per operation.
                \(deprecated(schema.restoration?.deprecation))\(access)convenience init(restoring saved: \(validator.archiveParameter),
                    \(closures)\(handlers),
                    configuration: Configuration = .default,
                    \(completionPolicyParameter)\(executorParameter))\(restorationThrows) {
                    \(validator.failureType == nil ? "" : "try ")self.init(restoring: saved, \(ownerArgument)drivers: \(drivers)(\(selection)),
                        \(forwarded)configuration: configuration, completionPolicy: completionPolicy\(executorArgument))
                }
            """
        }
        return """

                /// Creates fresh initial authority, selecting one driver closure per operation.
                \(access)convenience init(_ initial: \(initialType)\(initialDefault),
                    \(closures)\(handlers),
                    configuration: Configuration = .default,
                    \(completionPolicyParameter)\(executorParameter)) {
                    self.init(initial, \(ownerArgument)drivers: \(drivers)(\(selection)),
                        \(forwarded)configuration: configuration, completionPolicy: completionPolicy\(executorArgument))
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
                guard schema.scopePhases(scope).contains(phase) else { return nil }
                return "_StateMachineScopeID(kind: \(i))"
            }
            .joined(separator: ", ")
    }

    /// The managed driver cases shared by all managed facades, each selecting the execution of its operation.
    ///
    /// The driver awaits only the execution it selects. One async closure that awaited each operation's
    /// driver in its own case would carry every case's temporaries through each suspension, causing the
    /// compiled closure to grow with the square of the operations.
    private func managedExecutions(owner: Bool) -> String {
        let starts = schema.operations
            .map { op in
                let arguments =
                    ((owner ? ["owner"] : []) + (op.isKeyed ? ["key"] : []) + (op.takesInput ? ["input"] : []))
                    .joined(separator: ", ")
                let request = op.hasRequest ? " request: \(requestConstruction(op))," : ""
                return """
                    case .\(op.effect)\(requestBindings(op)):
                        execution = { .\(op.effect)(\(op.name)Completion(\(op.isInfallible ? "value" : "result"): await drivers.\(op.effect)(\(arguments)),\(request) authority: raw.ticket)) }
                    """
            }
        // An event is never started. Admission publishes it instead and applies any cancellations.
        let unstarted =
            schema.events.map { ".\($0.effect)" }
            + schema.cancelledOperations.flatMap { [".\($0.cancelEffect)", ".\($0.cancelAllEffect)"] }
        let events =
            unstarted.isEmpty
            ? []
            : [
                "case \(unstarted.joined(separator: ", ")): Swift::preconditionFailure(\"Only an operation is started.\")"
            ]
        return (starts + events).joined(separator: "\n")
    }

}
