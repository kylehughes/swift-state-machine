import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacros

/// The lexical schema consumed by generation; semantic type relationships are compiler witnesses.
struct Schema {
    struct Phase {
        let caseName: String
        let typeName: String
    }

    struct Case {
        let caseName: String
        let payloadType: String?
    }

    struct Trigger: Hashable {
        let kind: String
        let name: String
    }

    struct Operation {
        let name: String
        let effect: String
        let scope: String
        let requires: [String]
        let activeIn: [String]
        let admission: String
        let maxNewIntents: Int
        let inputType: String
        let outputType: String
        let failureType: String
    }

    struct Transition {
        let name: String
        let from: String
        let to: String
        let trigger: Trigger
        let invalidates: [String]
        let starts: [String]
        let payloadType: String?
        let sourceType: String
        let returnType: String
        let failureType: String?
    }

    struct Route {
        let name: String
        let from: String
        let trigger: Trigger
        let sourceType: String
        let payloadType: String?
    }

    let name: String
    let access: String
    let mode: String
    let initial: String
    let scopes: [String]
    let phases: [Phase]
    let inputs: [Case]
    let effects: [Case]
    let operations: [Operation]
    let transitions: [Transition]
    let routes: [Route]

    static func parse(
        _ declaration: EnumDeclSyntax,
        attribute: AttributeSyntax,
        context: some MacroExpansionContext
    ) throws -> Schema {
        let parser = SchemaParser()
        return try parser.parse(declaration, attribute: attribute)
    }
}

private struct SchemaMessage: DiagnosticMessage {
    let message: String
    var diagnosticID: MessageID { MessageID(domain: "StateMachine", id: "invalidSchema") }
    var severity: DiagnosticSeverity { .error }
}

private struct SchemaParser {
    private func reject(_ node: some SyntaxProtocol, _ message: String) throws -> Never {
        throw DiagnosticsError(diagnostics: [Diagnostic(node: node, message: SchemaMessage(message: message))])
    }

    private func identifier(_ text: String) -> Bool {
        guard !text.isEmpty, text != "_", !text.hasPrefix("`") else { return false }
        let parsed = Parser.parse(source: "enum _AtomicIdentifier { case \(text) }")
        guard !parsed.hasError, parsed.statements.count == 1,
            let declaration = parsed.statements.first?.item.as(EnumDeclSyntax.self),
            declaration.memberBlock.members.count == 1,
            let cases = declaration.memberBlock.members.first?.decl.as(EnumCaseDeclSyntax.self),
            cases.elements.count == 1, let name = cases.elements.first?.name, name.presence == .present
        else { return false }
        return name.text == text
    }

    private func literal(_ expression: ExprSyntax) throws -> String {
        guard let string = expression.as(StringLiteralExprSyntax.self), string.segments.count == 1,
            case .stringSegment(let segment) = string.segments.first,
            identifier(segment.content.text)
        else { try reject(expression, "Use an Swift identifier string without interpolation or escapes.") }
        return segment.content.text
    }

    private func list(_ expression: ExprSyntax) throws -> [String] {
        guard let array = expression.as(ArrayExprSyntax.self) else {
            try reject(expression, "Use an array of literal identifier strings.")
        }
        let values = try array.elements.map { try literal($0.expression) }
        guard Set(values).count == values.count else {
            try reject(expression, "Remove duplicate identifiers from this metadata list.")
        }
        return values
    }

    private func arguments(
        _ attribute: AttributeSyntax,
        required: Set<String>,
        optional: Set<String> = []
    ) throws
        -> [String: ExprSyntax]
    {
        guard case .argumentList(let arguments) = attribute.arguments else {
            try reject(attribute, "Provide literal labeled metadata arguments.")
        }
        var result: [String: ExprSyntax] = [:]
        for argument in arguments {
            guard let label = argument.label?.text, required.union(optional).contains(label) else {
                try reject(
                    argument,
                    "Unexpected metadata argument; supported labels are \(required.union(optional).sorted().joined(separator: ", "))."
                )
            }
            guard result.updateValue(argument.expression, forKey: label) == nil else {
                try reject(argument, "Specify '\(label)' only once.")
            }
        }
        guard required.isSubset(of: Set(result.keys)) else {
            try reject(
                attribute,
                "Missing required metadata: \(required.subtracting(result.keys).sorted().joined(separator: ", "))."
            )
        }
        return result
    }

