import SwiftDiagnostics
import SwiftSyntax
import Testing

@testable import StateMachineMacros

/// What the macro keeps of the author's text: graph spellings exactly as written, names compared without
/// backticks wherever they are read, and the roles of the identifiers inside a type spelling.
struct AuthoredTextTests {
    private static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }
    private static func diagnostics(_ text: String) -> [String]? { DeclarationHygieneTests.diagnostics(text) }

    // MARK: Graph spellings

    /// Each authored type spelling, as written, and what the graph shows for it: the author's tokens with
    /// one space wherever whitespace, a line break, or a comment separated two of them, and nothing else.
    static let spellings: [(written: String, shown: String)] = [
        ("Self.Detail", "Self.Detail"),
        ("Flow.Detail", "Flow.Detail"),
        ("(Detail)", "(Detail)"),
        ("((Detail))", "((Detail))"),
        ("Swift::Optional<Detail>", "Swift::Optional<Detail>"),
        ("Swift.Array<Detail>", "Swift.Array<Detail>"),
        ("Detail?", "Detail?"),
        ("[Detail]", "[Detail]"),
        ("[ Swift::String : Detail ]", "[ Swift::String : Detail ]"),
        ("(Swift::Int, Detail)", "(Swift::Int, Detail)"),
        ("(@Sendable () -> Swift::Int)", "(@Sendable () -> Swift::Int)"),
        ("@Sendable () -> Swift::Int", "@Sendable () -> Swift::Int"),
        ("`Detail`", "`Detail`"),
        ("Swift::Dictionary<Swift::String,\n        Detail>", "Swift::Dictionary<Swift::String, Detail>"),
        ("(Swift::Int, // first\n        Detail /* second */)", "(Swift::Int, Detail )"),
        ("Swift::Optional</* wrapped */Detail>", "Swift::Optional< Detail>"),
    ]

    /// The phase payload spellings Swift and the macro accept, each naming the schema's `Idle`.
    static let phaseSpellings: [(written: String, shown: String)] = [
        ("Idle", "Idle"),
        ("Self.Idle", "Self.Idle"),
        ("Flow.Idle", "Flow.Idle"),
        ("(Idle)", "(Idle)"),
        ("((Self.Idle))", "((Self.Idle))"),
        ("`Idle`", "`Idle`"),
        ("Self /* the schema */ .Idle", "Self .Idle"),
        ("Flow\n        .Idle", "Flow .Idle"),
    ]

    private static func spellingSchema(phase: String, type written: String) -> String {
        // A key must be hashable, which a function or a tuple is not.
        let key = written.contains("->") || written.contains(",") ? "Flow.Detail" : written
        return """
            @StateMachine(mode: .shared)
            enum Flow {
                struct Detail: Swift::Hashable, Swift::Sendable, Swift::Error {}
                struct Idle {}
                struct Busy {}
                @Initial case idle(\(phase))
                case busy(Busy)
                enum Input {
                    typealias Detail = Flow.Detail
                    case go(\(written))
                }
                @Operation(activeIn: [Busy.self])
                enum Load {
                    typealias Key = \(key)
                    typealias Input = \(written)
                    typealias Output = \(written)
                    typealias Failure = Flow.Detail
                }
                @Event
                enum Logged { typealias Payload = \(written) }
                @Transition(on: Input.go, starts: [Load.self], emits: [Logged.self])
                static func go(_ source: Idle, _ value: Swift::Int) -> Change<Busy, Effect.Go> { fatalError() }
                @Transition(onSuccess: Load.self)
                static func loaded(_ source: Busy, _ output: \(written)) -> Idle { fatalError() }
                @Transition(onFailure: Load.self)
                static func failed(_ source: Busy, _ failure: Detail) -> Idle { fatalError() }
            }
            """
    }

    /// The graph shows every type spelling as the author wrote it, at every field that holds one: a phase's
    /// payload, an input's payload, an operation's key, input, output, and failure, and an event's payload.
    @Test func everyGraphSpellingIsTheAuthorsText() throws {
        for (written, shown) in Self.spellings {
            let schema = try Self.parse(Self.spellingSchema(phase: "Idle", type: written))
            let key = written.contains("->") || written.contains(",") ? "Flow.Detail" : shown
            #expect(schema.inputs.map(\.payloadType) == [shown], "\(written)")
            let load = try #require(schema.operations.first)
            #expect([load.keyType, load.inputType, load.outputType] == [key, shown, shown], "\(written)")
            #expect(schema.events.map(\.payloadType) == [shown], "\(written)")
            let graph = Generator(schema: schema).graph()
            func literal(_ text: String) -> String { StringLiteralExprSyntax(content: text).description }
            #expect(graph.contains("Input(id: \"go\", payload: \(literal(shown)))"), "\(written)")
            #expect(
                graph.contains("key: \(literal(key)), input: \(literal(shown)), output: \(literal(shown))"),
                "\(written)"
            )
            #expect(graph.contains("failure: \"Flow.Detail\", canFail: true"), "\(written)")
            #expect(
                graph.contains("Event(id: \"Logged\", effect: \"logged\", payload: \(literal(shown)))"),
                "\(written)"
            )
        }
        for (written, shown) in Self.phaseSpellings {
            let schema = try Self.parse(Self.spellingSchema(phase: written, type: "Detail"))
            #expect(schema.phases.map(\.payloadSpelling) == [shown, "Busy"], "\(written)")
            // The phase is still identified by the type it names, however the case spells it.
            #expect(schema.phases.map(\.typeName) == ["Idle", "Busy"], "\(written)")
            let graph = Generator(schema: schema).graph()
            let literal = StringLiteralExprSyntax(content: shown).description
            #expect(graph.contains("Phase(id: \"idle\", payload: \(literal))"), "\(written)")
        }
    }

    // MARK: Identifier roles in a type spelling

    /// A built-in attribute's name, such as `Sendable` in `@Sendable`, is no reference, so a helper the
    /// public schema names `Sendable` needs no access of its own; a global actor's name is a reference.
    @Test func aBuiltInAttributeNamesNoDeclaration() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            public enum Flow: Swift::Sendable {
                enum Sendable {}
                public struct Idle: Swift::Sendable { public init() {} }
                @Initial case idle(Idle)
                public enum Input: Swift::Sendable { case run(@Sendable () -> Swift::Int) }
                @Transition(on: Input.run)
                static func run(_ source: Idle, _ value: @escaping @Sendable () -> Swift::Int) -> Idle { fatalError() }
            }
            """#
        #expect(Self.diagnostics(source) == nil)
        let spelling = SpellingSyntax().type("@Notes.Main @Sendable (Sendable) -> [Swift::Int]")
        #expect(TypeQualifier.lookupReferences(in: spelling).map(\.name.text) == ["Notes", "Sendable"])
        #expect(Schema.freeNames(spelling) == ["Notes", "Sendable"])
        #expect(
            TypeQualifier.qualify(spelling, owner: "Flow", names: ["Sendable", "Notes"])
                == "@Flow.Notes.Main @Sendable (Flow.Sendable) -> [Swift::Int]"
        )
        let unrelated = source.replacingOccurrences(
            of: "_ value: @escaping @Sendable () -> Swift::Int",
            with: "_ value: @escaping @Sendable (Sendable) -> Swift::Int"
        )
        #expect(
            Self.diagnostics(unrelated) == [
                "Declare 'Sendable' public: the public schema 'Flow' generates public members that name it."
            ]
        )
    }

    /// A member named through a namespace alias is the member of the type the alias names, so its access is
    /// checked as it is through that type's own name.
    @Test func aMemberThroughANamespaceAliasNeedsItsAccess() throws {
        let message = "Declare 'Hidden' public: the public schema 'Flow' generates public members that name it."
        for (base, aliases) in [
            ("Box", ""), ("N", "public typealias N = Box"), ("M", "public typealias N = Box\npublic typealias M = N"),
            ("Self.N", "public typealias N = Self.Box"),
            ("Flow.Outer.Inner", "public enum Outer { public typealias Inner = Flow.Box }"),
        ] {
            let source = """
                @StateMachine(mode: .shared)
                public enum Flow: Swift::Sendable {
                    public enum Box { struct Hidden: Swift::Error {} }
                    \(aliases)
                    public struct Idle: Swift::Sendable { public init() {} }
                    @Initial case idle(Idle)
                    public enum Input: Swift::Sendable { case run }
                    @Transition(on: Input.run)
                    static func run(_ source: Idle) throws(\(base).Hidden) -> Idle { fatalError() }
                }
                """
            #expect(Self.diagnostics(source) == [message], "\(base)")
            #expect(
                Self.diagnostics(source.replacingOccurrences(of: "struct Hidden", with: "public struct Hidden")) == nil,
                "\(base)"
            )
        }
        // An alias that never reaches a type stops after a bounded number of expansions.
        let cyclic = """
            @StateMachine(mode: .shared)
            public enum Flow: Swift::Sendable {
                public typealias A = B
                public typealias B = A
                public struct Idle: Swift::Sendable { public init() {} }
                @Initial case idle(Idle)
                public enum Input: Swift::Sendable { case run }
                @Transition(on: Input.run)
                static func run(_ source: Idle) throws(A.Hidden) -> Idle { fatalError() }
            }
            """
        _ = Self.diagnostics(cyclic)
    }

    /// A member of a generic type is one declaration whatever the type's arguments, so its access is checked
    /// through a specialized alias and a specialization written in place, and the generic parameters hide the
    /// schema's types of their names inside the generic type.
    @Test func aMemberOfASpecializedTypeNeedsItsAccess() throws {
        let message = "Declare 'Hidden' public: the public schema 'Flow' generates public members that name it."
        for (base, aliases) in [
            ("Box<Swift::Int>", ""), ("N", "public typealias N = Box<Swift::Int>"),
            ("M", "public typealias N = Box<Swift::Int>\npublic typealias M = N"),
            ("Self.N", "public typealias N = Self.Box<Swift::Int>"), ("Flow.Box<Idle>", ""),
            ("Box<Swift::Int>.Inner", ""),
        ] {
            let member = "\(base).Hidden"
            let source = """
                @StateMachine(mode: .shared)
                public enum Flow: Swift::Sendable {
                    public enum Box<T> {
                        struct Hidden: Swift::Error {}
                        public enum Inner { struct Hidden: Swift::Error {} }
                    }
                    \(aliases)
                    public struct Idle: Swift::Sendable { public init() {} }
                    @Initial case idle(Idle)
                    public enum Input: Swift::Sendable { case run }
                    @Transition(on: Input.run)
                    static func run(_ source: Idle) throws(\(member)) -> Idle { fatalError() }
                }
                """
            #expect(Self.diagnostics(source) == [message], "\(member)")
            #expect(
                Self.diagnostics(source.replacingOccurrences(of: "struct Hidden", with: "public struct Hidden")) == nil,
                "\(member)"
            )
        }
        // Inside `Box`, `T` is its parameter, not the schema's `T`, whose `Hidden` the spelling does not name.
        let parameter = """
            @StateMachine(mode: .shared)
            public enum Flow: Swift::Sendable {
                public enum Box<T> { public typealias Inner = T }
                public enum T { struct Hidden: Swift::Error {} }
                public enum Other { public struct Hidden: Swift::Error {} }
                public typealias N = Box<Other>
                public struct Idle: Swift::Sendable { public init() {} }
                @Initial case idle(Idle)
                public enum Input: Swift::Sendable { case run }
                @Transition(on: Input.run)
                static func run(_ source: Idle) throws(N.Inner.Hidden) -> Idle { fatalError() }
            }
            """
        #expect(Self.diagnostics(parameter) == nil)
    }

    // MARK: Names without backticks

    /// A label, an attribute's name, and a member read in an attribute's arguments are compared without
    /// backticks that change nothing, as Swift reads them.
    @Test func escapedNamesInAttributesAreTheirNames() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Busy {}
                @Initial case idle(Idle)
                case busy(Busy)
                enum Input { case go, run(@Sendable () -> Int) }
                @Operation(activeIn: [Busy.self], admission: .`parallel`(`limit`: 2))
                enum Load {}
                @Transition(on: Input.go, starts: [Load.self])
                static func go(_ source: Idle) -> Change<Busy, Effect.Go> { fatalError() }
                @`discardableResult`
                @Transition(on: Input.run)
                static func run(_ source: Idle, _ value: @`escaping` @Sendable () -> Int) -> Idle { fatalError() }
                @Transition(onSuccess: Load.self)
                static func loaded(_ source: Busy) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.operations.first?.admission == .parallel(limit: 2))
        let run = try #require(schema.transitions.first { $0.name == "run" })
        #expect(run.payloadConvention == "@escaping ")
        #expect(run.payloadType == "@Sendable () -> Int")
        // An escaped `_` is a label of its own, as Swift reads it.
        let labeled = source.replacingOccurrences(of: "_ source: Idle) -> Change", with: "`_` source: Idle) -> Change")
        #expect(
            Self.diagnostics(labeled) == [
                "Use a synchronous nongeneric static function with nonvariadic parameters and no defaults, each unlabeled except a completion's request, labeled request:."
            ]
        )
        let autoclosure = source.replacingOccurrences(of: "@`escaping` @Sendable", with: "@`autoclosure` @Sendable")
        #expect(
            Self.diagnostics(autoclosure) == [
                "Take this payload without '@autoclosure'; generated code passes on the value it receives, which an autoclosure would wrap again."
            ]
        )
    }

    // MARK: The schema's own name

    /// Only a declaration found where a type is looked up can hide the schema's name from generated code: a
    /// direct member type or alias of that name is refused, and a value or method of that name is accepted.
    @Test func onlyATypeOfTheSchemasNameShadowsIt() throws {
        let base = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case go }
                MEMBER
                @Transition(on: Input.go)
                static func go(_ source: Idle) -> Idle { fatalError() }
            }
            """#
        for value in [
            "static var Flow: Swift::Int { 0 }", "static let Flow = 0", "static func Flow() -> Swift::Int { 0 }",
            "var Flow: Swift::Int { 0 }",
        ] {
            #expect(Self.diagnostics(base.replacingOccurrences(of: "MEMBER", with: value)) == nil, "\(value)")
        }
        let message = "The schema name is reserved or shadowed by a direct member; choose a distinct domain name."
        for type in [
            "struct Flow {}", "enum Flow {}", "typealias Flow = Swift::Int", "protocol Flow {}", "actor Flow {}",
        ] {
            #expect(Self.diagnostics(base.replacingOccurrences(of: "MEMBER", with: type)) == [message], "\(type)")
        }
    }

    // MARK: Deprecation

    /// A deprecation on every platform, with any message and rename, is kept as written for the generated
    /// public members named for the function, and generated code calls the function through a requirement
    /// that a deprecated member witnesses.
    @Test func aDeprecationIsKeptForTheMembersNamedForTheFunction() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            public enum Flow {
                public struct Idle {}
                public struct Done {}
                public enum Problem: Swift::Error {}
                @Initial case idle(Idle)
                @Terminal case done(Done)
                public enum Input { case go(Swift::Int), pick, start }
                ATTRIBUTE
                @Transition(on: Input.go)
                static func go(_ source: Self.Idle, _ count: borrowing Swift::Int) throws(Problem) -> Idle { source }
                @Transition(on: Input.start)
                static func start(_ source: Idle) -> Idle { source }
                @available(*, deprecated)
                @Route(on: Input.pick)
                static func pick(_ source: Idle) -> Route.Pick { .left }
                @Transition(on: Input.pick)
                static func left(_ source: Idle) -> Idle { source }
                @Transition(on: Input.pick)
                static func right(_ source: Idle) -> Done { Done() }
                @available(*, deprecated, message: "Restore the current archive.")
                @Restoration
                static func restore(_ saved: Swift::Int) -> Restoration { .idle(Idle()) }
            }
            """#
        for attribute in [
            "@available(*, deprecated)", #"@available(*, deprecated, renamed: "start")"#,
            #"@available(*, deprecated, message: "Use start.", renamed: "start")"#,
            #"@available(*,deprecated,renamed:"start",message:"Use start.")"#,
        ] {
            let schema = try Self.parse(source.replacingOccurrences(of: "ATTRIBUTE", with: attribute))
            let go = try #require(schema.transitions.first { $0.name == "go" }?.deprecation)
            #expect(go.attribute == attribute)
            #expect(
                go.declaration
                    == "static func go(_ argument0: Flow.Idle, _ argument1: borrowing Swift::Int) throws(Problem) -> Idle"
            )
            #expect(go.call == "go(argument0, argument1)")
            let text = try Generator(schema: schema).members().map(\.description).joined(separator: "\n")
            #expect(text.contains("fileprivate protocol _StateMachineDeprecatedFunctions"))
            #expect(text.contains("\(attribute) public consuming func go(_ input: borrowing Swift::Int)"))
            #expect(text.contains("\(attribute) public func go(_ input: Swift::Int) throws(Problem) -> Prepared"))
            #expect(text.contains("@available(*, deprecated) public consuming func pick()"))
            #expect(
                text.contains(
                    #"@available(*, deprecated, message: "Restore the current archive.") public init(restoring"#
                )
            )
            // Generated code that is not deprecated calls the function through the requirement.
            #expect(text.components(separatedBy: "_StateMachineSchema.go(").count == 2)
            #expect(text.contains("try _StateMachineSchema.go(argument0, argument1)"))
            #expect(text.contains("try _StateMachineSchema._stateMachineDeprecated.go(phase, input)"))
        }
        let restoration = source.replacingOccurrences(of: "ATTRIBUTE", with: "")
            .replacingOccurrences(of: #"message: "Restore the current archive.""#, with: #"renamed: "restoreCurrent""#)
        #expect(
            Self.diagnostics(restoration) == [
                "Remove 'renamed:': the restoring initializers and resets this deprecation marks keep their names; describe the replacement with 'message:'."
            ]
        )
        let twice = source.replacingOccurrences(
            of: "ATTRIBUTE",
            with: "@available(*, deprecated)\n@available(*, deprecated)"
        )
        // SwiftParser reads the arguments of an escaped `available` as expressions, so the macro cannot read
        // them as a deprecation, and refuses the attribute as other availability.
        for refused in [twice, source.replacingOccurrences(of: "ATTRIBUTE", with: "@`available`(*, deprecated)")] {
            #expect(
                Self.diagnostics(refused) == [
                    "Remove '@available' and give the schema this availability instead: generated members call this function, and they have only the schema's availability."
                ]
            )
        }
    }

    /// The options after `*` are read by kind, in any order, as Swift reads them.
    ///
    /// They are one bare `deprecated`, and at most one `message:` and one `renamed:`; anything else is
    /// availability, which belongs on the schema.
    @Test func deprecationOptionsAreReadInAnyOrder() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            public enum Flow {
                public struct Idle {}
                @Initial case idle(Idle)
                public enum Input { case go, start }
                ATTRIBUTE
                @Transition(on: Input.go)
                static func go(_ source: Idle) -> Idle { source }
                @Transition(on: Input.start)
                static func start(_ source: Idle) -> Idle { source }
            }
            """#
        func orders(_ options: [String]) -> [[String]] {
            options.isEmpty
                ? [[]]
                : options.indices.flatMap { index in
                    var rest = options
                    let first = rest.remove(at: index)
                    return orders(rest).map { [first] + $0 }
                }
        }
        let message = #"message: "Use start.""#
        let renamed = #"renamed: "start""#
        for options in [["deprecated", message, renamed], ["deprecated", message], ["deprecated", renamed]] {
            for order in orders(options) {
                let attribute = "@available(*, \(order.joined(separator: ", ")))"
                let schema = try Self.parse(source.replacingOccurrences(of: "ATTRIBUTE", with: attribute))
                #expect(schema.transitions.first { $0.name == "go" }?.deprecation?.attribute == attribute)
                let text = try Generator(schema: schema).members().map(\.description).joined(separator: "\n")
                #expect(text.contains("\(attribute) public consuming func go()"), "\(attribute)")
                #expect(text.contains("\(attribute) public func go() -> Prepared"), "\(attribute)")
            }
        }
        let availability =
            "Remove '@available' and give the schema this availability instead: generated members call this function, and they have only the schema's availability."
        for options in [
            message, renamed, "\(message), \(renamed)", "deprecated, deprecated", "\(message), deprecated, \(message)",
            "\(renamed), deprecated, \(renamed)", "unavailable, deprecated", "\(message), deprecated, obsoleted: 2",
            "introduced: 1, deprecated", "deprecated: 2", "\(message), deprecated, noasync",
        ] {
            let attribute = "@available(*, \(options))"
            #expect(
                Self.diagnostics(source.replacingOccurrences(of: "ATTRIBUTE", with: attribute)) == [availability],
                "\(attribute)"
            )
        }
    }

    /// A rename is copied onto the generated methods, where Swift's fix-it puts it in place of the called
    /// method's name, so it must be the bare name of another edge, or router, that has a generated public
    /// method wherever the deprecated one has; any other target is refused at its string.
    @Test func aRenameNamesAnotherGeneratedMethod() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            public enum Flow {
                public struct Idle {}
                public struct Busy {}
                @Initial case idle(Idle)
                case busy(Busy)
                public enum Input { case go(Swift::Int), next(Swift::Int), start, pick, choose }
                @Operation(activeIn: [Busy.self])
                public enum Load {}
                @available(*, deprecated, renamed: "EDGE")
                @Transition(on: Input.go)
                static func go(_ source: Idle, _ count: Swift::Int) -> Idle { source }
                @Transition(on: Input.next)
                static func next(_ source: Idle, _ count: Swift::Int) -> Idle { source }
                @Transition(on: Input.start, starts: [Load.self])
                static func start(_ source: Idle) -> Change<Busy, Effect.Start> { fatalError() }
                @Transition(onSuccess: Load.self)
                static func loaded(_ source: Busy) -> Idle { Idle() }
                @Transition(on: Input.start)
                static func café(_ source: Busy) -> Idle { Idle() }
                @available(*, deprecated, renamed: "ROUTER")
                @Route(on: Input.pick)
                static func pick(_ source: Idle) -> Route.Pick { .left }
                @Transition(on: Input.pick)
                static func left(_ source: Idle) -> Idle { source }
                @Transition(on: Input.pick)
                static func right(_ source: Idle) -> Idle { source }
                @Route(on: Input.choose)
                static func choose(_ source: Idle) -> Route.Choose { .up }
                @Transition(on: Input.choose)
                static func up(_ source: Idle) -> Idle { source }
                @Transition(on: Input.choose)
                static func down(_ source: Idle) -> Idle { source }
            }
            """#
        func schema(edge: String = "next", router: String = "choose") -> String {
            source.replacingOccurrences(of: "EDGE", with: edge).replacingOccurrences(of: "ROUTER", with: router)
        }
        // A bare name of an edge, or a router, with a public method on each wrapper the deprecated one has.
        for edge in ["next", "café"] {
            let text = try Generator(schema: try Self.parse(schema(edge: edge))).members().map(\.description)
                .joined(separator: "\n")
            #expect(text.contains(#"@available(*, deprecated, renamed: "\#(edge)") public consuming func go("#))
            #expect(text.contains(#"@available(*, deprecated, renamed: "choose") public consuming func pick("#))
        }
        // Where only `Owned` is generated, a completion edge, which has its own method there, is one.
        let owned = schema(edge: "loaded")
            .replacingOccurrences(of: "mode: .shared", with: "mode: .shared, owners: [.owned]")
        #expect(Self.diagnostics(owned) == nil)
        func refusal(_ role: String) -> String {
            "Write the bare name of the replacement \(role) in 'renamed:': the generated methods repeat this deprecation as written, so it must name another \(role) that has a generated public method wherever this one has."
        }
        // A qualified or labeled name, a name in backticks, which Swift refuses there, a name of no function,
        // the function itself, a router, an edge a router chooses, an edge whose method is on `Owned` alone,
        // and an equivalent name spelled with other scalars than the edge's.
        for edge in [
            "Flow.next", "next(_:)", "next(_:_:)", "Flow.next(_:_:)", "`next`", "nxt", "", " next", "go", "pick",
            "left", "loaded", "cafe\u{301}",
        ] {
            let text = schema(edge: edge)
            let site = try #require(DiagnosticAnchorTests.site(of: "\"\(edge)\"", in: text))
            #expect(
                DiagnosticAnchorTests.refusals(text)
                    == [.init(message: refusal("edge"), line: site.line, column: site.column)],
                "\(edge)"
            )
        }
        for router in ["Flow.choose", "choose(_:)", "pick", "next"] {
            let text = schema(router: router)
            // The edge's rename is `"next"` too, before the router's.
            let occurrence = router == "next" ? 2 : 1
            let site = try #require(DiagnosticAnchorTests.site(of: "\"\(router)\"", occurrence: occurrence, in: text))
            #expect(
                DiagnosticAnchorTests.refusals(text)
                    == [.init(message: refusal("router"), line: site.line, column: site.column)],
                "\(router)"
            )
        }
    }
}
