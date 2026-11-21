import SwiftParser
import SwiftSyntax

/// Decides which generated uses of an authored spelling go through its schema-level alias.
///
/// Generation spells every candidate of ``Schema/shieldedSpellings`` through a placeholder. A use keeps
/// an alias only where a generated scope around it declares a type named like one of the spelling's free
/// names, which would otherwise capture that name; every other use gets the authored spelling back.
/// An alias is declared only when some use keeps it, with the highest access among those uses: the
/// access of the declaration whose signature holds the use, within every type that encloses it, or
/// file-private for a use inside a body, which needs only visibility.
struct SpellingShield {
    /// A schema-level alias that some generated use needs.
    struct Alias {
        let name: String
        let spelling: String
        let access: Schema.Access
    }

    /// The placeholder each candidate spelling was generated through, with that spelling.
    let aliases: [(alias: String, spelling: String)]
    /// The access of the schema, which bounds every generated declaration.
    let schemaAccess: Schema.Access
    /// Every identifier the schema's source spells, which no alias may take.
    let authoredIdentifiers: Set<String>
    /// The syntax of a spelling, which the schema keeps so no spelling is parsed again.
    var parse: (String) -> TypeSyntax = { TypeSyntax(stringLiteral: $0) }

    /// The declarations with each use spelled as authored or through its alias, the aliases to
    /// declare, named `_StateMachineType1`, `_StateMachineType2`, and so on in declaration order, and
    /// the members of generated scopes read to decide, each scope's once however many uses it holds.
    func apply(to declarations: [DeclSyntax]) -> (declarations: [DeclSyntax], aliases: [Alias], membersRead: Int) {
        let spellings = Dictionary(uniqueKeysWithValues: aliases.map { ($0.alias, $0.spelling) })
        let freeNames = spellings.mapValues { Schema.freeNames(parse($0)) }
        func placeholder(_ token: TokenSyntax) -> IdentifierTypeSyntax? {
            guard case .identifier(let name) = token.tokenKind, spellings[name] != nil,
                let reference = token.parent?.as(IdentifierTypeSyntax.self), reference.name.id == token.id,
                reference.moduleSelector == nil, reference.genericArgumentClause == nil
            else { return nil }
            return reference
        }
        // Each use either keeps its alias, requiring an access of it, or is spelled as authored.
        var capturing: [String: [Schema.Access]] = [:]
        var restored: Set<SyntaxIdentifier> = []
        var scopes = ScopeNames()
        for declaration in declarations {
            for token in declaration.tokens(viewMode: .sourceAccurate) {
                guard let reference = placeholder(token) else { continue }
                let name = token.text
                if !scopes.capture(freeNames[name] ?? [], around: Syntax(reference)) {
                    restored.insert(token.id)
                } else {
                    capturing[name, default: []].append(access(of: Syntax(reference)))
                }
            }
        }
        var kept: [Alias] = []
        var names: [String: String] = [:]
        var next = 1
        for (alias, spelling) in aliases {
            guard let highest = capturing[alias]?.max(by: { $0.rank < $1.rank }) else { continue }
            while authoredIdentifiers.contains("_StateMachineType\(next)") { next += 1 }
            let name = "_StateMachineType\(next)"
            names[alias] = name
            next += 1
            kept.append(Alias(name: name, spelling: spelling, access: highest))
        }
        let rewritten = declarations.map { declaration -> DeclSyntax in
            var text = ""
            var changed = false
            for token in declaration.tokens(viewMode: .sourceAccurate) {
                guard placeholder(token) != nil,
                    let spelled = restored.contains(token.id) ? spellings[token.text] : names[token.text]
                else {
                    text += token.description
                    continue
                }
                text += token.leadingTrivia.description + spelled + token.trailingTrivia.description
                changed = true
            }
            return changed ? DeclSyntax(stringLiteral: text) : declaration
        }
        return (rewritten, kept, scopes.membersRead)
    }

