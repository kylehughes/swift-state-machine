import Foundation
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax

/// The rule that lets the macro compare names as `String`s.
///
/// Swift tells two identifiers apart by their bytes, so `Café` spelled with U+00E9 and `Café` spelled
/// with U+0065 U+0301 are two different names. `String` equality uses canonical equivalence, which
/// treats those two as equal. Unicode Normalization Form C spells each class of canonically equivalent
/// text one way, so two names written in it are `String`-equal exactly when their bytes are equal, and
/// a name written in it equals an ASCII literal exactly when it is that literal. The macro therefore
/// reads a declaration only once every name it interprets is written in Normalization Form C, and from
/// then on compares, hashes, and orders names as `String`s.
///
/// The bodies of functions, initializers, and accessors, and closures, are the author's code, which the
/// macro never interprets, so a name there may be written in any form, as an imported declaration's name
/// may need to be. The only readings that reach such a name are the scans of every token in the schema
/// for the names it spells, and each passes over a token that is not ``TokenSyntax/isComposed``. No such
/// token has the bytes of a composed name, an ASCII one included, so it is not any name they look for.
enum Normalization {
    /// Refuses `declaration` when a name it interprets is not written in Normalization Form C, with one
    /// diagnostic at each such token.
    ///
    /// Every token is checked, wherever it is, except the contents of string and regex literals, which
    /// name nothing, and the tokens of a function's, initializer's, or accessor's body or of a closure.
    /// That covers declared and referenced names, labels, members, attributes and their arguments,
    /// signatures, and default values, including in nested types.
    static func requireComposedNames(in declaration: some SyntaxProtocol) throws {
        var diagnostics: [Diagnostic] = []
        for token in declaration.tokens(viewMode: .sourceAccurate) {
            switch token.tokenKind {
            case .stringSegment, .regexLiteralPattern: continue
            default: break
            }
            // Only a token that is not composed, which is never ASCII, needs to know where it is.
            guard !token.isComposed, !isInExemptBody(token) else { continue }
            diagnostics.append(diagnostic(token))
        }
        guard diagnostics.isEmpty else { throw DiagnosticsError(diagnostics: diagnostics) }
    }

    /// Whether `token` is in the body of a function, initializer, or accessor, or in a closure, which the
    /// macro never reads.
    ///
    /// A body inside a type, an attribute, or an enum case's payload, such as a closure in a generic
    /// argument, an attribute's argument, or the initial phase's default, is part of what the macro reads
    /// and refuses by its shape, so it is checked too. An outer body still exempts it.
    private static func isInExemptBody(_ token: TokenSyntax) -> Bool {
        var exempt = false
        var current = token.parent
        while let ancestor = current {
            if ancestor.is(CodeBlockSyntax.self) || ancestor.is(AccessorBlockSyntax.self)
                || ancestor.is(ClosureExprSyntax.self)
            {
                exempt = true
            } else if ancestor.is(TypeSyntax.self) || ancestor.is(AttributeSyntax.self)
                || ancestor.is(EnumCaseParameterClauseSyntax.self)
            {
                exempt = false
            }
            current = ancestor.parent
        }
        return exempt
    }

    /// Whether `text` has the bytes of its Normalization Form C.
    static func isComposed(_ text: String) -> Bool {
        text.utf8.elementsEqual(text.precomposedStringWithCanonicalMapping.utf8)
    }

    private static func diagnostic(_ token: TokenSyntax) -> Diagnostic {
        let composed = token.text.precomposedStringWithCanonicalMapping
        let reason =
            "Swift tells names apart by their bytes, but the macro compares them as text, which takes 'é' written as one character and as 'e' with a combining accent for one name."
        // No fix-it rewrites the token because Swift tells the two spellings apart, so the composed one
        // could name another declaration, or none, where the author's names one outside the schema.
        guard case .identifier = token.tokenKind, !lexesAsOneName(composed) else {
            return Diagnostic(
                node: token,
                message: Message(
                    message:
                        "The name '\(token.text)' is not in Unicode Normalization Form C; spell it '\(composed)'. \(reason)"
                )
            )
        }
        // Composing some characters gives ASCII punctuation, as U+1FEF GREEK VARIA gives a backtick.
        return Diagnostic(
            node: token,
            message: Message(
                message:
                    "The name '\(token.text)' is not in Unicode Normalization Form C, and composed it reads '\(composed)', which is no name; spell it with other characters. \(reason)"
            )
        )
    }

    /// Whether `text` lexes as one identifier with exactly its bytes.
    private static func lexesAsOneName(_ text: String) -> Bool {
        let tokens = Parser.parse(source: text).tokens(viewMode: .sourceAccurate).filter { $0.tokenKind != .endOfFile }
        guard tokens.count == 1, let only = tokens.first, case .identifier = only.tokenKind else { return false }
        return only.text.utf8.elementsEqual(text.utf8)
    }

    private struct Message: DiagnosticMessage {
        let message: String
        var diagnosticID: MessageID { MessageID(domain: "StateMachine", id: "uncomposedName") }
        var severity: DiagnosticSeverity { .error }
    }
}

extension TokenSyntax {
    /// Whether the token's text, and its name without backticks, are written in Normalization Form C.
    var isComposed: Bool {
        // ASCII text is in every normalization form, and most names are ASCII.
        text.utf8.allSatisfy { $0 < 0x80 } || (Normalization.isComposed(text) && Normalization.isComposed(lookupName))
    }
}

extension String {
    /// The text in Normalization Form C.
    ///
    /// A name the macro derives by changing the case of an authored name or by joining two of them can
    /// leave the form, as `ΐ` upper-cases to `Ι` and two combining marks. Each derived name passes through
    /// this property so it too is compared as text exactly as Swift compares it, by its bytes.
    var composed: String { utf8.allSatisfy { $0 < 0x80 } ? self : precomposedStringWithCanonicalMapping }
}
