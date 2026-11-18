import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

@main
struct StateMachinePlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [StateMachineMacro.self, MetadataMacro.self]
}

struct MetadataMacro: PeerMacro {
    static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard let owner = context.lexicalContext.first?.as(EnumDeclSyntax.self),
            owner.attributes.contains(where: {
                ["StateMachine", "StateMachine.StateMachine"]
                    .contains($0.as(AttributeSyntax.self)?.attributeName.trimmedDescription)
            })
        else {
            throw MacroFailure("Place @\(node.attributeName.trimmedDescription) directly inside a @StateMachine enum.")
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
            throw MacroFailure("@StateMachine requires an enum declaration")
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
        return try Generator(schema: schema).members()
    }
}

struct MacroFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
