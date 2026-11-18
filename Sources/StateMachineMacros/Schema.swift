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
        /// The declared default construction, spelled so it resolves outside the schema.
        var defaultValue: String?
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
        /// How the authored function spells its result.
        enum Shape {
            /// The destination payload itself; the edge starts nothing.
            case destination
            /// `Change<Destination, Effect.Edge>`.
            case change
            /// `Advance<Source, Destination, Effect, Failure>`, the owned-only fallible form.
            case advance
        }

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
        let shape: Shape
        /// The generated `Effect.<Namespace>` this edge returns, when it starts operations.
        let effectNamespace: String?
    }

    struct Route {
        let name: String
        let from: String
        let trigger: Trigger
        let sourceType: String
        let payloadType: String?
        let failureType: String?
        /// The generated `Route.<Namespace>` this router returns, when it has edges to choose.
        let namespace: String?
        /// The candidate edge names in declaration order.
        let choices: [String]
    }

    /// The authored function that validates saved data into a resting phase.
    struct Restoration {
        let name: String
        /// The saved data type, spelled so it resolves outside the schema.
        let archiveType: String
        /// The typed failure, spelled so it resolves outside the schema.
        let failureType: String?
    }

    let name: String
    let access: Access
    let mode: Mode
    let initial: String
    /// The declared default construction of the initial payload, spelled so it resolves outside the schema.
    let initialDefault: String?
    let scopes: [String]
    let phases: [Phase]
    let inputs: [Case]
    let operations: [Operation]
    let transitions: [Transition]
    let routes: [Route]
    let restoration: Restoration?

    /// The phases in which no operation is active, in declaration order; only these can be restored.
    var restingPhases: [Phase] {
        phases.filter { phase in !operations.contains { $0.activeIn.contains(phase.caseName) } }
    }

    static func parse(
        _ declaration: EnumDeclSyntax,
        attribute: AttributeSyntax,
        context: some MacroExpansionContext
    ) throws -> Schema {
        let parser = SchemaParser()
        return try parser.parse(declaration, attribute: attribute)
    }
}

/// Qualifies bare references to an enum's own nested types so they resolve outside the enum.
private struct NestedTypeQualifier {
    let owner: String
    let names: Set<String>

    func qualify(_ type: TypeSyntax) -> String {
        guard !names.isEmpty else { return type.trimmedDescription }
        var result = ""
        var previous: TokenSyntax?
        let tokens = Array(type.trimmed.tokens(viewMode: .sourceAccurate))
        for (index, token) in tokens.enumerated() {
            // A name after a period is already qualified, and a name before a colon is a tuple label.
            let isLabel = index + 1 < tokens.count && tokens[index + 1].tokenKind == .colon
            if case .identifier(let name) = token.tokenKind, names.contains(name), previous?.tokenKind != .period,
                !isLabel
            {
                result += token.leadingTrivia.description + owner + "." + token.text + token.trailingTrivia.description
            } else {
                result += token.description
            }
            previous = token
        }
        return result
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

    /// Lower-cases the leading capital run: `Fetch` to `fetch`, `URLLoad` to `urlLoad`.
    private func lowerCamel(_ name: String) -> String {
        let characters = Array(name)
        var run = 0
        while run < characters.count, characters[run].isUppercase { run += 1 }
        guard run > 0 else { return name }
        let lowered = run > 1 && run < characters.count ? run - 1 : run
        return String(characters[..<lowered]).lowercased() + String(characters[lowered...])
    }

    /// The generated companion type name for an authored function: `begin` to `Begin`.
    private func companion(_ name: String) -> String {
        name.prefix(1).uppercased() + name.dropFirst()
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
                // The module-qualified spelling names the same macro.
                [name, "StateMachineSchema.\(name)"].contains($0.attributeName.trimmedDescription)
            }
        guard matches.count <= 1 else {
            try reject(attributes, "Apply @\(name) only once to a declaration.")
        }
        return matches.first
    }

