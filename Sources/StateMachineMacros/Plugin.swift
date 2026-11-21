import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct StateMachinePlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        StateMachineMacro.self, MetadataMacro.self, OperationMacro.self, EventMacro.self, ActiveMacro.self,
    ]
}

struct MetadataMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let owner = context.lexicalContext.first?.as(EnumDeclSyntax.self),
            owner.attributes.contains(where: {
                $0.as(AttributeSyntax.self).map { Schema.namesMacro($0, "StateMachine") } ?? false
            })
        else {
            throw MacroFailure("Place @\(node.attributeName.trimmedDescription) directly inside a @StateMachine enum.")
        }
        return []
    }
}

/// Marks an operation namespace, and declares the `Input` and `Output` aliases it omits as `Void`, so
/// `Refresh.Input` and `Refresh.Output` name its types whether or not the author wrote them.
struct OperationMacro: PeerMacro, MemberMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try MetadataMacro.expansion(of: node, providingPeersOf: declaration, in: context)
    }

    static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // The schema diagnoses a misplaced marker; an operation is always an enum.
        guard let namespace = declaration.as(EnumDeclSyntax.self) else { return [] }
        let declared = Set(
            namespace.memberBlock.members.compactMap { $0.decl.as(TypeAliasDeclSyntax.self)?.name.unescaped }
        )
        let access =
            namespace.modifiers.lazy.map(\.name.unescaped)
            .first { ["public", "package", "internal", "fileprivate", "private"].contains($0) }
            .map { $0 == "private" ? "fileprivate " : "\($0) " } ?? ""
        return [("Input", "takes"), ("Output", "produces")]
            .filter { !declared.contains($0.0) }
            .map { alias, verb in
                DeclSyntax(
                    stringLiteral: "/// The operation \(verb) no value.\n\(access)typealias \(alias) = Swift::Void"
                )
            }
    }
}

/// Marks an event namespace, and declares its `Payload` alias as `Void` when it omits one, so
/// `Tracked.Payload` names its payload whether or not the author wrote it.
struct EventMacro: PeerMacro, MemberMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        try MetadataMacro.expansion(of: node, providingPeersOf: declaration, in: context)
    }

    static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        // The schema diagnoses a misplaced marker; an event is always an enum.
        guard let namespace = declaration.as(EnumDeclSyntax.self),
            !namespace.memberBlock.members.contains(where: {
                $0.decl.as(TypeAliasDeclSyntax.self)?.name.unescaped == "Payload"
            })
        else { return [] }
        let access =
            namespace.modifiers.lazy.map(\.name.unescaped)
            .first { ["public", "package", "internal", "fileprivate", "private"].contains($0) }
            .map { $0 == "private" ? "fileprivate " : "\($0) " } ?? ""
        return [DeclSyntax(stringLiteral: "/// The event carries no value.\n\(access)typealias Payload = Swift::Void")]
    }
}

/// Marks a case of a schema's `Scope` enum with the phases in which it stays active.
struct ActiveMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let enclosing = Array(context.lexicalContext.prefix(2))
        guard declaration.is(EnumCaseDeclSyntax.self), enclosing.count == 2,
            enclosing[0].as(EnumDeclSyntax.self)?.name.unescaped == "Scope",
            let owner = enclosing[1].as(EnumDeclSyntax.self),
            owner.attributes.contains(where: {
                $0.as(AttributeSyntax.self).map { Schema.namesMacro($0, "StateMachine") } ?? false
            })
        else {
            throw MacroFailure(
                "Place @\(node.attributeName.trimmedDescription) on a case of the Scope enum directly inside a @StateMachine enum."
            )
        }
        return []
    }
}

struct StateMachineMacro: MemberMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingMembersOf declaration: some DeclGroupSyntax,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let enumeration = declaration.as(EnumDeclSyntax.self) else {
            // The refusal stands at the keyword that declares something other than an enum.
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: declaration.introducer,
                    message: PlacementMessage(message: "@StateMachine requires an enum declaration")
                )
            ])
        }
        let genericEnclosingType = context.lexicalContext.contains { syntax in
            syntax.as(StructDeclSyntax.self)?.genericParameterClause != nil
                || syntax.as(EnumDeclSyntax.self)?.genericParameterClause != nil
                || syntax.as(ClassDeclSyntax.self)?.genericParameterClause != nil
                || syntax.as(ActorDeclSyntax.self)?.genericParameterClause != nil
        }
        guard !genericEnclosingType else {
            throw MacroFailure("Generic schemas, including schemas inside a generic enclosing type, are unsupported.")
        }
        let schema = try Schema.parse(enumeration, attribute: node, context: context)
        if let excess = schema.sizeLimitExcess {
            throw DiagnosticsError(diagnostics: [
                Diagnostic(node: enumeration.name, message: SizeLimitMessage(message: excess))
            ])
        }
        return try Generator(schema: schema).members()
    }
}

/// The refusal of a schema larger than the generated code compiles in reasonable time.
private struct SizeLimitMessage: DiagnosticMessage {
    let message: String
    var diagnosticID: MessageID { MessageID(domain: "StateMachine", id: "schemaTooLarge") }
    var severity: DiagnosticSeverity { .error }
}

/// The refusal of a schema attribute on a declaration that is not an enum.
private struct PlacementMessage: DiagnosticMessage {
    let message: String
    var diagnosticID: MessageID { MessageID(domain: "StateMachine", id: "schemaNotEnum") }
    var severity: DiagnosticSeverity { .error }
}

struct MacroFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