    private func member(_ expression: ExprSyntax) throws -> String {
        guard let member = expression.as(MemberAccessExprSyntax.self), member.base == nil else {
            try reject(expression, "Use an unqualified literal enum member such as .shared.")
        }
        return member.declName.baseName.text
    }

    private func trigger(_ expression: ExprSyntax) throws -> Schema.Trigger {
        guard let call = expression.as(FunctionCallExprSyntax.self), call.arguments.count == 1,
            let argument = call.arguments.first, argument.label == nil,
            call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty
        else { try reject(expression, "Use .input(\"case\"), .success(\"effect\"), or .failure(\"effect\").") }
        let kind = try member(call.calledExpression)
        guard ["input", "success", "failure"].contains(kind) else {
            try reject(expression, "A trigger must be .input, .success, or .failure.")
        }
        return Schema.Trigger(kind: kind, name: try literal(argument.expression))
    }

    private func marker(_ attributes: AttributeListSyntax, named name: String) throws -> AttributeSyntax? {
        let matches = attributes.compactMap { $0.as(AttributeSyntax.self) }
            .filter {
                $0.attributeName.trimmedDescription == name
            }
        guard matches.count <= 1 else {
            try reject(attributes, "Apply @\(name) only once to a declaration.")
        }
        return matches.first
    }

    private func cases(_ declaration: EnumDeclSyntax, effect: Bool) throws -> [Schema.Case] {
        guard declaration.genericParameterClause == nil, declaration.genericWhereClause == nil else {
            try reject(declaration, "Input and Effect must be nongeneric closed enums.")
        }
        var result: [Schema.Case] = []
        for member in declaration.memberBlock.members {
            guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in cases.elements {
                guard identifier(element.name.text) else {
                    try reject(element, "Use an unescaped Swift case identifier.")
                }
                let parameters = element.parameterClause?.parameters
                let count = parameters?.count ?? 0
                guard element.rawValue == nil, count <= 1, !effect || count == 1 else {
                    try reject(
                        element,
                        effect
                            ? "Each Effect case requires exactly one unlabeled payload."
                            : "Each Input case accepts zero or one unlabeled payload."
                    )
                }
                if let parameter = parameters?.first {
                    guard parameter.firstName == nil || parameter.firstName?.text == "_",
                        parameter.defaultValue == nil
                    else { try reject(parameter, "Use an unlabeled payload without a default value.") }
                }
                result.append(
                    Schema.Case(caseName: element.name.text, payloadType: parameters?.first?.type.trimmedDescription)
                )
            }
        }
        guard Set(result.map(\.caseName)).count == result.count else {
            try reject(declaration, "Case names must be unique; overloaded enum cases are unsupported.")
        }
        return result
    }

    private func admission(_ expression: ExprSyntax) throws -> (expression: String, maxNewIntents: Int) {
        if let call = expression.as(FunctionCallExprSyntax.self) {
            guard try member(call.calledExpression) == "parallel", call.arguments.count == 1,
                let argument = call.arguments.first, argument.label?.text == "limit",
                let integer = argument.expression.as(IntegerLiteralExprSyntax.self),
                let limit = Int(integer.literal.text), limit > 0,
                call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty
            else {
                try reject(expression, "Use .parallel(limit: N) with a positive decimal integer representable as Int.")
            }
            return (".parallel(limit: \(limit))", limit)
        }
        let name = try member(expression)
        guard ["latest", "rejectWhenActive"].contains(name) else {
            try reject(expression, "Admission must be .latest, .rejectWhenActive, or .parallel(limit: N).")
        }
        return (".\(name)", 1)
    }

    private func validateFunction(_ function: FunctionDeclSyntax, route: Bool) throws {
        guard function.modifiers.contains(where: { $0.name.text == "static" }),
            function.genericParameterClause == nil, function.genericWhereClause == nil,
            function.signature.effectSpecifiers?.asyncSpecifier == nil,
            function.signature.parameterClause.parameters.allSatisfy({
                $0.firstName.text == "_" && $0.ellipsis == nil && $0.defaultValue == nil
            })
        else {
            try reject(
                function,
                "Use a synchronous nongeneric static function with unlabeled, nonvariadic parameters and no defaults."
            )
        }
        let effects = function.signature.effectSpecifiers
        if let throwsClause = effects?.throwsClause {
            guard !route, throwsClause.type != nil, throwsClause.throwsSpecifier.text == "throws" else {
                try reject(
                    function,
                    route ? "Routers cannot throw." : "Transitions must use typed throws(Failure), or omit throws."
                )
            }
        }
        guard function.body != nil else { try reject(function, "Provide the authored function body in the schema.") }
    }