    /// Reads the default value of the `@Initial` case: a no-argument construction of its payload, or a call to
    /// a no-argument static function of the schema, spelled so it resolves outside the schema.
    private func initialDefault(
        _ expression: ExprSyntax,
        payload: String,
        schema: String,
        functions: Set<String>
    ) throws -> String {
        func path(_ expression: ExprSyntax) -> [String]? {
            if let reference = expression.as(DeclReferenceExprSyntax.self), reference.argumentNames == nil {
                return [reference.baseName.text]
            }
            if let member = expression.as(MemberAccessExprSyntax.self), member.declName.argumentNames == nil {
                guard let base = member.base else { return [".", member.declName.baseName.text] }
                return path(base).map { $0 + [member.declName.baseName.text] }
            }
            return nil
        }
        if let call = expression.as(FunctionCallExprSyntax.self), call.arguments.isEmpty,
            call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
            var names = path(call.calledExpression)
        {
            if names.count > 1, names.first == schema || names.first == "Self" { names.removeFirst() }
            if names == [".", "init"] || names == [payload] || names == [payload, "init"] {
                return "\(schema).\(payload)()"
            }
            if names.count == 1, functions.contains(names[0]) { return "\(schema).\(names[0])()" }
        }
        try reject(
            expression,
            "Put this construction in a static function that returns \(payload) and name that function here."
        )
    }

