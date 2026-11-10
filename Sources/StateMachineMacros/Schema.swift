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

    enum Mode: String {
        case shared
        case isolated
        case ownedOnly
    }

    enum Access: String {
        case `public`
        case package
        case `internal`
        case `fileprivate`
        case `private`
    }

    struct Trigger: Hashable {
        enum Kind: String, Hashable {
            case input
            case success
            case failure
        }

        let kind: Kind
        let name: String
    }

    enum Admission: Equatable {
        case latest
        case rejectWhenActive
        case parallel(limit: Int)

        /// The most starts of one operation that a single plan may contain.
        var maxNewIntents: Int {
            switch self {
            case .latest, .rejectWhenActive: 1
            case .parallel(let limit): limit
            }
        }
    }

    struct Operation {
        let name: String
        let effect: String
        let scope: String
        let requires: [String]
        let activeIn: [String]
        let admission: Admission
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
    let access: Access
    let mode: Mode
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
        let parsed = Parser.parse(source: "enum _SchemaIdentifier { case \(text) }")
        guard !parsed.hasError, parsed.statements.count == 1,
            let declaration = parsed.statements.first?.item.as(EnumDeclSyntax.self),
            declaration.memberBlock.members.count == 1,
            let cases = declaration.memberBlock.members.first?.decl.as(EnumCaseDeclSyntax.self),
            cases.elements.count == 1, let name = cases.elements.first?.name, name.presence == .present
        else { return false }
        return name.text == text
    }

    /// Reads `<Enum>.<case>`, the only accepted spelling of a declared case reference.
    private func caseReference(_ expression: ExprSyntax, in enumeration: String) throws -> String {
        guard let member = expression.as(MemberAccessExprSyntax.self),
            let base = member.base?.as(DeclReferenceExprSyntax.self), base.argumentNames == nil,
            base.baseName.text == enumeration, member.declName.argumentNames == nil,
            case .identifier(let name) = member.declName.baseName.tokenKind, identifier(name)
        else { try reject(expression, "Reference a declared case as \(enumeration).<case>.") }
        return name
    }

    private func caseReferences(_ expression: ExprSyntax, in enumeration: String) throws -> [String] {
        guard let array = expression.as(ArrayExprSyntax.self) else {
            try reject(expression, "Use an array literal of \(enumeration).<case> references.")
        }
        let values = try array.elements.map { try caseReference($0.expression, in: enumeration) }
        guard Set(values).count == values.count else {
            try reject(expression, "Remove duplicate references from this metadata list.")
        }
        return values
    }

    /// Reads `<Type>.self`, the only accepted spelling of a declared phase payload or operation reference.
    private func typeReference(_ expression: ExprSyntax) throws -> String {
        guard let member = expression.as(MemberAccessExprSyntax.self),
            let base = member.base?.as(DeclReferenceExprSyntax.self), base.argumentNames == nil,
            member.declName.baseName.tokenKind == .keyword(.self), identifier(base.baseName.text)
        else { try reject(expression, "Reference a type declared directly inside the schema as <Type>.self.") }
        return base.baseName.text
    }

    /// Reads a phase payload spelling from a signature, allowing `Self.` or schema-name qualification.
    private func payloadName(_ type: TypeSyntax, schema: String) -> String {
        if let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil,
            let base = member.baseType.as(IdentifierTypeSyntax.self), base.genericArgumentClause == nil,
            base.name.text == "Self" || base.name.text == schema
        {
            return member.name.text
        }
        return type.trimmedDescription
    }

    private func typeReferences(_ expression: ExprSyntax) throws -> [(name: String, node: ExprSyntax)] {
        guard let array = expression.as(ArrayExprSyntax.self) else {
            try reject(expression, "Use an array literal of <Type>.self references.")
        }
        let values = try array.elements.map { (name: try typeReference($0.expression), node: $0.expression) }
        guard Set(values.map(\.name)).count == values.count else {
            try reject(expression, "Remove duplicate references from this metadata list.")
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
            guard required.isEmpty, attribute.arguments == nil else {
                try reject(attribute, "Provide labeled metadata arguments.")
            }
            return [:]
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

    /// Reads the one trigger label of an edge or router: `on`, `onSuccess`, or `onFailure`.
    private func trigger(
        _ metadata: [String: ExprSyntax],
        attribute: AttributeSyntax,
        inputs: [Schema.Case],
        operations: [Schema.Operation]
    ) throws -> Schema.Trigger {
        let labels = ["on", "onSuccess", "onFailure"].filter { metadata[$0] != nil }
        guard labels.count == 1, let label = labels.first, let expression = metadata[label] else {
            try reject(
                attribute,
                "Name exactly one trigger: on: Input.<case>, onSuccess: <Operation>.self, or onFailure: <Operation>.self."
            )
        }
        guard label != "on" else {
            let name = try caseReference(expression, in: "Input")
            guard inputs.contains(where: { $0.caseName == name }) else {
                try reject(expression, "'\(name)' is not a declared Input case.")
            }
            return Schema.Trigger(kind: .input, name: name)
        }
        let name = try typeReference(expression)
        guard let operation = operations.first(where: { $0.name == name }) else {
            try reject(expression, "'\(name)' is not a declared @Operation namespace.")
        }
        return Schema.Trigger(kind: label == "onSuccess" ? .success : .failure, name: operation.effect)
    }

    private func describe(_ trigger: Schema.Trigger, operations: [Schema.Operation]) -> String {
        guard trigger.kind != .input else { return "on: Input.\(trigger.name)" }
        let name = operations.first { $0.effect == trigger.name }?.name ?? trigger.name
        return "\(trigger.kind == .success ? "onSuccess" : "onFailure"): \(name).self"
    }

    /// Finds the authored declaration to blame for a name, falling back to the schema.
    private func anchor(for name: String, in declaration: EnumDeclSyntax) -> Syntax {
        func matches(_ token: TokenSyntax) -> Bool {
            token.text == name || token.text == "`\(name)`" || "`\(token.text)`" == name
        }
        for member in declaration.memberBlock.members {
            if let cases = member.decl.as(EnumCaseDeclSyntax.self),
                let element = cases.elements.first(where: { matches($0.name) })
            {
                return Syntax(element)
            }
            if let named = member.decl.asProtocol(NamedDeclSyntax.self), matches(named.name) {
                return Syntax(member.decl)
            }
            if let variable = member.decl.as(VariableDeclSyntax.self),
                variable.bindings.contains(where: {
                    $0.pattern.as(IdentifierPatternSyntax.self).map { matches($0.identifier) } ?? false
                })
            {
                return Syntax(member.decl)
            }
        }
        return Syntax(declaration)
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

    private func cases(_ declaration: EnumDeclSyntax, payloads: ClosedRange<Int>) throws -> [Schema.Case] {
        guard declaration.genericParameterClause == nil, declaration.genericWhereClause == nil else {
            try reject(declaration, "Input, Effect, and Scope must be nongeneric closed enums.")
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
                guard element.rawValue == nil, payloads.contains(count) else {
                    try reject(
                        element,
                        payloads == 1 ... 1
                            ? "Each phase and Effect case requires exactly one unlabeled payload."
                            : payloads == 0 ... 0
                                ? "Each Scope case is a plain name without a payload or raw value."
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

    private func admission(_ expression: ExprSyntax) throws -> Schema.Admission {
        if let call = expression.as(FunctionCallExprSyntax.self) {
            guard try member(call.calledExpression) == "parallel", call.arguments.count == 1,
                let argument = call.arguments.first, argument.label?.text == "limit",
                let integer = argument.expression.as(IntegerLiteralExprSyntax.self),
                let limit = Int(integer.literal.text), limit > 0,
                call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty
            else {
                try reject(expression, "Use .parallel(limit: N) with a positive decimal integer representable as Int.")
            }
            return .parallel(limit: limit)
        }
        switch try member(expression) {
        case "latest": return .latest
        case "rejectWhenActive": return .rejectWhenActive
        default: try reject(expression, "Admission must be .latest, .rejectWhenActive, or .parallel(limit: N).")
        }
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
        let root = try arguments(attribute, required: ["mode"])
        guard let mode = Schema.Mode(rawValue: try member(root["mode"]!)) else {
            try reject(attribute, "Mode must be .shared, .isolated, or .ownedOnly.")
        }
        let members = declaration.memberBlock.members
        var initialCases: [EnumCaseDeclSyntax] = []
        for member in members {
            guard let attributed = member.decl.asProtocol(WithAttributesSyntax.self) else { continue }
            for name in ["Transition", "Route", "Operation", "Initial"] {
                guard let attribute = try marker(attributed.attributes, named: name) else { continue }
                switch name {
                case "Operation":
                    guard member.decl.is(EnumDeclSyntax.self) else {
                        try reject(attribute, "@Operation must mark a nested enum namespace.")
                    }
                case "Initial":
                    guard let phase = member.decl.as(EnumCaseDeclSyntax.self), phase.elements.count == 1,
                        attribute.arguments == nil
                    else {
                        try reject(
                            attribute,
                            "@Initial takes no arguments and must mark a declaration of one phase case directly inside the schema."
                        )
                    }
                    initialCases.append(phase)
                default:
                    guard member.decl.is(FunctionDeclSyntax.self) else {
                        try reject(
                            attribute,
                            "@\(name) must mark a static function declared directly inside the schema."
                        )
                    }
                }
            }
        }
        guard initialCases.count == 1, let initial = initialCases.first?.elements.first?.name.text else {
            try reject(
                initialCases.dropFirst().first.map(Syntax.init) ?? Syntax(attribute),
                "Mark exactly one phase case with @Initial."
            )
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
        let rootCases = try cases(declaration, payloads: 1 ... 1)
        let phases = try rootCases.map { value -> Schema.Phase in
            guard let type = value.payloadType, identifier(type), nominalNames.contains(type),
                !["Input", "Effect", "Scope"].contains(type)
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
        func phase(_ reference: (name: String, node: ExprSyntax)) throws -> String {
            guard let phase = phases.first(where: { $0.typeName == reference.name }) else {
                try reject(reference.node, "'\(reference.name)' is not a phase payload type declared in this schema.")
            }
            return phase.caseName
        }
        guard let inputEnum = nestedEnums.first(where: { $0.name.text == "Input" }),
            let effectEnum = nestedEnums.first(where: { $0.name.text == "Effect" })
        else {
            try reject(
                declaration,
                "Declare closed Input and Effect enums directly inside the schema; empty enums are allowed."
            )
        }
        let inputs = try cases(inputEnum, payloads: 0 ... 1)
        let effects = try cases(effectEnum, payloads: 1 ... 1)
        let scopes =
            try nestedEnums.first { $0.name.text == "Scope" }
            .map { try cases($0, payloads: 0 ... 0).map(\.caseName) } ?? []
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
                required: ["scope", "activeIn", "admission"],
                optional: ["requires"]
            )
            let requests = effects.filter { $0.payloadType == "\(namespace.name.text).Input" }
            guard requests.count == 1, let effect = requests.first?.caseName else {
                try reject(
                    namespace,
                    "Exactly one Effect case must request this operation by carrying \(namespace.name.text).Input."
                )
            }
            let scope = try caseReference(metadata["scope"]!, in: "Scope")
            let dependencies = try metadata["requires"].map { try caseReferences($0, in: "Scope") } ?? []
            let activeIn = try typeReferences(metadata["activeIn"]!).map(phase)
            guard scopes.contains(scope),
                Set(dependencies).isSubset(of: Set(scopes)), !dependencies.contains(scope),
                !activeIn.isEmpty
            else {
                try reject(
                    attribute,
                    "Operation metadata must reference a primary Scope case, distinct additional Scope cases, and at least one active phase."
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
                    admission: policy,
                    inputType: types["Input"]!,
                    outputType: types["Output"]!,
                    failureType: types["Failure"]!
                )
            )
        }
        if let unbound = effects.first(where: { effect in !operations.contains { $0.effect == effect.caseName } }) {
            try reject(
                effectEnum,
                "Effect case '\(unbound.caseName)' must request an @Operation namespace by carrying its Input alias, such as Fetch.Input."
            )
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
        let triggerLabels: Set<String> = ["on", "onSuccess", "onFailure"]
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
            if isRoute && mode == .ownedOnly {
                try reject(
                    attribute,
                    "@Route requires hosted observations and is unavailable in .ownedOnly; select consuming edges in the caller."
                )
            }
            try validateFunction(function, route: isRoute)
            if !isRoute,
                ["withValue", "phase", "payload", "record", "claim", "value", "revision"].contains(function.name.text)
            {
                try reject(
                    function,
                    "'\(function.name.text)' is reserved by generated phase wrappers; rename this transition."
                )
            }
            if !isRoute, function.signature.effectSpecifiers?.throwsClause != nil,
                ["plan", "invalidPhase"].contains(function.name.text)
            {
                try reject(
                    function.name,
                    "'\(function.name.text)' is already a PreparationRejection case; rename this throwing transition."
                )
            }
            guard edgeNames.insert(function.name.text).inserted,
                members.compactMap({ $0.decl.as(FunctionDeclSyntax.self) })
                    .filter({ $0.name.text == function.name.text }).count == 1
            else { try reject(function, "Transition and router names must be unique and cannot be overloaded.") }
            let metadata = try arguments(
                attribute,
                required: [],
                optional: isRoute ? triggerLabels : triggerLabels.union(["invalidates", "starts"])
            )
            let on = try trigger(metadata, attribute: attribute, inputs: inputs, operations: operations)
            let input = inputs.first { $0.caseName == on.name }
            let operation = operations.first { $0.effect == on.name }
            let parameters = Array(function.signature.parameterClause.parameters)
            let needsPayload = on.kind != .input || input?.payloadType != nil
            guard parameters.count == (needsPayload ? 2 : 1) else {
                try reject(
                    function,
                    "This trigger requires \(needsPayload ? "source and trigger payload parameters" : "only a source parameter")."
                )
            }
            let expectedOwnership = mode == .ownedOnly ? "consuming" : "borrowing"
            let sourceType: String
            var authoredSource = parameters[0].type.trimmedDescription
            if isRoute {
                guard let observed = parameters[0].type.as(IdentifierTypeSyntax.self),
                    observed.name.text == "Observed", let arguments = observed.genericArgumentClause?.arguments,
                    arguments.count == 1, let argument = arguments.first,
                    let result = function.signature.returnClause?.type.as(IdentifierTypeSyntax.self),
                    result.name.text == "PreparationResult", result.genericArgumentClause == nil
                else {
                    try reject(function, "A router must accept Observed<Source> and return PreparationResult.")
                }
                guard case .type(let observedType) = argument.argument else {
                    try reject(argument, "A router must accept Observed<Source> and return PreparationResult.")
                }
                sourceType = payloadName(observedType, schema: declaration.name.text)
            } else {
                guard let source = parameters[0].type.as(AttributedTypeSyntax.self),
                    source.attributes.isEmpty, source.specifiers.count == 1,
                    source.specifiers.first?.as(SimpleTypeSpecifierSyntax.self)?.specifier.text == expectedOwnership
                else {
                    try reject(
                        parameters[0],
                        "Use an explicitly \(expectedOwnership) phase payload as the source parameter."
                    )
                }
                sourceType = payloadName(source.baseType, schema: declaration.name.text)
                authoredSource = source.baseType.trimmedDescription
            }
            guard let from = phases.first(where: { $0.typeName == sourceType })?.caseName else {
                try reject(
                    parameters[0].type,
                    "Source '\(sourceType)' is not a phase payload type declared in this schema."
                )
            }
            if on.kind != .input, let operation, !operation.activeIn.contains(from) {
                try reject(attribute, "Completion edges must start in an operation's activeIn phase.")
            }
            if isRoute {
                routes.append(
                    Schema.Route(
                        name: function.name.text,
                        from: from,
                        trigger: on,
                        sourceType: authoredSource,
                        payloadType: needsPayload ? parameters[1].type.trimmedDescription : nil
                    )
                )
                continue
            }
            var failureType = function.signature.effectSpecifiers?.throwsClause?.type?.trimmedDescription
            let destinationType: String
            if mode == .ownedOnly {
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
                guard case .type(let advanced) = arguments[arguments.index(after: arguments.startIndex)].argument else {
                    try reject(result, "Advance must name the destination phase payload type.")
                }
                destinationType = payloadName(advanced, schema: declaration.name.text)
                failureType = arguments.last?.argument.trimmedDescription
            } else {
                guard let result = function.signature.returnClause?.type.as(IdentifierTypeSyntax.self),
                    result.name.text == "Change",
                    let arguments = result.genericArgumentClause?.arguments, arguments.count == 2,
                    let argument = arguments.first
                else { try reject(function, "A value transition must return Change<Destination, Effect>.") }
                guard case .type(let changed) = argument.argument else {
                    try reject(result, "Change must name the destination phase payload type.")
                }
                destinationType = payloadName(changed, schema: declaration.name.text)
            }
            guard let to = phases.first(where: { $0.typeName == destinationType })?.caseName else {
                try reject(
                    function.signature.returnClause!.type,
                    "Destination '\(destinationType)' is not a phase payload type declared in this schema."
                )
            }
            let invalidates = try metadata["invalidates"].map { try caseReferences($0, in: "Scope") } ?? []
            guard Set(invalidates).isSubset(of: Set(scopes)) else {
                try reject(metadata["invalidates"]!, "invalidates must reference declared Scope cases.")
            }
            var starts: [String] = []
            for reference in try metadata["starts"].map(typeReferences) ?? [] {
                guard let started = operations.first(where: { $0.name == reference.name }) else {
                    try reject(reference.node, "'\(reference.name)' is not a declared @Operation namespace.")
                }
                let boundScopes = [started.scope] + started.requires
                guard started.activeIn.contains(to),
                    boundScopes.allSatisfy({ scope in
                        operations.first(where: { $0.scope == scope })?.activeIn.contains(to) ?? true
                    })
                else {
                    try reject(
                        reference.node,
                        "Started operation '\(started.name)' and every required scope must be eligible in destination '\(destinationType)'."
                    )
                }
                starts.append(started.effect)
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
                    sourceType: authoredSource,
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
            "PendingCompletion", "DeliveryResult", "_StateMachineEngine", "_StateMachineLedger",
            "_TransitionSourceIsPhasePayload", "_TransitionReturnsDeclaredResult", "_TriggerPayloadMatchesDeclaration",
            "_EffectPayloadIsOperationInput", "_RouterSourceIsObservedPhase", "_SharedModeRequiresSendable",
            "_OperationFailureIsError", "_EffectIsCopyable", "_stateMachineWitnesses",
            "_stateMachineSnapshot",
            "_stateMachineAdmission", "_stateMachineBatch", "_stateMachinePrepare", "_stateMachineCompletion",
            "_stateMachineFinish",
            "_stateMachineDeliveryPreparation", "_stateMachineEligibility", "Phase", "Int", "UInt32", "UInt64",
            "String", "Bool",
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
        if mode != .ownedOnly,
            let phase = phases.first(where: { ["record", "model", "revision", "isClosed"].contains($0.caseName) })
        {
            try reject(
                anchor(for: phase.caseName, in: declaration),
                "Phase case '\(phase.caseName)' is reserved by generated Snapshot members; rename the phase case."
            )
        }
        for name in declaredNames + phases.map(\.caseName)
        where reserved.contains(name.hasPrefix("`") && name.hasSuffix("`") ? String(name.dropFirst().dropLast()) : name)
        {
            try reject(
                anchor(for: name, in: declaration),
                "'\(name)' is reserved for generated members; rename the authored declaration."
            )
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
                        "Ambiguous routing from '\(phase.typeName)' for \(describe(on, operations: operations)); declare exactly one @Route when multiple edges match."
                    )
                }
            }
        }
        for operation in operations {
            for phase in operation.activeIn {
                for kind in [Schema.Trigger.Kind.success, .failure]
                where kind != .failure || operation.failureType != "Never" {
                    let on = Schema.Trigger(kind: kind, name: operation.effect)
                    guard
                        transitions.contains(where: { $0.from == phase && $0.trigger == on })
                            || routes.contains(where: { $0.from == phase && $0.trigger == on })
                    else {
                        try reject(
                            declaration,
                            "Operation '\(operation.name)' needs a \(kind.rawValue) edge or router in active phase case '\(phase)'."
                        )
                    }
                }
            }
        }
        let access = declaration.modifiers.lazy.compactMap { Schema.Access(rawValue: $0.name.text) }.first ?? .internal
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
