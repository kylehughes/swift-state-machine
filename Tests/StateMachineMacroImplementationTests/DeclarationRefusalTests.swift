import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

/// Declarations Swift accepts that the expansion could not compile against, refused by the macro with
/// a message that names what to change.
struct DeclarationRefusalTests {
    private static func diagnostics(_ text: String) -> [String]? { DeclarationHygieneTests.diagnostics(text) }

    static let seed = #"""
        @StateMachine(mode: .shared)
        enum Approval {
            struct Draft {}
            struct Approved {}
            @Initial case draft(Draft)
            @Terminal case approved(Approved)
            enum Input { case approve }
            @Operation(activeIn: [Draft.self])
            enum Check { typealias Output = Int }
            @Transition(on: Input.approve, starts: [Check.self])
            static func approve(_ source: Draft) -> Change<Draft, Effect.Approve> { fatalError() }
            @Transition(onSuccess: Check.self)
            static func checked(_ source: Draft, _ value: Int) -> Approved { fatalError() }
        }
        """#

    private static func replacing(_ plain: String, _ spelled: String) -> String {
        let source = seed.replacingOccurrences(of: plain, with: spelled)
        #expect(source != seed)
        return source
    }

    /// The macro cannot tell which `#if` clause the build takes, so it refuses one among the members it
    /// reads rather than leave what is inside out of the graph.
    @Test func conditionalMembersAreRefused() {
        let message =
            "Move this '#if' outside the schema or into a function body: the macro cannot tell which clause the build takes, so it would read no declaration inside it."
        #expect(Self.diagnostics(Self.replacing("struct Draft {}", "#if true\nstruct Draft {}\n#endif")) == [message])
        #expect(
            Self.diagnostics(
                Self.replacing("enum Input { case approve }", "enum Input {\n#if DEBUG\ncase approve\n#endif\n}")
            )
                == [message]
        )
        #expect(
            Self.diagnostics(
                Self.replacing(
                    "enum Check { typealias Output = Int }",
                    "enum Check {\n#if os(macOS)\ntypealias Output = Int\n#endif\n}"
                )
            ) == [message]
        )
        // A payload's own members and an authored body are not the macro's to read.
        #expect(
            Self.diagnostics(Self.replacing("struct Draft {}", "struct Draft {\n#if DEBUG\nvar note = 0\n#endif\n}"))
                == nil
        )
        #expect(
            Self.diagnostics(
                Self.replacing(
                    "-> Approved { fatalError() }",
                    "-> Approved {\n#if DEBUG\nprint(0)\n#endif\nfatalError()\n}"
                )
            ) == nil
        )
    }

    /// Generated code calls an authored function from nonisolated code, from every owner, and from members
    /// with only the schema's availability, so every attribute but the macro's markers and four of Swift's
    /// own is refused, however it is capitalized or qualified.
    @Test func attributesOnAuthoredFunctionsAreRefused() {
        func with(_ attribute: String) -> [String]? {
            Self.diagnostics(Self.replacing("    static func approve", "    @\(attribute)\n    static func approve"))
        }
        let custom = { (name: String) in
            "Remove '@\(name)': generated code calls this function from nonisolated code and from every owner, so it takes only Swift's @discardableResult, @inlinable, @inline, and @usableFromInline, and no attribute that may isolate it to a global actor such as MainActor."
        }
        for attribute in [
            "MainActor", "Swift.MainActor", "Swift::MainActor", "SomeGlobalActor", "uiActor", "Actors.ui", "concurrent",
            "objc", "preconcurrency", "_disfavoredOverload", "Sendable", "warn_unqualified_access", "`inlinable`",
            "Swift::inlinable",
        ] {
            let name =
                attribute.split(whereSeparator: { $0 == "." || $0 == ":" }).last.map(String.init)?
                .replacingOccurrences(of: "`", with: "") ?? attribute
            #expect(with(attribute) == [custom(name)], "\(attribute)")
        }
        let availability = { (name: String) in
            "Remove '@\(name)' and give the schema this availability instead: generated members call this function, and they have only the schema's availability."
        }
        for attribute in [
            "available(macOS 14, *)", "available(macOS 13, *)", "available(*, unavailable)",
            "available(*, deprecated, message: \"old\")", "available(macOS, obsoleted: 14)",
            "backDeployed(before: macOS 14)",
        ] {
            let name = String(attribute.prefix { $0 != "(" })
            #expect(with(attribute) == [availability(name)], "\(attribute)")
        }
        for attribute in ["inlinable", "discardableResult", "inline(__always)", "inline(never)", "usableFromInline"] {
            #expect(with(attribute) == nil, "\(attribute)")
        }
        let qualified = Self.replacing(
            "@Transition(on: Input.approve, starts:",
            "@StateMachine.Transition(on: Input.approve, starts:"
        )
        #expect(Self.diagnostics(qualified) == nil)
    }

    /// An attribute inside `#if` is one the macro cannot tell is there, on an authored function, a phase
    /// case, or a namespace, so it is refused wherever it is.
    @Test func conditionalAttributesAreRefused() {
        let message =
            "Move this '#if' out of the declaration's attributes: the macro cannot tell which clause the build takes, so it cannot tell which attributes the declaration has."
        for (plain, conditional) in [
            ("    static func approve", "    #if DEBUG\n    @MainActor\n    #endif\n    static func approve"),
            ("@Terminal case approved", "#if DEBUG\n@Terminal\n#endif\ncase approved"),
            ("@Operation(activeIn: [Draft.self])", "#if DEBUG\n@Operation(activeIn: [Draft.self])\n#endif"),
            ("    struct Draft {}", "    #if os(macOS)\n    @available(macOS 13, *)\n    #endif\n    struct Draft {}"),
        ] {
            #expect(Self.diagnostics(Self.replacing(plain, conditional)) == [message], "\(conditional)")
        }
    }

    /// An authored function is static with an access modifier and `nonisolated` as its only other
    /// modifiers; any other would change how generated code may call it, or Swift refuses it.
    @Test func modifiersOnAuthoredFunctionsAreChecked() throws {
        func with(_ modifiers: String) -> [String]? {
            Self.diagnostics(Self.replacing("    static func approve", "    \(modifiers) func approve"))
        }
        for modifiers in ["nonisolated static", "private static", "fileprivate static nonisolated", "static internal"] {
            #expect(with(modifiers) == nil, "\(modifiers)")
        }
        for (modifiers, refused) in [
            ("nonisolated(unsafe) static", "nonisolated(unsafe)"), ("static dynamic", "dynamic"),
            ("static mutating", "mutating"), ("final static", "final"),
            ("static nonisolated(nonsending)", "nonisolated(nonsending)"),
            ("static consuming", "consuming"), ("open static", "open"),
        ] {
            #expect(
                with(modifiers) == [
                    "Remove '\(refused)': an authored function is static, with an access modifier and nonisolated as its only other modifiers."
                ],
                "\(modifiers)"
            )
        }
        // A parameter specifier other than an ownership or `sending` changes what generated code may pass.
        for specifier in ["_const", "inout", "isolated"] {
            let source = Self.replacing("_ value: Int)", "_ value: \(specifier) Int)")
            let messages = try #require(Self.diagnostics(source), "\(specifier)")
            #expect(
                messages.count == 1
                    && messages[0].hasSuffix("without '\(specifier)'; generated code passes on the value it receives."),
                "\(messages)"
            )
        }
    }

    /// A declaration that the parser running the macro cut short at its nesting limit is diagnosed as
    /// such, rather than as missing the members it could not read, such as the `@Initial` case.
    @Test func aDeclarationPastTheParserNestingLimitIsDiagnosed() throws {
        let depth = 12
        let namespaces =
            (0 ..< depth).map { "enum N\($0) {" }.joined(separator: " ") + " typealias X = Swift::Int "
            + String(repeating: "} ", count: depth)
        let source = Self.seed.replacingOccurrences(
            of: "    struct Draft {}",
            with: "    \(namespaces)\n    struct Draft {}"
        )
        func diagnostics(limit: Int) throws -> [String]? {
            var text = source
            let syntax = text.withUTF8 { Parser.parse(source: $0, maximumNestingLevel: limit) }
            let declaration = try #require(syntax.statements.first?.item.as(EnumDeclSyntax.self))
            let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))
            do {
                _ = try Schema.parse(declaration, attribute: attribute, context: BasicMacroExpansionContext())
                return nil
            } catch let error as DiagnosticsError {
                return error.diagnostics.map(\.message)
            }
        }
        #expect(try diagnostics(limit: 256) == nil)
        let refused = try #require(try diagnostics(limit: depth))
        #expect(
            refused == [
                "The macro cannot read this schema in full: it nests deeper than the Swift parser that runs the macro reads: a debug build of SwiftSyntax, which a package builds when one of its test targets depends on SwiftSyntax, reads 20 levels of nested declarations, types, and expressions, and a release build reads 256. Nest less deeply, for example by moving nested types out of the schema."
            ]
        )
        // A declaration that does not parse is not read either, so no member it seems to lack is reported.
        let malformed = Self.seed.replacingOccurrences(of: "    struct Draft {}", with: "    struct Draft { var x: = }")
        #expect(
            DeclarationHygieneTests.diagnostics(malformed) == [
                "The macro cannot read this schema in full: it does not parse as Swift. Fix the syntax errors the compiler reports."
            ]
        )
    }

    /// `.parallel(limit:)` reads its limit as Swift reads an integer literal.
    @Test func admissionLimitsAreReadAsIntegerLiterals() throws {
        func limit(_ spelled: String) throws -> Schema.Admission? {
            let source = Self.replacing(
                "@Operation(activeIn: [Draft.self])",
                "@Operation(activeIn: [Draft.self], admission: .parallel(limit: \(spelled)))"
            )
            return try DeclarationHygieneTests.parse(source).operations.first?.admission
        }
        for spelled in ["10", "1_0", "0xA", "0o12", "0b1010", "0b10_10", "010"] {
            #expect(try limit(spelled) == .parallel(limit: 10), "\(spelled)")
        }
        let message = "Use .parallel(limit: N) with a positive integer literal representable as Int."
        for spelled in ["0", "-1", "-0x1", "0x0", "9_223_372_036_854_775_808", "+1", "N", "1.0"] {
            let source = Self.replacing(
                "@Operation(activeIn: [Draft.self])",
                "@Operation(activeIn: [Draft.self], admission: .parallel(limit: \(spelled)))"
            )
            #expect(Self.diagnostics(source) == [message], "\(spelled)")
        }
        #expect(try limit("9_223_372_036_854_775_807") == .parallel(limit: Int.max))
    }

    /// A public or package schema generates members of its access that name its payloads, `Input`, and its
    /// namespaces with their aliases, so each declaration it names needs that access.
    @Test func aPublicSchemaNeedsItsNamedDeclarationsPublic() {
        let message = { (name: String, access: String) in
            "Declare '\(name)' \(access): the \(access) schema 'Approval' generates \(access) members that name it."
        }
        for access in ["public", "package"] {
            let schema = Self.replacing("enum Approval {", "\(access) enum Approval {")
            #expect(Self.diagnostics(schema) == [message("Draft", access)])
            let declared = schema.replacingOccurrences(of: "    struct Draft", with: "    \(access) struct Draft")
                .replacingOccurrences(of: "    struct Approved", with: "    public struct Approved")
            #expect(Self.diagnostics(declared) == [message("Input", access)])
            let input = declared.replacingOccurrences(of: "    enum Input", with: "    \(access) enum Input")
            #expect(Self.diagnostics(input) == [message("Check", access)])
            let namespace = input.replacingOccurrences(of: "    enum Check", with: "    \(access) enum Check")
            #expect(Self.diagnostics(namespace) == [message("Output", access)])
            let alias = namespace.replacingOccurrences(of: "typealias Output", with: "\(access) typealias Output")
            #expect(Self.diagnostics(alias) == nil)
        }
        // An internal schema needs nothing more.
        #expect(Self.diagnostics(Self.seed) == nil)
    }

    /// Only a declaration that a generated signature names, as Swift resolves the spelling where it is
    /// written, needs the schema's access: a helper of the same name in another scope keeps its own.
    @Test func aPublicSchemaChecksOnlyTheDeclarationsItsSignaturesName() {
        let message = { (name: String) in
            "Declare '\(name)' public: the public schema 'Approval' generates public members that name it."
        }
        let schema = Self.seed.replacingOccurrences(of: "enum Approval {", with: "public enum Approval {")
            .replacingOccurrences(of: "    struct Draft", with: "    public struct Draft")
            .replacingOccurrences(of: "    struct Approved", with: "    public struct Approved")
            .replacingOccurrences(of: "    enum Input", with: "    public enum Input")
            .replacingOccurrences(
                of: "    enum Check { typealias Output = Int }",
                with: "    public enum Check { public typealias Output = Int; struct Helper {} }"
            )
        #expect(Self.diagnostics(schema) == nil)
        func adding(_ declaration: String) -> String {
            schema.replacingOccurrences(
                of: "    public struct Draft {}",
                with: "    public struct Draft {}\n    \(declaration)"
            )
        }
        // Helpers whose basenames are those of the types the signatures name.
        for helper in [
            "private enum Notes { struct Draft {} }", "enum Notes { struct Input {}; struct Output {} }",
            "fileprivate struct Holder { typealias Check = Int; typealias Approved = Int }",
        ] {
            #expect(Self.diagnostics(adding(helper)) == nil, "\(helper)")
        }
        // A type that a signature names through a path, in a payload, an output, a failure, or saved data.
        let named = adding("enum Notes { struct Detail {}; struct Problem: Error {} }")
        let payload =
            named.replacingOccurrences(
                of: "enum Input { case approve }",
                with: "enum Input { case approve(Notes.Detail) }"
            )
            .replacingOccurrences(
                of: "static func approve(_ source: Draft)",
                with: "static func approve(_ source: Draft, _ note: Notes.Detail)"
            )
        #expect(Self.diagnostics(payload) == [message("Notes")])
        let nested = payload.replacingOccurrences(of: "enum Notes {", with: "public enum Notes {")
        #expect(Self.diagnostics(nested) == [message("Detail")])
        let output =
            named.replacingOccurrences(
                of: "public typealias Output = Int",
                with: "public typealias Output = Notes.Detail"
            )
            .replacingOccurrences(of: "_ value: Int)", with: "_ value: Notes.Detail)")
            .replacingOccurrences(of: "enum Notes {", with: "public enum Notes {")
        #expect(Self.diagnostics(output) == [message("Detail")])
        let failure =
            named.replacingOccurrences(
                of: "-> Change<Draft, Effect.Approve>",
                with: "throws(Notes.Problem) -> Change<Draft, Effect.Approve>"
            )
            .replacingOccurrences(of: "enum Notes {", with: "public enum Notes {")
        #expect(Self.diagnostics(failure) == [message("Problem")])
        // An operation's alias names a type inside its namespace, where it is written.
        let inside =
            schema.replacingOccurrences(
                of: "public typealias Output = Int; struct Helper {}",
                with: "public typealias Output = Helper; struct Helper {}"
            )
            .replacingOccurrences(of: "_ value: Int)", with: "_ value: Check.Helper)")
        #expect(Self.diagnostics(inside) == [message("Helper")])
    }
}