    private func cases(
        _ declaration: EnumDeclSyntax,
        payloads: ClosedRange<Int>,
        initial: String? = nil
    ) throws -> [Schema.Case] {
        guard declaration.genericParameterClause == nil, declaration.genericWhereClause == nil else {
            try reject(declaration, "Input and Scope must be nongeneric closed enums.")
        }
        var result: [Schema.Case] = []
        // A payload may name a type declared inside the enum; generated code refers to it from outside.
        let nested = Set(
            declaration.memberBlock.members.compactMap { member -> String? in
                if let alias = member.decl.as(TypeAliasDeclSyntax.self) { return alias.name.text }
                if let type = member.decl.as(StructDeclSyntax.self) { return type.name.text }
                if let type = member.decl.as(EnumDeclSyntax.self) { return type.name.text }
                return nil
            }
        )
        // Phase payloads are declared in the schema, where generated code already resolves them.
        let qualifier = NestedTypeQualifier(
            owner: declaration.name.text,
            names: declaration.name.text == "Input" ? nested : []
        )
        let staticFunctions = Set(
            declaration.memberBlock.members.compactMap { member -> String? in
                guard let function = member.decl.as(FunctionDeclSyntax.self),
                    function.modifiers.contains(where: { $0.name.text == "static" })
                else { return nil }
                return function.name.text
            }
        )
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
                            ? "Each phase case requires exactly one unlabeled payload."
                            : payloads == 0 ... 0
                                ? "Each Scope case is a plain name without a payload or raw value."
                                : "Each Input case accepts zero or one unlabeled payload."
                    )
                }
                var defaultValue: String?
                if let parameter = parameters?.first {
                    let defaultable = element.name.text == initial
                    guard parameter.firstName == nil || parameter.firstName?.text == "_" else {
                        try reject(
                            parameter,
                            defaultable
                                ? "Use an unlabeled payload."
                                : "Use an unlabeled payload without a default value."
                        )
                    }
                    guard defaultable || parameter.defaultValue == nil else {
                        try reject(parameter, "Use an unlabeled payload without a default value.")
                    }
                    if defaultable, let value = parameter.defaultValue?.value {
                        defaultValue = try initialDefault(
                            value,
                            payload: qualifier.qualify(parameter.type),
                            schema: declaration.name.text,
                            functions: staticFunctions
                        )
                    }
                }
                result.append(
                    Schema.Case(
                        caseName: element.name.text,
                        payloadType: parameters?.first.map { qualifier.qualify($0.type) },
                        defaultValue: defaultValue
                    )
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

    /// Checks the shape shared by authored functions; `role` names them in the throws diagnostic.
    private func validateFunction(_ function: FunctionDeclSyntax, role: String) throws {
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
        if let throwsClause = function.signature.effectSpecifiers?.throwsClause {
            guard throwsClause.type != nil, throwsClause.throwsSpecifier.text == "throws" else {
                try reject(
                    function,
                    "\(role) must use typed throws(Failure), or omit throws."
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
            for name in ["Transition", "Route", "Operation", "Initial", "Restoration"] {
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
        let rootCases = try cases(declaration, payloads: 1 ... 1, initial: initial)
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
        if let authored = nestedEnums.first(where: { $0.name.text == "Effect" }) {
            try reject(
                authored.name,
                "Effect is generated from the @Operation namespaces; delete this declaration."
            )
        }
        guard let inputEnum = nestedEnums.first(where: { $0.name.text == "Input" }) else {
            try reject(
                declaration,
                "Declare a closed Input enum directly inside the schema; an empty enum is allowed."
            )
        }
        let inputs = try cases(inputEnum, payloads: 0 ... 1)
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
            let effect = lowerCamel(namespace.name.text)
            guard effect != namespace.name.text, identifier(effect), !["cancel", "authority"].contains(effect) else {
                try reject(
                    namespace.name,
                    "Operation '\(namespace.name.text)' would generate the effect case '\(effect)', which is a keyword or collides with a generated member; rename the namespace with a capitalized, distinct name."
                )
            }
            guard !operations.contains(where: { $0.effect == effect }) else {
                try reject(
                    namespace.name,
                    "Operation '\(namespace.name.text)' generates the same effect case '\(effect)' as another operation; rename one."
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
                    failureType: types["Failure"]! == "Swift.Never" ? "Never" : types["Failure"]!
                )
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
            if try marker(function.attributes, named: "Restoration") != nil,
                transitionAttribute != nil || routeAttribute != nil
            {
                try reject(function, "A @Restoration function cannot also be a transition or a router.")
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
            try validateFunction(function, role: isRoute ? "Routers" : "Transitions")
            if !isRoute,
                ["withValue", "phase", "payload", "record", "claim", "value", "revision", "description"]
                    .contains(function.name.text)
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
            let base: TypeSyntax
            if let attributed = parameters[0].type.as(AttributedTypeSyntax.self) {
                let expectedOwnership = mode == .ownedOnly ? "consuming" : "borrowing"
                guard attributed.attributes.isEmpty, attributed.specifiers.count == 1,
                    attributed.specifiers.first?.as(SimpleTypeSpecifierSyntax.self)?.specifier.text
                        == expectedOwnership
                else {
                    try reject(
                        parameters[0],
                        mode == .ownedOnly
                            ? "Use an explicitly consuming phase payload as the source parameter."
                            : "Use a plain or borrowing phase payload as the source parameter."
                    )
                }
                base = attributed.baseType
            } else {
                guard mode != .ownedOnly else {
                    try reject(parameters[0], "Use an explicitly consuming phase payload as the source parameter.")
                }
                base = parameters[0].type
            }
            let sourceType = payloadName(base, schema: declaration.name.text)
            guard let from = phases.first(where: { $0.typeName == sourceType })?.caseName else {
                try reject(base, "Source '\(sourceType)' is not a phase payload type declared in this schema.")
            }
            if on.kind != .input, let operation, !operation.activeIn.contains(from) {
                try reject(attribute, "Completion edges must start in an operation's activeIn phase.")
            }
            let payloadType = needsPayload ? parameters[1].type.trimmedDescription : nil
            let thrown = function.signature.effectSpecifiers?.throwsClause?.type?.trimmedDescription
            guard let result = function.signature.returnClause?.type else {
                try reject(function, "Return the destination phase payload, a Change, or a Route choice.")
            }
            if isRoute {
                routes.append(
                    Schema.Route(
                        name: function.name.text,
                        from: from,
                        trigger: on,
                        sourceType: base.trimmedDescription,
                        payloadType: payloadType,
                        failureType: thrown,
                        namespace: nil,
                        choices: []
                    )
                )
                continue
            }
            var started: [Schema.Operation] = []
            let startReferences = try metadata["starts"].map(typeReferences) ?? []
            for reference in startReferences {
                guard let operation = operations.first(where: { $0.name == reference.name }) else {
                    try reject(reference.node, "'\(reference.name)' is not a declared @Operation namespace.")
                }
                started.append(operation)
            }
            let effectNamespace = started.isEmpty ? nil : companion(function.name.text)
            if let effectNamespace {
                guard !["Effect", "Type", "Protocol"].contains(effectNamespace),
                    !transitions.contains(where: { $0.effectNamespace == effectNamespace })
                else {
                    try reject(
                        function.name,
                        "This transition's effect type would be Effect.\(effectNamespace), which is unavailable; rename the transition."
                    )
                }
            }
            let expectedEffect = effectNamespace.map { "Effect.\($0)" }
            let startedNames = started.map(\.name).joined(separator: ", ")
            var failureType = thrown
            let shape: Schema.Transition.Shape
            let destinationNode: TypeSyntax
            if let generic = result.as(IdentifierTypeSyntax.self), generic.name.text == "Advance",
                let arguments = generic.genericArgumentClause?.arguments, arguments.count == 4
            {
                let list = Array(arguments)
                guard mode == .ownedOnly, case .type(let destination) = list[1].argument else {
                    try reject(
                        result,
                        "Advance<Source, Destination, Effect, Failure> is the owned-only form; value transitions use typed throws."
                    )
                }
                guard list[2].argument.trimmedDescription == expectedEffect ?? "Never" else {
                    try reject(
                        list[2],
                        expectedEffect.map { "This transition starts \(startedNames); use \($0) as its effect type." }
                            ?? "This transition starts no operation; use Never as its effect type."
                    )
                }
                shape = .advance
                destinationNode = destination
                failureType = list[3].argument.trimmedDescription
            } else if let generic = result.as(IdentifierTypeSyntax.self), generic.name.text == "Change",
                let arguments = generic.genericArgumentClause?.arguments, arguments.count == 2
            {
                let list = Array(arguments)
                guard case .type(let destination) = list[0].argument else {
                    try reject(result, "Change must name the destination phase payload type.")
                }
                guard let expectedEffect else {
                    try reject(
                        result,
                        "This transition starts no operation; return \(destination.trimmedDescription) directly."
                    )
                }
                guard list[1].argument.trimmedDescription == expectedEffect else {
                    try reject(
                        list[1],
                        "This transition starts \(startedNames); name its effects \(expectedEffect)."
                    )
                }
                shape = .change
                destinationNode = destination
            } else {
                if let expectedEffect {
                    try reject(
                        result,
                        "This transition starts \(startedNames); return Change<\(result.trimmedDescription), \(expectedEffect)>."
                    )
                }
                shape = .destination
                destinationNode = result
            }
            if mode == .ownedOnly, thrown != nil {
                try reject(
                    function,
                    "Owned-only transitions cannot throw; return Advance<Source, Destination, Effect, Failure> to give the source back."
                )
            }
            let destinationType = payloadName(destinationNode, schema: declaration.name.text)
            guard let to = phases.first(where: { $0.typeName == destinationType })?.caseName else {
                try reject(
                    destinationNode,
                    "Destination '\(destinationType)' is not a phase payload type declared in this schema."
                )
            }
            let invalidates = try metadata["invalidates"].map { try caseReferences($0, in: "Scope") } ?? []
            guard Set(invalidates).isSubset(of: Set(scopes)) else {
                try reject(metadata["invalidates"]!, "invalidates must reference declared Scope cases.")
            }
            for (operation, reference) in zip(started, startReferences) {
                let boundScopes = [operation.scope] + operation.requires
                guard operation.activeIn.contains(to),
                    boundScopes.allSatisfy({ scope in
                        operations.first(where: { $0.scope == scope })?.activeIn.contains(to) ?? true
                    })
                else {
                    try reject(
                        reference.node,
                        "Started operation '\(operation.name)' and every required scope must be eligible in destination '\(destinationType)'."
                    )
                }
            }
            transitions.append(
                Schema.Transition(
                    name: function.name.text,
                    from: from,
                    to: to,
                    trigger: on,
                    invalidates: invalidates,
                    starts: started.map(\.effect),
                    payloadType: payloadType,
                    sourceType: base.trimmedDescription,
                    returnType: result.trimmedDescription,
                    failureType: failureType,
                    shape: shape,
                    effectNamespace: effectNamespace
                )
            )
        }
        // A router chooses among the edges that share its source and trigger, so its result type
        // can only be checked once every edge is known.
        routes = try routes.map { route in
            let function = members.compactMap { $0.decl.as(FunctionDeclSyntax.self) }
                .first { $0.name.text == route.name }!
            let result = function.signature.returnClause!.type
            let choices = transitions.filter { $0.from == route.from && $0.trigger == route.trigger }.map(\.name)
            let namespace = choices.isEmpty ? nil : companion(route.name)
            if let namespace {
                guard !["Route", "Type", "Protocol"].contains(namespace) else {
                    try reject(
                        function.name,
                        "This router's choice type would be Route.\(namespace); rename the router."
                    )
                }
                guard result.trimmedDescription == "Route.\(namespace)" else {
                    try reject(
                        result,
                        "A router returns its choice among \(choices.joined(separator: ", ")): Route.\(namespace)."
                    )
                }
            } else {
                guard result.trimmedDescription == "Never", route.failureType != nil else {
                    try reject(
                        function,
                        "A router with no edge to choose returns Never and throws a typed rejection."
                    )
                }
            }
            return Schema.Route(
                name: route.name,
                from: route.from,
                trigger: route.trigger,
                sourceType: route.sourceType,
                payloadType: route.payloadType,
                failureType: route.failureType,
                namespace: namespace,
                choices: choices
            )
        }
        let restoration = try restoration(members, mode: mode, schema: declaration.name.text)
        var reserved: Set<String> = [
            "Owned", "Observed", "Snapshot", "Prepared", "PreparationResult", "PreparationRejection", "CommitResult",
            "CommitRejection", "Receipt", "Completion", "Drivers", "Local", "MainActor", "Shared", "Actor",
            "MainActorHost", "ActorHost", "MainActorDrivers", "Configuration", "LocalConfiguration", "makeOwned",
            "owned", "prepare", "ExecutionHandle", "Host",
            "ExecutionDisposition", "AcknowledgmentResult", "Command", "CommandBatch", "PendingCompletionID",
            "PendingCompletion", "DeliveryResult", "_StateMachineEngine", "_StateMachineLedger",
            "_TransitionSourceIsPhasePayload", "_TransitionReturnsDeclaredResult", "_TriggerPayloadMatchesDeclaration",
            "_RouterSourceIsPhasePayload", "_SharedModeRequiresSendable",
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
            "RuntimeSubscription", "RuntimeSnapshots", "RuntimeMainActorSnapshots", "Snapshots",
            "MainActorSnapshots", "Change", "Advance",
            "PreparationFailure", "PlanRejection", "Effect", "Route", "SendRejection", "Subscription",
            "MainActorSubscription", "SubscriptionFailure", "CompletionPolicy", "PendingStatus", "StateMachineSnapshot",
            "StateMachineReceipt", "MainActorStateMachineHost", "Restoration", "_stateMachineRestored",
            "ShutdownResult", "ShutdownDiagnostics", "RuntimeShutdownDiagnostics",
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
            let phase = phases.first(where: {
                ["record", "model", "revision", "isClosed", "description"].contains($0.caseName)
            })
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
            initialDefault: rootCases.first { $0.caseName == initial }?.defaultValue,
            scopes: scopes,
            phases: phases,
            inputs: inputs,
            operations: operations,
            transitions: transitions,
            routes: routes,
            restoration: restoration
        )
    }

    /// Reads the optional `@Restoration` validator: `static func <name>(_ saved: Archive) -> Restoration`.
    private func restoration(
        _ members: MemberBlockItemListSyntax,
        mode: Schema.Mode,
        schema: String
    ) throws -> Schema.Restoration? {
        let marked = try members.compactMap { member -> (function: FunctionDeclSyntax, attribute: AttributeSyntax)? in
            guard let function = member.decl.as(FunctionDeclSyntax.self),
                let attribute = try marker(function.attributes, named: "Restoration")
            else { return nil }
            return (function, attribute)
        }
        guard let first = marked.first else { return nil }
        let function = first.function
        let attribute = first.attribute
        guard marked.count == 1 else {
            try reject(marked[1].attribute, "Declare at most one @Restoration function in a schema.")
        }
        guard mode != .ownedOnly else {
            try reject(attribute, "@Restoration is unavailable in .ownedOnly, which generates no owner to restore.")
        }
        guard attribute.arguments == nil else { try reject(attribute, "@Restoration takes no arguments.") }
        guard identifier(function.name.text) else {
            try reject(function.name, "Use an unescaped Swift restoration function identifier.")
        }
        guard
            members.compactMap({ $0.decl.as(FunctionDeclSyntax.self) })
                .filter({ $0.name.text == function.name.text }).count == 1
        else { try reject(function.name, "A @Restoration function cannot be overloaded.") }
        try validateFunction(function, role: "Restoration functions")
        let parameters = function.signature.parameterClause.parameters
        guard parameters.count == 1, let parameter = parameters.first else {
            try reject(
                function.signature.parameterClause,
                "A @Restoration function takes exactly one unlabeled parameter: the saved data it validates."
            )
        }
        if let attributed = parameter.type.as(AttributedTypeSyntax.self),
            attributed.specifiers.contains(where: {
                $0.as(SimpleTypeSpecifierSyntax.self)?.specifier.tokenKind == .keyword(.inout)
            })
        {
            try reject(parameter, "Pass the saved data to a @Restoration function by value, not inout.")
        }
        guard let result = function.signature.returnClause?.type, payloadName(result, schema: schema) == "Restoration"
        else {
            try reject(
                function.signature.returnClause.map(Syntax.init) ?? Syntax(function),
                "A @Restoration function returns Restoration, the resting phase to restore."
            )
        }
        return Schema.Restoration(
            name: function.name.text,
            archiveType: outsideSchema(parameter.type, schema: schema),
            failureType: function.signature.effectSpecifiers?.throwsClause?.type
                .map { outsideSchema($0, schema: schema) }
        )
    }

    /// Spells a type written inside the schema so it means the same thing inside a generated owner.
    private func outsideSchema(_ type: TypeSyntax, schema: String) -> String {
        type.trimmed.tokens(viewMode: .sourceAccurate)
            .map { token in
                token.tokenKind == .keyword(.Self)
                    ? token.leadingTrivia.description + schema + token.trailingTrivia.description
                    : token.description
            }
            .joined()
    }
}