    /// The type names each generated scope declares, read once per scope: the members and generic
    /// parameters of a type, the generic parameters of a function, and the type witnesses a restoring
    /// `Local` infers from its restoring resets.
    private struct ScopeNames {
        private var declared: [SyntaxIdentifier: Set<String>] = [:]
        /// The members read so far, each scope's once.
        private(set) var membersRead = 0

        /// Whether a scope around `node` declares a type named like one of `names`, which would capture it.
        mutating func capture(_ names: Set<String>, around node: Syntax) -> Bool {
            var current = node.parent
            while let ancestor = current {
                if names.contains(where: declaredNames(of: ancestor).contains) { return true }
                current = ancestor.parent
            }
            return false
        }

        private mutating func declaredNames(of scope: Syntax) -> Set<String> {
            guard scope.isProtocol(DeclGroupSyntax.self) || scope.isProtocol(WithGenericParametersSyntax.self) else {
                return []
            }
            if let names = declared[scope.id] { return names }
            var names: Set<String> = []
            if let group = scope.asProtocol(DeclGroupSyntax.self) {
                for member in group.memberBlock.members {
                    membersRead += 1
                    if let name = SpellingShield.typeName(member.decl) { names.insert(name) }
                }
                if group.inheritanceClause?.inheritedTypes
                    .contains(where: {
                        $0.type.trimmedDescription.hasSuffix("RestoringLocalStateMachine")
                    }) == true
                {
                    names.formUnion(["RestorationArchive", "RestorationRejection"])
                }
            }
            if let generic = scope.asProtocol(WithGenericParametersSyntax.self) {
                for parameter in generic.genericParameterClause?.parameters ?? [] {
                    names.insert(parameter.name.lookupName)
                }
            }
            declared[scope.id] = names
            return names
        }
    }

    fileprivate static func typeName(_ declaration: DeclSyntax) -> String? {
        if let alias = declaration.as(TypeAliasDeclSyntax.self) { return alias.name.lookupName }
        if let type = declaration.as(StructDeclSyntax.self) { return type.name.lookupName }
        if let type = declaration.as(EnumDeclSyntax.self) { return type.name.lookupName }
        if let type = declaration.as(ClassDeclSyntax.self) { return type.name.lookupName }
        if let type = declaration.as(ActorDeclSyntax.self) { return type.name.lookupName }
        if let type = declaration.as(ProtocolDeclSyntax.self) { return type.name.lookupName }
        if let type = declaration.as(AssociatedTypeDeclSyntax.self) { return type.name.lookupName }
        return nil
    }

    /// The access a use requires of its alias: file-private inside a body, and otherwise the access of
    /// the declaration that holds it within every enclosing declaration, bounded by the schema's.
    private func access(of node: Syntax) -> Schema.Access {
        var result = schemaAccess == .private ? Schema.Access.fileprivate : schemaAccess
        var held = false
        var current = node.parent
        while let ancestor = current {
            if !held {
                // A body needs the alias only to be visible.
                if ancestor.is(CodeBlockSyntax.self) || ancestor.is(AccessorBlockSyntax.self)
                    || ancestor.is(ClosureExprSyntax.self)
                {
                    return .fileprivate
                }
                held = ancestor.is(DeclSyntax.self)
            }
            if ancestor.is(DeclSyntax.self), !ancestor.is(EnumCaseDeclSyntax.self),
                let modified = ancestor.asProtocol(WithModifiersSyntax.self)
            {
                let declared =
                    modified.modifiers.lazy.compactMap { Schema.Access(rawValue: $0.name.unescaped) }.first ?? .internal
                if declared.rank < result.rank { result = declared }
            }
            current = ancestor.parent
        }
        return result == .private ? .fileprivate : result
    }
}

extension Schema.Access {
    /// The access's order from most to least restrictive.
    var rank: Int {
        switch self {
        case .private: 0
        case .fileprivate: 1
        case .internal: 2
        case .package: 3
        case .public: 4
        }
    }
}
