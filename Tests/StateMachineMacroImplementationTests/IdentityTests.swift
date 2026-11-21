import Foundation
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

/// Two spellings Swift reads as one type or one name give the same generated code, and two it tells apart
/// are never merged: every name is written in Normalization Form C, keys are ordered by their structure,
/// and every reading kept for reuse passes one admission rule.
struct IdentityTests {
    private static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }
    private static func diagnostics(_ text: String) -> [String]? { DeclarationHygieneTests.diagnostics(text) }

    private static func generated(_ text: String) throws -> String {
        try Generator(schema: parse(text)).members().map(\.description).joined(separator: "\n")
    }

    /// `é` as one scalar, and as `e` followed by a combining acute accent: two names to Swift.
    static let precomposed = "Caf\u{E9}"
    static let decomposed = "Cafe\u{301}"

    /// The diagnostic at a name not written in Normalization Form C.
    static func uncomposed(_ name: String) -> String {
        let composed = name.precomposedStringWithCanonicalMapping
        return "The name '\(name)' is not in Unicode Normalization Form C; spell it '\(composed)'. "
            + Self.reason
    }

    /// The diagnostic at a name whose composed spelling is no name.
    static func uncomposable(_ name: String) -> String {
        let composed = name.precomposedStringWithCanonicalMapping
        return
            "The name '\(name)' is not in Unicode Normalization Form C, and composed it reads '\(composed)', which is no name; spell it with other characters. "
            + Self.reason
    }

    static let reason =
        "Swift tells names apart by their bytes, but the macro compares them as text, which takes 'é' written as one character and as 'e' with a combining accent for one name."

    // MARK: Names in Normalization Form C

    /// A name the macro interprets must be written in Normalization Form C.
    ///
    /// One written otherwise is diagnosed at its token, without a fix-it, since the composed spelling is
    /// another name to Swift, and its composed spelling compiles. A body or closure, which the macro never
    /// reads, may hold one.
    @Test func everyNameIsWrittenInNormalizationFormC() throws {
        func flow(_ name: String) -> String {
            """
            @StateMachine(mode: .shared)
            enum Flow {
                struct Start {}
                struct Done {}
                @Initial case start(Start)
                @Terminal case done(Done)
                enum Input { case go }
                @Transition(on: Input.go)
                static func \(name)(_ source: Start) -> Done { fatalError() }
            }
            """
        }
        #expect(Self.diagnostics(flow("caf\u{E9}")) == nil)
        let syntax = Parser.parse(source: flow("cafe\u{301}"))
        let declaration = try #require(syntax.statements.first?.item.as(EnumDeclSyntax.self))
        let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))
        do {
            _ = try Schema.parse(declaration, attribute: attribute, context: BasicMacroExpansionContext())
            Issue.record("Expected the decomposed name to be refused")
        } catch let error as DiagnosticsError {
            let diagnostic = try #require(error.diagnostics.first)
            #expect(error.diagnostics.count == 1)
            #expect(diagnostic.message == Self.uncomposed("cafe\u{301}"))
            #expect(diagnostic.node.trimmedDescription.utf8.elementsEqual("cafe\u{301}".utf8))
            #expect(diagnostic.fixIts.isEmpty)
        }
        // Every interpreted position is checked: a referenced type, a label, a member after a period, a
        // default value and an interpolation in it, a conditional compilation block, active or not, a
        // nested type's members, a key path, a raw identifier, a generic parameter, a marker's argument,
        // the default of the initial phase, and an operator, whose marks are out of canonical order.
        let d = Self.decomposed
        let positions = [
            "typealias Alias = \(d)",
            "static func f(\(d) value: Swift::Int) {}",
            "typealias Alias = Swift::Int.\(d)",
            "@available(*, deprecated, renamed: \"x\") static func f(_ x: \(d)) {}",
            "static func f(_ x: Swift::Int = \(d)) {}",
            "static func f(_ x: Swift::String = \"\\(\(d))\") {}",
            "#if DEBUG\nstatic func \(d)() {}\n#endif",
            "#if false\nstatic func \(d)() {}\n#else\nstatic func g() {}\n#endif",
            "struct Nested { struct Inner { var \(d): Swift::Int } }",
            "static let path = \\Done.\(d)",
            "typealias Alias = `\(d)`",
            "static func f<\(d)>(_ x: \(d)) {}",
            "@Transition(on: Input.\(d))\nstatic func g(_ source: Start) -> Done { fatalError() }",
            "static prefix func +\u{301}\u{316} (x: Done) -> Done { x }",
            "static let work: () -> \(d) = { fatalError() }",
            // A closure the macro reads as part of an attribute or a type is checked with it.
            "@Wrapped({ \(d) }) static func f() {}",
            "typealias Alias = Swift::Array<{ \(d) }>",
        ]
        for position in positions {
            let source = flow("finish")
                .replacingOccurrences(of: "struct Done {}", with: "struct Done {}\n    \(position)")
            let messages = try #require(Self.diagnostics(source), "\(position)")
            #expect(
                !messages.isEmpty && messages.allSatisfy { $0.hasPrefix("The name '") && $0.hasSuffix(Self.reason) },
                "\(position): \(messages)"
            )
        }
        // The body of a function, an initializer, or an accessor, and a closure, are the author's code, which
        // the macro never reads, so a name there may be written in any form, as an imported one may need.
        for body in [
            "static func helper() -> Swift::Int { let \(d) = 1; return \(d) }",
            "init() { let \(d) = 1; _ = \(d) }",
            "static var x: Swift::Int { $\(d) }",
            "static var y: Swift::Int { get { \(d) } }",
            "static let work: () -> Swift::Int = { let \(d) = 1; return \(d) }",
            "static let v = #m { \(d) }",
            // The Kelvin sign composes to `K`, but this name, to Swift, is not the expansion's `_StateMachineKey`.
            "static func helper() { _ = _StateMachine\u{212A}ey }",
        ] {
            let source = flow("finish").replacingOccurrences(of: "struct Done {}", with: "struct Done {}\n    \(body)")
            #expect(Self.diagnostics(source) == nil, "\(body)")
        }
        let edgeBody = flow("finish")
            .replacingOccurrences(of: "-> Done { fatalError() }", with: "-> Done { \(d)(); fatalError() }")
        #expect(Self.diagnostics(edgeBody) == nil)
        // A decomposed accent in a string's contents names nothing.
        let text = flow("finish")
            .replacingOccurrences(
                of: "struct Done {}",
                with: "struct Done {}\n    static let text = \"\(d)\""
            )
        #expect(Self.diagnostics(text) == nil)
    }

    /// An initial value constructed by a factory whose name differs from the payload's only in encoding:
    /// Swift calls the factory, which the macro would read as the payload's initializer.
    @Test func aFactoryNamedLikeTheInitialPayloadIsRefused() throws {
        func flow(_ factory: String) -> String {
            """
            @StateMachine(mode: .shared)
            enum Flow {
                struct \(Self.precomposed) { var value = 1 }
                static func \(factory)() -> \(Self.precomposed) { \(Self.precomposed)(value: 42) }
                @Initial @Terminal case ready(\(Self.precomposed) = \(factory)())
                enum Input {}
            }
            """
        }
        #expect(try Self.parse(flow("make")).initialDefault == "_StateMachineSchema.make()")
        #expect(Self.diagnostics(flow(Self.decomposed)) == Array(repeating: Self.uncomposed(Self.decomposed), count: 2))
    }

    /// A scope reference that names a static property, whose name differs from a case's only in
    /// encoding, rather than the case.
    @Test func aScopeMemberNamedLikeACaseIsRefused() throws {
        func flow(_ reference: String) -> String {
            """
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Loading {}
                @Initial case idle(Idle)
                case loading(Loading)
                enum Scope {
                    @Active(in: [Loading.self]) case caf\u{E9}
                    @Active(in: [Loading.self]) case other
                    static var cafe\u{301}: Scope { .other }
                }
                enum Input { case start, cancel }
                @Operation(scope: Scope.other)
                enum Fetch {}
                @Transition(on: Input.start, starts: [Fetch.self])
                static func begin(_ source: Idle) -> Change<Loading, Effect.Begin> { fatalError() }
                @Transition(on: Input.cancel, invalidates: [Scope.\(reference)])
                static func cancel(_ source: Loading) -> Idle { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func received(_ source: Loading) -> Idle { fatalError() }
            }
            """
        }
        #expect(Self.diagnostics(flow("other")) == Array(repeating: Self.uncomposed("cafe\u{301}"), count: 1))
        #expect(Self.diagnostics(flow("cafe\u{301}")) == Array(repeating: Self.uncomposed("cafe\u{301}"), count: 2))
    }

    /// An `.ownedOnly` phase payload that names an alias, whose name differs from a struct's only in
    /// encoding, rather than the struct.
    @Test func anAliasNamedLikeANominalPayloadIsRefused() throws {
        func flow(_ payload: String) -> String {
            """
            @StateMachine(mode: .ownedOnly)
            enum Flow {
                struct \(Self.precomposed) {}
                typealias \(Self.decomposed) = Swift.Int
                @Initial @Terminal case ready(\(payload))
                enum Input {}
            }
            """
        }
        #expect(Self.diagnostics(flow(Self.precomposed)) == [Self.uncomposed(Self.decomposed)])
        #expect(Self.diagnostics(flow(Self.decomposed)) == Array(repeating: Self.uncomposed(Self.decomposed), count: 2))
    }

    /// Two candidate-free routers whose return types are outside aliases, of `Never` and of `Void`, whose
    /// names differ only in encoding: each needs its own check.
    @Test func routerReturnTypesNamedAlikeAreRefused() throws {
        func flow(_ second: String) -> String {
            """
            @StateMachine(mode: .shared, owners: [.owned])
            enum Flow {
                enum Problem: Error { case bad }
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case go, stop, halt }
                @Transition(on: Input.go)
                static func again(_ source: Idle) -> Idle { fatalError() }
                @Route(on: Input.stop)
                static func stop(_ source: Idle) throws(Problem) -> \(Self.precomposed) { throw .bad }
                @Route(on: Input.halt)
                static func halt(_ source: Idle) throws(Problem) -> \(second) { return () }
            }
            """
        }
        // Spelled apart, each router's return type is checked.
        let checks = try Self.parse(flow("Second")).typeChecks.map(\.reference)
        #expect(checks.contains(Self.precomposed) && checks.contains("Second"))
        #expect(Self.diagnostics(flow(Self.decomposed)) == [Self.uncomposed(Self.decomposed)])
    }

    /// U+1FEF GREEK VARIA composes to a backtick, so a name that begins with it is refused, without a
    /// fix-it, rather than read as a backticked name.
    @Test func aNameThatComposesToPunctuationIsRefused() throws {
        func flow(_ name: String) -> String {
            """
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                @Initial @Terminal case \(name)(Idle)
                enum Input {}
            }
            """
        }
        #expect(Self.diagnostics(flow("ready")) == nil)
        #expect(Self.diagnostics(flow("\u{1FEF}ready")) == [Self.uncomposable("\u{1FEF}ready")])
        // The Kelvin sign composes to the letter K, so `\u{212A}ey` is refused before it can be read as `Key`.
        #expect(Self.diagnostics(flow("\u{212A}ey")) == [Self.uncomposed("\u{212A}ey")])
    }

    // MARK: Keys by their structure

    static func pair(_ first: String, _ second: String, raw: String = "`N.P`") -> String {
        """
        @StateMachine(mode: .shared)
        enum Pair {
            enum N { protocol P {} }
            protocol \(raw) {}
            struct Problem<T>: Error {}
            struct Start {}
            struct Left {}
            struct Right {}
            @Initial case start(Start)
            @Terminal case left(Left)
            @Terminal case right(Right)
            enum Input { case pick(Swift::Int) }
            @Transition(on: Input.pick)
            static func goLeft(_ source: Start, _ value: Swift::Int) throws(Problem<\(first)>) -> Left { fatalError() }
            @Transition(on: Input.pick)
            static func goRight(_ source: Start, _ value: Swift::Int) throws(Problem<\(second)>) -> Right { fatalError() }
            @Route(on: Input.pick)
            static func pick(_ source: Start, _ value: Swift::Int) -> Route.Pick { fatalError() }
        }
        """
    }

    /// A nested protocol `N.P` and one named by the raw identifier `` `N.P` `` print alike; a composition
    /// of them keys alike in either order, so two edges that throw it share the router's failure.
    @Test func compositionsOrderTheirMembersByStructure() throws {
        let schema = try Self.parse(Self.pair("any N.P & `N.P`", "any `N.P` & N.P"))
        let nested = schema.typeScopes.resolve("N.P").key
        let raw = schema.typeScopes.resolve("`N.P`").key
        #expect(nested != raw && nested.description == raw.description)
        #expect(schema.typeScopes.resolve("N.P & `N.P`").key == schema.typeScopes.resolve("`N.P` & N.P").key)
        let text = try Self.generated(Self.pair("any N.P & `N.P`", "any `N.P` & N.P"))
        #expect(text.contains("func pick(_ input: Swift::Int) throws(Problem<any N.P & `N.P`>) -> Prepared"))
        // Attributes are ordered by their structure as well.
        #expect(
            schema.typeScopes.resolve("@Sendable @MainActor () -> Swift::Int").key
                == schema.typeScopes.resolve("@MainActor @Sendable () -> Swift::Int").key
        )
    }

    /// Spellings Swift reads as one type share a key, and spellings it tells apart do not: backticks that
    /// change nothing, parentheses, `Self.` and the schema's name, and member order in a composition keep a
    /// key; a raw identifier changes it.
    @Test(arguments: [
        ("`Problem`<Swift::Int>", "Problem<Swift::Int>", true),
        ("(Problem<Swift::Int>)", "Problem<Swift::Int>", true),
        ("((Problem<Swift::Int>))", "Problem<Swift::Int>", true),
        ("Self.Problem<Swift::Int>", "Problem<Swift::Int>", true),
        ("Pair.Problem<Swift::Int>", "`Pair`.`Problem`<Swift::Int>", true),
        ("N.P & `N.P` & Swift::Sendable", "Swift::Sendable & `N.P` & (N.P)", true),
        ("`N.P`", "N.P", false),
        ("`N.P`", "N.`P`", false),
    ])
    func spellingsKeyAsSwiftReadsThem(_ first: String, _ second: String, same: Bool) throws {
        let schema = try Self.parse(Self.pair("Swift::Int", "Swift::Int"))
        #expect((schema.typeScopes.resolve(first).key == schema.typeScopes.resolve(second).key) == same)
        #expect((schema.failureKey(first) == schema.failureKey(second)) == same)
    }

    /// The order is total and agrees with equality, whatever the keys print as.
    @Test func keysAreTotallyOrdered() throws {
        let schema = try Self.parse(Self.pair("N.P", "`N.P`"))
        let spellings = [
            "N.P", "`N.P`", "N.P & `N.P`", "[N.P]", "[`N.P`]", "(N.P, `N.P`)", "(`N.P`, N.P)", "N.P.Type",
            "Outside", "Outside.N", "(a: N.P)", "(b: N.P)", "() -> N.P", "() throws -> N.P", "Swift::Int",
        ]
        let keys = spellings.map { schema.typeScopes.resolve($0).key }
        for a in keys {
            #expect(!(a < a))
            for b in keys {
                #expect((a < b) || (b < a) || a == b)
                #expect(!((a < b) && (b < a)))
                for c in keys where a < b && b < c { #expect(a < c) }
            }
        }
    }

    // MARK: Admission

    // The key budget's single admission rule is checked through the compiler by GMT-path-key-budget: its
    // 1 025-node keys hash too deeply for a test thread's stack in a debug build.

    /// An alias that names another alias with its key unchanged keeps that reading's identity, so a
    /// composition of 300 aliases of one 500-protocol composition flattens it once, as 300 uses of the
    /// composition's own name do.
    @Test func transparentAliasesOfACompositionFlattenItOnce() throws {
        func schema(_ count: Int, throughAliases: Bool) -> String {
            let protocols = (0 ..< 500).map { "protocol P\($0) {}" }.joined(separator: "; ")
            let all = "typealias All = " + (0 ..< 500).map { "P\($0)" }.joined(separator: " & ")
            let aliases = (0 ..< count).map { "typealias A\($0) = All" }.joined(separator: "; ")
            let output =
                "any " + (0 ..< count).map { throughAliases ? "A\($0)" : "All" }.joined(separator: " & ")
            return TypeResolutionTests.loading(
                aliases: "typealias Output = \(output)",
                declarations: [protocols, all, aliases].joined(separator: "; "),
                edges:
                    "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Load.Output) -> Idle { fatalError() }"
            )
        }
        let direct = try Self.parse(schema(300, throughAliases: false))
        let aliased = try Self.parse(schema(300, throughAliases: true))
        #expect(direct.typeScopes.resolve("Load.Output").key == aliased.typeScopes.resolve("Load.Output").key)
        #expect(aliased.typeScopes.work.flattened == direct.typeScopes.work.flattened)
    }

    /// An identifier token's name is looked up once however many generic uses reach it, so a long name
    /// spelled inside an alias read with many bindings is hashed once.
    @Test(arguments: [true, false])
    func aLongNameIsLookedUpOncePerToken(declared: Bool) throws {
        let name = "Long" + String(repeating: "x", count: 200_000)
        func schema(_ count: Int) -> String {
            TypeResolutionTests.loading(
                aliases: "typealias Output = (" + (0 ..< count).map { "X<C\($0)>" }.joined(separator: ", ") + ")",
                // A name declared outside the schema is as long to read as one it declares.
                declarations: (declared ? "struct \(name) {}; " : "") + "typealias X<T> = (T, \(name), Outer.\(name)); "
                    + (0 ..< count).map { "struct C\($0) {}" }.joined(separator: "; "),
                edges:
                    "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Load.Output) -> Idle { fatalError() }"
            )
        }
        let counts = [500, 1_000, 2_000, 4_000]
        var named: [Int] = []
        for count in counts {
            let schema = try Self.parse(schema(count))
            _ = schema.typeScopes.resolve("Load.Output")
            named.append(schema.typeScopes.work.named)
        }
        // Each use's own two tokens are looked up, once; the alias's spelling, the long name among it,
        // adds the same few lookups however many uses read it.
        let added = zip(counts, named).map { count, named in named - 2 * count }
        #expect(Set(added).count == 1 && added[0] <= 8, "\(named)")
    }

    // MARK: Routed closure payloads

    /// A router and its edges that differ in taking a closure payload `@escaping` give a routed method
    /// that takes it escaping, `__shared` when one sends it, and never `borrowing`.
    @Test func mixedEscapingGivesAnEscapingRoutedParameter() throws {
        func bench(_ router: String, _ first: String, _ second: String) -> String {
            """
            @StateMachine(mode: .isolated, owners: [.owned])
            enum Bench {
                typealias Work = @Sendable () -> Swift::Int
                struct Idle {}
                struct Ran {}
                struct Kept {}
                @Initial case idle(Idle)
                @Terminal case ran(Ran)
                @Terminal case kept(Kept)
                enum Input: Swift::Sendable { case offer(Work) }
                @Route(on: Input.offer)
                static func choose(_ source: Idle, _ work: \(router)Work) -> Route.Choose { fatalError() }
                @Transition(on: Input.offer)
                static func run(_ source: Idle, _ work: \(first)Work) -> Ran { fatalError() }
                @Transition(on: Input.offer)
                static func keep(_ source: Idle, _ work: \(second)Work) -> Kept { fatalError() }
            }
            """
        }
        for (router, first, second, parameter) in [
            ("borrowing ", "borrowing ", "borrowing @escaping ", "_ input: @escaping Work"),
            ("__shared ", "", "consuming sending @escaping ", "_ input: __shared sending @escaping Work"),
            ("borrowing @escaping ", "borrowing @escaping ", "borrowing @escaping ", "_ input: @escaping Work"),
            ("consuming @escaping ", "borrowing ", "__owned ", "_ input: @escaping Work"),
        ] {
            let text = try Self.generated(bench(router, first, second))
            #expect(text.contains("consuming func choose(\(parameter)) ->"), "\(router)| \(first)| \(second)")
            #expect(!text.contains("_stateMachineCopy"))
        }
    }

    /// A value generic argument is an integer literal, read by its value: `10`, `1_0`, `0xA`, `0o12`, and
    /// `0b1010` are one argument, so a routed group that throws them shares one failure type.
    @Test func integerLiteralArgumentsAreReadByTheirValue() throws {
        func flow(_ router: String, _ left: String, _ right: String) -> String {
            """
            @StateMachine(mode: .shared)
            enum Flow {
                struct Problem<let N: Int>: Error {}
                struct Idle {}
                struct Left {}
                struct Right {}
                @Initial case idle(Idle)
                @Terminal case left(Left)
                @Terminal case right(Right)
                enum Input { case go }
                @Route(on: Input.go)
                static func choose(_ source: Idle) throws(Problem<\(router)>) -> Route.Choose { fatalError() }
                @Transition(on: Input.go)
                static func left(_ source: Idle) throws(Problem<\(left)>) -> Left { fatalError() }
                @Transition(on: Input.go)
                static func right(_ source: Idle) throws([\(right) of Swift::Int]) -> Right { fatalError() }
            }
            """
        }
        let scopes = LexicalScopes(
            try #require(Parser.parse(source: flow("1", "1", "1")).statements.first?.item.as(EnumDeclSyntax.self))
        )
        let ten = scopes.resolve("Problem<10>").key
        for spelling in ["Problem<1_0>", "Problem<0xA>", "Problem<0o12>", "Problem<0b10_10>", "Problem<010>"] {
            #expect(scopes.resolve(spelling).key == ten, "\(spelling)")
        }
        #expect(scopes.resolve("Problem<11>").key != ten)
        #expect(scopes.resolve("Problem<-10>").key != ten)
        #expect(scopes.resolve("[2 of Swift::Int]").key == scopes.resolve("Swift::InlineArray<0b10, Swift::Int>").key)
        #expect(
            Schema.spellingKey(TypeSyntax(stringLiteral: "Outside<1_0>"))
                == Schema.spellingKey(TypeSyntax(stringLiteral: "Outside<10>"))
        )
        let schema = try Self.parse(flow("10", "1_0", "2"))
        let route = try #require(schema.routes.first)
        // The right edge throws another type, so the group's failures differ.
        #expect(Generator(schema: schema).routedFailure(route) == "PreparationRejection")
        let shared = try Self.parse(
            flow("10", "1_0", "2").replacingOccurrences(of: "throws([2 of Swift::Int])", with: "throws(Problem<0xA>)")
        )
        #expect(try Generator(schema: shared).routedFailure(#require(shared.routes.first)) == "Problem<10>")
    }
}