    func parse(_ declaration: EnumDeclSyntax, attribute: AttributeSyntax) throws -> Schema {
        guard declaration.genericParameterClause == nil, declaration.genericWhereClause == nil else {
            try reject(declaration, "Generic schemas are unsupported; declare a concrete schema enum.")
        }
        guard identifier(declaration.name.text) else {
            try reject(declaration, "Use an unescaped Swift schema identifier.")
        }
        let root = try arguments(attribute, required: ["mode", "initial"], optional: ["scopes"])
        let mode = try member(root["mode"]!)
        guard ["shared", "isolated", "ownedOnly"].contains(mode) else {
            try reject(attribute, "Mode must be .shared, .isolated, or .ownedOnly.")
        }
        let initial = try literal(root["initial"]!)
        let scopes = try root["scopes"].map(list) ?? []
        let members = declaration.memberBlock.members
        for member in members {
            guard let attributed = member.decl.asProtocol(WithAttributesSyntax.self) else { continue }
            for name in ["Transition", "Route", "Operation"] {
                guard let attribute = try marker(attributed.attributes, named: name) else { continue }
                guard
                    name == "Operation" ? member.decl.is(EnumDeclSyntax.self) : member.decl.is(FunctionDeclSyntax.self)
                else {
                    try reject(
                        attribute,
                        name == "Operation"
                            ? "@Operation must mark a nested enum namespace."
                            : "@\(name) must mark a static function declared directly inside the schema."
                    )
                }
            }
        }
        var nominalNames: [String] = []
        var nestedEnums: [EnumDeclSyntax] = []
        var declaredNames: [String] = []
        for member in members {
            if let value = member.decl.as(StructDeclSyntax.self) {
                declaredNames.append(value.name.text)
                if value.genericParameterClause == nil { nominalNames.append(value.name.text) }
            } else if let value = member.decl.as(EnumDeclSyntax.self) {
                declaredNames.append(value.name.text)
                nestedEnums.append(value)
                if value.genericParameterClause == nil { nominalNames.append(value.name.text) }
            } else if let value = member.decl.as(TypeAliasDeclSyntax.self) {
                declaredNames.append(value.name.text)
            } else if let value = member.decl.as(ClassDeclSyntax.self) {
                declaredNames.append(value.name.text)
            } else if let value = member.decl.as(ActorDeclSyntax.self) {
                declaredNames.append(value.name.text)
            } else if let value = member.decl.as(FunctionDeclSyntax.self) {
                declaredNames.append(value.name.text)
            } else if let value = member.decl.as(VariableDeclSyntax.self) {
                declaredNames += value.bindings.compactMap {
                    $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
                }
            }
        }
        let rootCases = try cases(declaration, effect: true)
        let phases = try rootCases.map { value -> Schema.Phase in
            guard let type = value.payloadType, identifier(type), nominalNames.contains(type), type != "Input",
                type != "Effect"
            else {
                try reject(
                    declaration,
                    "Phase '\(value.caseName)' needs a distinct nongeneric struct or enum with an unescaped Swift name declared directly inside the schema; aliases are unsupported."
                )
            }
            return Schema.Phase(caseName: value.caseName, typeName: type)
        }
        guard !phases.isEmpty, Set(phases.map(\.typeName)).count == phases.count else {
            try reject(
                declaration,
                "Declare at least one phase, with a different nested nominal payload type for every phase."
            )
        }
        let phaseNames = Set(phases.map(\.caseName))
        guard phaseNames.contains(initial) else {
            try reject(attribute, "Initial phase '\(initial)' is not a declared phase case.")
        }
        guard let inputEnum = nestedEnums.first(where: { $0.name.text == "Input" }),
            let effectEnum = nestedEnums.first(where: { $0.name.text == "Effect" })
        else {
            try reject(
                declaration,
                "Declare closed Input and Effect enums directly inside the schema; empty enums are allowed."
            )
        }
        let inputs = try cases(inputEnum, effect: false)
        let effects = try cases(effectEnum, effect: true)
        var operations: [Schema.Operation] = []
        for namespace in nestedEnums {
            guard let attribute = try marker(namespace.attributes, named: "Operation") else { continue }
            guard identifier(namespace.name.text) else {
                try reject(namespace, "Use an unescaped Swift operation identifier.")
            }
            guard namespace.genericParameterClause == nil, namespace.genericWhereClause == nil else {
                try reject(namespace, "Operation namespaces must be nongeneric enums.")
            }
            let metadata = try arguments(
                attribute,
                required: ["effect", "scope", "activeIn", "admission"],
                optional: ["requires"]
            )
            let effect = try literal(metadata["effect"]!)
            let scope = try literal(metadata["scope"]!)
            let dependencies = try metadata["requires"].map(list) ?? []
            let activeIn = try list(metadata["activeIn"]!)
            guard effects.contains(where: { $0.caseName == effect }), scopes.contains(scope),
                Set(dependencies).isSubset(of: Set(scopes)), !dependencies.contains(scope),
                !activeIn.isEmpty, Set(activeIn).isSubset(of: phaseNames)
            else {
                try reject(
                    attribute,
                    "Operation metadata must reference a declared effect, primary scope, distinct additional scopes, and nonempty declared active phases."
                )
            }
            let aliases = namespace.memberBlock.members.compactMap { $0.decl.as(TypeAliasDeclSyntax.self) }
            guard aliases.count == 3, Set(aliases.map { $0.name.text }) == ["Input", "Output", "Failure"],
                aliases.allSatisfy({ $0.genericParameterClause == nil })
            else {
                try reject(
                    namespace,
                    "An operation declares exactly three explicit nongeneric typealiases: Input, Output, and Failure."
                )
            }
            let types = Dictionary(
                uniqueKeysWithValues: aliases.map { ($0.name.text, $0.initializer.value.trimmedDescription) }
            )
            let policy = try admission(metadata["admission"]!)
            operations.append(
                Schema.Operation(
                    name: namespace.name.text,
                    effect: effect,
                    scope: scope,
                    requires: dependencies,
                    activeIn: activeIn,
                    admission: policy.expression,
                    maxNewIntents: policy.maxNewIntents,
                    inputType: types["Input"]!,
                    outputType: types["Output"]!,
                    failureType: types["Failure"]!
                )
            )
        }
        guard operations.count == effects.count, Set(operations.map(\.effect)).count == effects.count else {
            try reject(declaration, "Every Effect case must bind to exactly one @Operation namespace.")
        }
        for scope in scopes {
            let sets = operations.filter { $0.scope == scope }.map { Set($0.activeIn) }
            guard sets.dropFirst().allSatisfy({ $0 == sets.first }) else {
                try reject(
                    declaration,
                    "Operations sharing primary scope '\(scope)' must declare identical activeIn sets."
                )
            }
        }
        var transitions: [Schema.Transition] = []
        var routes: [Schema.Route] = []
        var edgeNames = Set<String>()
        for member in members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            let transitionAttribute = try marker(function.attributes, named: "Transition")
            let routeAttribute = try marker(function.attributes, named: "Route")
            guard transitionAttribute == nil || routeAttribute == nil else {
                try reject(function, "A function cannot be both a transition and a router.")
            }
            guard let attribute = transitionAttribute ?? routeAttribute else { continue }
            guard identifier(function.name.text) else {
                try reject(function, "Use an unescaped Swift transition or router identifier.")
            }
            let isRoute = routeAttribute != nil
            if isRoute && mode == "ownedOnly" {
                try reject(
                    attribute,
                    "@Route requires hosted observations and is unavailable in .ownedOnly; select consuming edges in the caller."
                )
            }
            try validateFunction(function, route: isRoute)
            if !isRoute,
                ["withValue", "phase", "payload", "record", "claim", "value", "ordinal"].contains(function.name.text)
            {
                try reject(
                    function,
                    "'\(function.name.text)' is reserved by generated phase wrappers; rename this transition."
                )
            }
            guard edgeNames.insert(function.name.text).inserted,
                members.compactMap({ $0.decl.as(FunctionDeclSyntax.self) })
                    .filter({ $0.name.text == function.name.text }).count == 1
            else { try reject(function, "Transition and router names must be unique and cannot be overloaded.") }
            let metadata = try arguments(
                attribute,
                required: isRoute ? ["from", "on"] : ["from", "to", "on"],
                optional: isRoute ? [] : ["invalidates", "starts"]
            )
            let from = try literal(metadata["from"]!)
            let on = try trigger(metadata["on"]!)
            guard phaseNames.contains(from) else { try reject(attribute, "Source '\(from)' is not a declared phase.") }
            let input = inputs.first { $0.caseName == on.name }
            let operation = operations.first { $0.effect == on.name }
            guard on.kind == "input" ? input != nil : operation != nil else {
                try reject(
                    attribute,
                    "Trigger '\(on.name)' does not name a declared \(on.kind == "input" ? "input" : "effect")."
                )
            }
            if on.kind != "input", let operation, !operation.activeIn.contains(from) {
                try reject(attribute, "Completion edges must start in an operation's activeIn phase.")
            }
            let parameters = Array(function.signature.parameterClause.parameters)
            let needsPayload = on.kind != "input" || input?.payloadType != nil
            guard parameters.count == (needsPayload ? 2 : 1) else {
                try reject(
                    function,
                    "This trigger requires \(needsPayload ? "source and trigger payload parameters" : "only a source parameter")."
                )
            }
            let sourceType = phases.first { $0.caseName == from }!.typeName
            if isRoute {
                guard let observed = parameters[0].type.as(IdentifierTypeSyntax.self),
                    observed.name.text == "Observed", observed.genericArgumentClause?.arguments.count == 1,
                    let result = function.signature.returnClause?.type.as(IdentifierTypeSyntax.self),
                    result.name.text == "PreparationResult", result.genericArgumentClause == nil
                else {
                    try reject(function, "A router must accept Observed<\(sourceType)> and return PreparationResult.")
                }
                routes.append(
                    Schema.Route(
                        name: function.name.text,
                        from: from,
                        trigger: on,
                        sourceType: parameters[0].type.trimmedDescription,
                        payloadType: needsPayload ? parameters[1].type.trimmedDescription : nil
                    )
                )
                continue
            }
            let to = try literal(metadata["to"]!)
            guard let destination = phases.first(where: { $0.caseName == to }) else {
                try reject(attribute, "Destination '\(to)' is not a declared phase.")
            }
            let invalidates = try metadata["invalidates"].map(list) ?? []
            let starts = try metadata["starts"].map(list) ?? []
            guard Set(invalidates).isSubset(of: Set(scopes)), Set(starts).isSubset(of: Set(effects.map(\.caseName)))
            else {
                try reject(attribute, "invalidates must name declared scopes and starts must name declared effects.")
            }
            for effect in starts {
                let started = operations.first { $0.effect == effect }!
                let boundScopes = [started.scope] + started.requires
                guard started.activeIn.contains(to),
                    boundScopes.allSatisfy({ scope in
                        operations.first(where: { $0.scope == scope })?.activeIn.contains(to) ?? true
                    })
                else {
                    try reject(
                        attribute,
                        "Started effect '\(effect)' and every required scope must be eligible in destination '\(to)'."
                    )
                }
            }
            let expectedOwnership = mode == "ownedOnly" ? "consuming" : "borrowing"
            guard let source = parameters[0].type.as(AttributedTypeSyntax.self),
                source.attributes.isEmpty, source.specifiers.count == 1,
                source.specifiers.first?.as(SimpleTypeSpecifierSyntax.self)?.specifier.text == expectedOwnership
            else {
                try reject(parameters[0], "Use an explicitly \(expectedOwnership) \(sourceType) source parameter.")
            }
            var failureType = function.signature.effectSpecifiers?.throwsClause?.type?.trimmedDescription
            if mode == "ownedOnly" {
                guard function.signature.effectSpecifiers?.throwsClause == nil,
                    let result = function.signature.returnClause?.type.as(IdentifierTypeSyntax.self),
                    result.name.text == "Advance",
                    let arguments = result.genericArgumentClause?.arguments, arguments.count == 4
                else {
                    try reject(
                        function,
                        "Owned-only transitions cannot throw and must return Advance<Source, Destination, Effect, Failure>."
                    )
                }
                failureType = arguments.last?.argument.trimmedDescription
            } else {
                guard let result = function.signature.returnClause?.type.as(IdentifierTypeSyntax.self),
                    result.name.text == "Change",
                    let arguments = result.genericArgumentClause?.arguments, arguments.count == 2
                else { try reject(function, "A value transition must return Change<\(destination.typeName), Effect>.") }
            }
            transitions.append(
                Schema.Transition(
                    name: function.name.text,
                    from: from,
                    to: to,
                    trigger: on,
                    invalidates: invalidates,
                    starts: starts,
                    payloadType: needsPayload ? parameters[1].type.trimmedDescription : nil,
                    sourceType: source.baseType.trimmedDescription,
                    returnType: function.signature.returnClause!.type.trimmedDescription,
                    failureType: failureType
                )
            )
        }
        var reserved: Set<String> = [
            "Owned", "Observed", "Snapshot", "Prepared", "PreparationResult", "PreparationRejection", "CommitResult",
            "CommitRejection", "Receipt", "Completion", "Drivers", "Local", "MainActor", "Shared", "Actor",
            "MainActorHost", "ActorHost", "MainActorDrivers", "Configuration", "LocalConfiguration", "makeOwned",
            "owned", "prepare", "ExecutionHandle", "Host",
            "ExecutionDisposition", "AcknowledgmentResult", "Command", "CommandBatch", "PendingCompletionID",
            "PendingCompletion", "DeliveryResult", "_AtomicEngine", "_AtomicLedger", "_AtomicTypeWitness",
            "_AtomicSendableWitness", "_AtomicErrorWitness", "_AtomicCopyableWitness", "_atomicWitnesses",
            "_atomicSnapshot",
            "_atomicAdmission", "_atomicBatch", "_atomicPrepare", "_atomicCompletion", "_atomicFinish",
            "_atomicDeliveryPreparation", "_atomicEligibility", "Phase", "Int", "UInt32", "UInt64", "String", "Bool",
            "Void", "Never", "Result", "Error", "Sendable", "Copyable", "Array", "RuntimeState", "RuntimeTicket",
            "RuntimeLimits", "RuntimeManagedConfiguration", "RuntimeScopeID", "RuntimeOperation",
            "RuntimeOperationPolicy",
            "RuntimeWork", "RuntimeDeliveryClaim", "RuntimeDeliveryLedger", "RuntimePendingID", "RuntimePendingStatus",
            "RuntimeCompletionPolicy", "RuntimeSharedHost", "RuntimeMainActorHost", "RuntimeActorHost",
            "RuntimeHostDelivery", "RuntimeHostSubscriptionFailure", "RuntimeMainActorSubscription",
            "RuntimeSubscription", "Change", "Advance",
            "PreparationFailure", "PlanRejection",
        ]
        for operation in operations {
            for suffix in ["Work", "Completion", "SuccessCompletion", "FailureCompletion"] {
                reserved.insert(operation.name + suffix)
            }
        }
        guard !reserved.contains(declaration.name.text), !declaredNames.contains(declaration.name.text) else {
            try reject(
                declaration,
                "The schema name is reserved or shadowed by a direct member; choose a distinct domain name."
            )
        }
        if mode != "ownedOnly",
            let phase = phases.first(where: { ["record", "model", "ordinal", "isClosed"].contains($0.caseName) })
        {
            try reject(
                declaration,
                "Phase case '\(phase.caseName)' is reserved by generated Snapshot members; rename the phase case."
            )
        }
        for name in declaredNames + phases.map(\.caseName)
        where reserved.contains(name.hasPrefix("`") && name.hasSuffix("`") ? String(name.dropFirst().dropLast()) : name)
        {
            try reject(declaration, "'\(name)' is reserved for generated members; rename the authored declaration.")
        }
        for phase in phases {
            for on in Set(transitions.filter { $0.from == phase.caseName }.map(\.trigger))
                .union(routes.filter { $0.from == phase.caseName }.map(\.trigger))
            {
                let edges = transitions.filter { $0.from == phase.caseName && $0.trigger == on }
                let routers = routes.filter { $0.from == phase.caseName && $0.trigger == on }
                guard routers.count <= 1, edges.count <= 1 || routers.count == 1 else {
                    try reject(
                        declaration,
                        "Ambiguous routing for '\(phase.caseName)' and .\(on.kind)(\"\(on.name)\"); declare exactly one @Route when multiple edges match."
                    )
                }
            }
        }
        for operation in operations {
            for phase in operation.activeIn {
                for kind in ["success", "failure"] where kind != "failure" || operation.failureType != "Never" {
                    let on = Schema.Trigger(kind: kind, name: operation.effect)
                    guard
                        transitions.contains(where: { $0.from == phase && $0.trigger == on })
                            || routes.contains(where: { $0.from == phase && $0.trigger == on })
                    else {
                        try reject(
                            declaration,
                            "Operation '\(operation.name)' needs a \(kind) edge or router in active phase '\(phase)'."
                        )
                    }
                }
            }
        }
        let access =
            declaration.modifiers.first {
                ["public", "package", "internal", "fileprivate", "private"].contains($0.name.text)
            }?
            .name.text ?? "internal"
        return Schema(
            name: declaration.name.text,
            access: access,
            mode: mode,
            initial: initial,
            scopes: scopes,
            phases: phases,
            inputs: inputs,
            effects: effects,
            operations: operations,
            transitions: transitions,
            routes: routes
        )
    }
}
