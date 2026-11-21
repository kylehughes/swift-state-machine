import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

/// Every spelling Swift accepts for a type is read by what it names, whatever its kind, and a spelling
/// the macro cannot judge is read as opaque and checked by the expansion, never trapped on.
struct SpellingTotalityTests {
    private static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }
    private static func diagnostics(_ text: String) -> [String]? { DeclarationHygieneTests.diagnostics(text) }
    private static func expansion(_ text: String) throws -> String {
        try Generator(schema: parse(text)).members().map(\.description).joined(separator: "\n")
    }
    private static func loading(aliases: String, declarations: String = "", edges: String) -> String {
        TypeResolutionTests.loading(aliases: aliases, declarations: declarations, edges: edges)
    }
    private static let succeeds =
        "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running) -> Idle { fatalError() }"

    // MARK: Members of types the macro does not read

    @Test func aMemberOfAStructuralBaseReadsAsOpaque() throws {
        let source = Self.loading(
            aliases: "typealias Output = [Int].Element",
            edges:
                "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Int) -> Idle { fatalError() }"
        )
        let schema = try Self.parse(source)
        #expect(schema.neverProbes == ["Load.Output"])
        let scopes = schema.typeScopes
        for spelling in [
            "[Int].Element", "[Int: Int].Element", "Int?.Wrapped", "(Int, Int).Element", "Generic<Int>.Member",
        ] {
            #expect(scopes.resolve(spelling).isOpaque, "\(spelling)")
        }
        #expect(try Self.expansion(source).contains("typealias _StateMachineChecked = Load.Output"))
    }

    @Test func parenthesesKeepWhatAReferenceNamesAndItsMembers() throws {
        for (declarations, output) in [
            ("enum Values { typealias Unit = () }", "(Values).Unit"),
            ("enum Types { typealias Unit = Swift.Void }; typealias NS = (Types)", "NS.Unit"),
            ("enum Types { typealias Unit = Swift.Void }; typealias NS = ((Types))", "(NS).Unit"),
            ("enum Types { typealias Unit = Swift.Void }; typealias NS = (Self.Types)", "NS.Unit"),
        ] {
            let source = Self.loading(
                aliases: "typealias Output = \(output)",
                declarations: declarations,
                edges: Self.succeeds
            )
            #expect(try #require(try Self.parse(source).operations.first).producesVoid, "\(declarations) \(output)")
        }
    }

    // MARK: Generic aliases

    @Test func aGenericAliasReadsWithItsArguments() throws {
        let declarations = "typealias Identity<T> = T; typealias Pair<T> = (T, T); typealias Nothing = Swift::Never"
        let infallible = Self.loading(
            aliases: "typealias Failure = Identity<Swift::Never>; typealias Output = Identity<Swift::Void>",
            declarations: declarations,
            edges: Self.succeeds
        )
        let operation = try #require(try Self.parse(infallible).operations.first)
        #expect(operation.isInfallible && operation.producesVoid)
        #expect(Generator(schema: try Self.parse(infallible)).graph().contains("canFail: false"))
        // A failure edge of the substituted `Never` can never run, as one of `Swift::Never` cannot.
        let failing =
            infallible.replacingOccurrences(
                of: "EDGES",
                with: ""
            )
            .replacingOccurrences(
                of: "static func done(_ source: Running) -> Idle { fatalError() }",
                with:
                    "static func done(_ source: Running) -> Idle { fatalError() }\n@Transition(onFailure: Load.self)\nstatic func broke(_ source: Running, _ failure: Never) -> Idle { fatalError() }"
            )
        // The namespace reads `Identity` from the schema, which a member an extension gives it could hide, so
        // the failure edge decides: the operation is fallible, and the expansion checks its `Failure`.
        let fallible = try Self.parse(failing)
        #expect(fallible.operations.first?.isInfallible == false)
        #expect(
            TypeSpellingMatrixTests.checkMessage(fallible, at: "Load.Failure")?
                .hasPrefix("Operation 'Load' cannot fail")
                == true
        )
        let confirmed = failing.replacingOccurrences(
            of: "typealias Failure = Identity<Swift::Never>",
            with: "typealias Failure = Swift::Never"
        )
        #expect(Self.diagnostics(confirmed)?.first?.hasPrefix("Operation 'Load' cannot fail") == true)
        let scopes = try Self.parse(infallible).typeScopes
        #expect(scopes.resolve("Identity<Nothing>").isNever)
        #expect(scopes.resolve("Identity<Identity<()>>").isVoid)
        #expect(scopes.resolve("Pair<Int>").key == scopes.resolve("(Int, Int)").key)
        // A bare `Never` argument is a reading the macro cannot confirm, as a bare `Never` always is.
        #expect(scopes.resolve("Identity<Never>").isNever && !scopes.resolve("Identity<Never>").isConfirmed)
        #expect(scopes.resolve("Identity<Swift::Never>").isConfirmed)
    }

    @Test func aGenericAliasTheMacroCannotExpandReadsAsOpaque() throws {
        let scopes =
            try Self.parse(
                Self.loading(
                    aliases: "",
                    declarations:
                        "typealias Identity<T> = T; typealias Many<each T> = (repeat each T); typealias Unit = Void",
                    edges: Self.succeeds
                )
            )
            .typeScopes
        for spelling in ["Identity", "Identity<Int, Int>", "Many<Never>", "Unit<Int>", "Identity<3>"] {
            #expect(scopes.resolve(spelling).isOpaque, "\(spelling)")
        }
    }

    // MARK: Types outside the schema

    @Test func anInputOrKeyOfATypeOutsideTheSchemaIsCheckedNotToBeNever() throws {
        let source = Self.loading(
            aliases: "typealias Input = OutsideInput; typealias Key = OutsideKey",
            edges: Self.succeeds
        )
        #expect(try Self.parse(source).neverProbes == ["Load.Input", "Load.Key"])
        let text = try Self.expansion(source)
        #expect(text.contains("typealias _StateMachineChecked = Load.Input"))
        #expect(text.contains("typealias _StateMachineChecked = Load.Key"))
    }

    @Test func anEventPayloadIsReadForNeverAndCheckedWhenTheMacroCannotSeeIt() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                DECLARATIONS
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case go }
                @Event enum Tracked { typealias Payload = PAYLOAD }
                @Transition(on: Input.go, emits: [Tracked.self])
                static func go(_ source: Idle) -> Change<Idle, Effect.Go> { fatalError() }
            }
            """#
        func event(_ payload: String, _ declarations: String = "") -> String {
            source.replacingOccurrences(of: "PAYLOAD", with: payload)
                .replacingOccurrences(of: "DECLARATIONS", with: declarations)
        }
        let message =
            "Event 'Tracked' carries Never, so no transition can emit it; declare a payload type that has values, or remove the event."
        #expect(Self.diagnostics(event("Swift::Never", "typealias Nothing = Never")) == [message])
        // A namespace that reads `Never` from outside it, where a member could hide it, is checked instead.
        for payload in ["Never", "Nothing"] {
            let schema = try Self.parse(event(payload, "typealias Nothing = Never"))
            #expect(TypeSpellingMatrixTests.checkMessage(schema, at: "Tracked.Payload") == message, "\(payload)")
        }
        #expect(try Self.parse(event("Outside")).neverProbes == ["Tracked.Payload"])
        #expect(try Self.parse(event("Swift::Int")).neverProbes.isEmpty)
    }

    @Test func aThrownTypeTheMacroCannotSeeIsCheckedNotToBeNever() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                enum Problem: Error { case bad }
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case go, stop }
                @Transition(on: Input.go)
                static func go(_ source: Idle) throws(OutsideProblem) -> Idle { fatalError() }
                @Transition(on: Input.stop)
                static func stop(_ source: Idle) throws(Problem) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.neverProbes == ["OutsideProblem"])
        #expect(try Self.expansion(source).contains("typealias _StateMachineChecked = OutsideProblem"))
    }

    // MARK: Throwing Never

    /// Swift reads `throws(Never)` as nonthrowing, so generated code calls the function without `try`,
    /// and no witness, result, or wrapper treats it as one that can fail.
    @Test func aThrowOfNeverIsNonthrowingEverywhere() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                enum Problem: Error { case bad }
                typealias Nope = Never
                struct Idle {}
                struct A {}
                @Initial case idle(Idle)
                case a(A)
                enum Input { case go, back }
                @Transition(on: Input.go)
                static func left(_ source: Idle) throws(SPELLING) -> A { fatalError() }
                @Transition(on: Input.go)
                static func right(_ source: Idle) throws(Problem) -> A { fatalError() }
                @Route(on: Input.go, failure: Problem.self)
                static func choose(_ source: Idle) -> Route.Choose { fatalError() }
                @Transition(on: Input.back)
                static func back(_ source: A) throws(Swift.Never) -> Idle { fatalError() }
                @Restoration
                static func restore(_ saved: Int) throws(Nope) -> Restoration { fatalError() }
            }
            """#
        for spelling in ["Swift::Never", "Never", "Nope", "Swift.Never", "(Never)", "Flow.Nope"] {
            let text = source.replacingOccurrences(of: "SPELLING", with: spelling)
            let schema = try Self.parse(text)
            #expect(schema.transitions.first { $0.name == "left" }?.failureType == nil, "\(spelling)")
            #expect(schema.transitions.first { $0.name == "back" }?.failureType == nil, "\(spelling)")
            #expect(schema.restoration?.failureType == nil, "\(spelling)")
            #expect(schema.throwingFunctions.map(\.name) == ["right"], "\(spelling)")
            let expansion = try Self.expansion(text)
            #expect(
                !expansion.contains("(failure: Never)") && !expansion.contains("(failure: Swift::Never)"),
                "\(spelling)"
            )
            #expect(expansion.contains("return self.left()"), "\(spelling)")
            #expect(!expansion.contains("ResetRejection"), "\(spelling)")
        }
        // A bare `Never` is checked to be the standard library's, as any bare `Never` is.
        let bare = try Self.parse(source.replacingOccurrences(of: "SPELLING", with: "Never"))
        #expect(bare.standardNameChecks.map(\.reference).contains("Never"))
    }

    // MARK: Structural keys

    /// Spellings of one type share one key, so the functions of a router that throw it share one failure.
    @Test func sugarAndItsSpelledOutTypeShareAKey() throws {
        let scopes =
            try Self.parse(
                Self.loading(
                    aliases: "",
                    declarations: "struct Item {}; struct Detail {}; typealias Unit = Void; typealias Identity<T> = T",
                    edges: Self.succeeds
                )
            )
            .typeScopes
        let groups = [
            ["Item", "`Item`", "Flow.Item", "Self.Item", "(Item)", "((Item))", "Identity<Item>"],
            ["[Item]", "Array<Item>", "Swift.Array<Item>", "Swift::Array<Item>", "[`Item`]", "Identity<[Item]>"],
            ["Item?", "Optional<Item>", "Item!", "Swift::Optional<Flow.Item>"],
            ["[Item: Detail]", "Dictionary<Item, Detail>", "Swift.Dictionary<Item, Detail>"],
            ["[2 of Item]", "InlineArray<2, Item>", "Swift::InlineArray<2, Item>"],
            ["()", "Void", "Swift.Void", "Swift::Void", "Unit", "Identity<()>", "(())"],
            ["any Error", "Error", "Swift.Error", "Swift::Error", "(any Error)"],
            ["Sendable & Error", "Error & Sendable"],
            ["() throws(Never) -> Item", "() -> Item", "@escaping () -> Item", "() throws(Swift::Never) -> Item"],
            ["() throws(any Error) -> Item", "() throws -> Item", "() throws(Error) -> Item"],
            ["Swift.Int", "Swift::Int"],
        ]
        for group in groups {
            let keys = Set(group.map { scopes.resolve($0).key })
            #expect(keys.count == 1, "\(group): \(keys.map(\.description).sorted())")
        }
        let distinct = ["[Item]", "Item?", "(x: Item)", "Item", "Item.Type", "some Error", "any Error", "(Item, Item)"]
        #expect(Set(distinct.map { scopes.resolve($0).key }).count == distinct.count)
        #expect(
            scopes.resolve("(@escaping () -> Item) -> Item").key != scopes.resolve("(() -> Item) -> Item").key
        )
    }

    @Test func candidatesThatThrowOneGenericTypeThroughSugarShareOneFailure() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Detail {}
                struct Problem<T>: Error { let detail: T }
                struct Idle {}
                struct A {}
                @Initial case idle(Idle)
                case a(A)
                enum Input { case go, back }
                @Transition(on: Input.go)
                static func left(_ source: Idle) throws(Problem<[Detail]>) -> A { fatalError() }
                @Transition(on: Input.go)
                static func right(_ source: Idle) throws(Problem<Swift::Array<Detail>>) -> A { fatalError() }
                @Route(on: Input.go)
                static func choose(_ source: Idle) -> Route.Choose { fatalError() }
                @Transition(on: Input.back)
                static func back(_ source: A) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        let route = try #require(schema.routes.first)
        #expect(Generator(schema: schema).routedFailure(route) == "Problem<[Detail]>")
        #expect(!schema.needsOwnedResult(route))
        #expect(
            Schema.rejectionCase("left", from: "idle", distinguished: schema.namesThrowingDifferentFailures) == "left"
        )
    }

    // MARK: Escaped identifiers

    @Test func anEscapedReferenceIsShieldedAndLookedUpWithoutItsBackticks() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                typealias `Unit` = Swift.Void
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case use(`Phase`) }
                @Transition(on: Input.use)
                static func use(_ source: Idle, _ value: `Phase`) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.shieldedSpellings.map(\.spelling) == ["`Phase`"])
        #expect(schema.typeScopes.resolve("Unit").isVoid && schema.typeScopes.resolve("`Unit`").isVoid)
        let text = try Self.expansion(source)
        // `Owned<Phase>` names its parameter through the alias, which keeps the authored spelling.
        #expect(text.contains("typealias _StateMachineType1 = `Phase`"))
        #expect(text.contains("consuming func use(_ input: _StateMachineType1)"))
    }

    @Test func escapedDeclarationNamesNameTheirDeclarations() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum `Flow` {
                struct `Idle` {}
                struct Running {}
                @Initial case `idle`(`Idle`)
                case running(Self.`Running`)
                enum `Input` { case `go`, stop }
                enum Scope { case `session` }
                @Operation(activeIn: [`Running`.self])
                enum `Load` { typealias `Output` = Swift.Void }
                @Event enum `Tracked` {}
                @Transition(on: Input.`go`, starts: [`Load`.self], emits: [Tracked.self])
                static func `go`(_ source: `Idle`) -> Change<`Running`, Effect.`Go`> { fatalError() }
                @Transition(onSuccess: `Load`.self)
                static func done(_ source: Running) -> Idle { fatalError() }
                @Transition(on: Input.stop)
                static func stop(_ source: Running) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.name == "Flow")
        #expect(schema.phases.map(\.typeName) == ["Idle", "Running"] && schema.initial == "idle")
        #expect(schema.inputs.map(\.caseName) == ["go", "stop"] && schema.scopes == ["session"])
        #expect(schema.operations.map(\.name) == ["Load"] && schema.operations.first?.producesVoid == true)
        #expect(schema.events.map(\.name) == ["Tracked"])
        #expect(schema.transitions.map(\.name) == ["go", "done", "stop"])
        _ = try Self.expansion(source)
        // A name that only backticks allow cannot be spelled bare by generated code.
        for (declaration, role) in [
            ("@Initial case `default`(Idle)", "case"), ("@Initial case `Type`(Idle)", "case"),
        ] {
            let rejected = source.replacingOccurrences(of: "@Initial case `idle`(`Idle`)", with: declaration)
            #expect(
                Self.diagnostics(rejected)?
                    .contains(
                        "Name the \(role) with a Swift identifier that needs no backticks, such as one that is not a keyword."
                    ) == true,
                "\(declaration)"
            )
        }
        let keywordOperation = source.replacingOccurrences(of: "enum `Load`", with: "enum `Type`")
        #expect(Self.diagnostics(keywordOperation) != nil)
    }

    // MARK: Generated scopes that declare types

    /// `PendingCompletion` declares `Outcome` and `Rejection`, so its outcome's cases spell an
    /// operation's types from the schema's name.
    @Test func anOperationNamedForAPendingCompletionMemberKeepsItsTypes() throws {
        for name in ["Outcome", "Rejection"] {
            let effect = name.prefix(1).lowercased() + name.dropFirst()
            let source = TypeResolutionTests.loading
                .replacingOccurrences(of: "enum Load { ALIASES }", with: "enum \(name) { typealias Output = Int }")
                .replacingOccurrences(of: "Load.self", with: "\(name).self")
                .replacingOccurrences(of: "DECLARATIONS", with: "")
                .replacingOccurrences(
                    of: "EDGES",
                    with:
                        "@Transition(onSuccess: \(name).self)\nstatic func done(_ source: Running, _ value: Int) -> Idle { fatalError() }"
                )
            let text = try Self.expansion(source)
            #expect(text.contains("case \(effect)(Flow.\(name).Output)"), "\(name)")
            // The schema's own name is then reserved against both.
            let schemaNamed = source.replacingOccurrences(
                of: "enum Flow",
                with: "enum \(name == "Outcome" ? "Rejection" : "Outcome")"
            )
            #expect(
                Self.diagnostics(schemaNamed) == [
                    "The schema name is reserved or shadowed by a direct member; choose a distinct domain name."
                ],
                "\(name)"
            )
        }
    }

    // MARK: Parameter conventions

    @Test func aPayloadParameterKeepsItsConventionOnlyWhereGeneratedCodeDeclaresIt() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case trigger(@Sendable () -> Int), other(Int), sent(Int) }
                @Transition(on: Input.trigger)
                static func trigger(_ source: Idle, _ work: @escaping @Sendable () -> Int) -> Idle { fatalError() }
                @Transition(on: Input.other)
                static func other(_ source: Idle, _ value: borrowing Int) -> Idle { fatalError() }
                @Transition(on: Input.sent)
                static func sent(_ source: Idle, _ value: sending Int) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.transitions.map(\.payloadConvention) == ["@escaping ", "", "sending "])
        #expect(schema.transitions.map(\.payloadType) == ["@Sendable () -> Int", "Int", "Int"])
        let text = try Self.expansion(source)
        #expect(text.contains("let _: _TriggerPayloadMatchesDeclaration<@Sendable () -> Int> = payload"))
        #expect(!text.contains("<@escaping"))
        #expect(text.contains("consuming func trigger(_ input: @escaping @Sendable () -> Int)"))
        #expect(text.contains("func trigger(_ input: @escaping @Sendable () -> Int) -> Prepared"))
        // An `Owned` verb passes the payload on once, so it repeats the payload's ownership.
        #expect(text.contains("consuming func other(_ input: borrowing Int)"))
        #expect(text.contains("consuming func sent(_ input: sending Int)"))
        for (parameter, message) in [
            (
                "_ work: @autoclosure @escaping @Sendable () -> Int",
                "Take this payload without '@autoclosure'; generated code passes on the value it receives, which an autoclosure would wrap again."
            ),
            (
                "_ work: inout @Sendable () -> Int",
                "Take this payload without 'inout'; generated code passes on the value it receives."
            ),
        ] {
            let rejected = source.replacingOccurrences(of: "_ work: @escaping @Sendable () -> Int", with: parameter)
            #expect(Self.diagnostics(rejected) == [message], "\(parameter)")
        }
    }

    /// A routed method passes its payload to the router and to each edge it may choose, so it declares
    /// every convention any of them does.
    @Test func aRoutedPayloadDeclaresEveryConventionOfItsGroup() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct A {}
                @Initial case idle(Idle)
                case a(A)
                enum Input { case go(@Sendable () -> Int), back }
                @Transition(on: Input.go)
                static func left(_ source: Idle, _ work: @escaping @Sendable () -> Int) -> A { fatalError() }
                @Transition(on: Input.go)
                static func right(_ source: Idle, _ work: @Sendable () -> Int) -> A { fatalError() }
                @Route(on: Input.go)
                static func choose(_ source: Idle, _ work: @Sendable () -> Int) -> Route.Choose { fatalError() }
                @Transition(on: Input.back)
                static func back(_ source: A) -> Idle { fatalError() }
            }
            """#
        let text = try Self.expansion(source)
        #expect(text.contains("consuming func choose(_ input: @escaping @Sendable () -> Int)"))
        #expect(text.contains("func choose(_ input: @escaping @Sendable () -> Int) -> Prepared"))
    }

    // MARK: Alias chains

    @Test func aLongAliasChainResolvesAndACycleIsReported() throws {
        func used(_ declarations: String, output: String) -> String {
            Self.loading(
                aliases: "typealias Output = \(output)",
                declarations: declarations,
                edges:
                    "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Load.Output) -> Idle { fatalError() }"
            )
        }
        let chain = (0 ..< 68).map { "typealias A\($0) = A\($0 + 1)" }.joined(separator: "; ") + "; typealias A68 = ()"
        let long = Self.loading(aliases: "typealias Output = A0", declarations: chain, edges: Self.succeeds)
        #expect(try #require(try Self.parse(long).operations.first).producesVoid)
        // Reading never follows a chain in turn, so neither its length nor its order deepens a read.
        let reversed = (0 ..< 1_000).reversed().map { "typealias B\($0) = B\($0 + 1)" }.joined(separator: "; ")
        let deep = Self.loading(
            aliases: "typealias Output = B0",
            declarations: "typealias B1000 = Swift::Void; " + reversed,
            edges: Self.succeeds
        )
        #expect(try #require(try Self.parse(deep).operations.first).producesVoid)
        // A cycle is reported once a reading reaches it, and only when every link in it is confirmed.
        let ring = (0 ..< 500).map { "typealias C\($0) = C\(($0 + 1) % 500)" }.joined(separator: "; ")
        #expect(
            Self.diagnostics(used(ring, output: "C0")) == [
                "Type alias 'C0' names itself, directly or through other aliases; give it a type that does not depend on it."
            ]
        )
        for (declarations, output, name) in [
            ("typealias A = B; typealias B = A", "A", "A"), ("typealias A = [A]", "A", "A"),
            ("typealias G<T> = G<T>", "G<Swift::Int>", "G"), ("typealias G<T> = G<[T]>", "G<Swift::Int>", "G"),
            ("typealias A = Pair<A>; typealias Pair<T> = (T, T)", "A", "A"),
        ] {
            #expect(
                Self.diagnostics(used(declarations, output: output)) == [
                    "Type alias '\(name)' names itself, directly or through other aliases; give it a type that does not depend on it."
                ],
                "\(declarations)"
            )
        }
        // A link a member of a nested scope could change, as an extension or a superclass gives one, or
        // an alias no reading reaches, is left for the compiler, which reports the cycle where it is one.
        for (declarations, output) in [
            ("typealias A = S.B; struct S { typealias B = A }", "A"),
            ("enum Values { typealias Value = Values.Value }", "Values.Value"),
            (
                "typealias A = Child.Outcome; class Parent { typealias A = Swift::Int }; class Child: Parent { typealias Outcome = A }",
                "A"
            ),
            ("typealias Unused = Unused", "Swift::Int"),
        ] {
            #expect(Self.diagnostics(used(declarations, output: output)) == nil, "\(declarations)")
        }
        // An alias that reuses an outer name for another type is no cycle.
        let shadowing = Self.loading(
            aliases: "typealias Output = S.Item",
            declarations: "struct Item {}; struct S { typealias Item = Flow.Item }",
            edges:
                "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Item) -> Idle { fatalError() }"
        )
        #expect(Self.diagnostics(shadowing) == nil)
    }

    // MARK: Reserved members

    /// The generated `static let graph` is the same declaration as a static property, a type, a case
    /// without a payload, or a synchronous static method without parameters of that name, and a
    /// different one otherwise, as Swift's redeclaration rules have it.
    @Test func graphIsReservedAtItsSignature() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                DECLARATION
                struct Idle {}
                @Initial @Terminal case idle(Idle)
                enum Input {}
            }
            """#
        for declaration in [
            "static func graph(_ index: Int) -> Int { index }", "static func graph(at index: Int) -> Int { index }",
            "func graph() -> Int { 0 }", "var graph: Int { 0 }", "static subscript(graph: Int) -> Int { graph }",
            "static func graph() async -> Int { 0 }", "static func graph() async throws -> Int { 0 }",
        ] {
            #expect(
                Self.diagnostics(source.replacingOccurrences(of: "DECLARATION", with: declaration)) == nil,
                "\(declaration)"
            )
        }
        for declaration in [
            "static func graph() -> Int { 0 }", "static var graph: Int { 0 }", "struct graph {}",
            "typealias graph = Int",
            "static let (graph, other) = (1, 2)", "class func graph() -> Int { 0 }",
            "static func graph() throws -> Int { 0 }", "static func graph<Value>() -> Value? { nil }",
        ] {
            #expect(
                Self.diagnostics(source.replacingOccurrences(of: "DECLARATION", with: declaration)) == [
                    "'graph' is reserved for generated members; rename the authored declaration."
                ],
                "\(declaration)"
            )
        }
    }

    /// A phase case carries a payload, so it is a constructor beside the generated `graph`, whatever
    /// owners the schema generates.
    @Test func aPhaseNamedGraphIsAnotherDeclaration() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Node {}
                struct Done {}
                @Initial case graph(Node)
                @Terminal case done(Done)
                enum Input { case finish }
                @Transition(on: Input.finish)
                static func finish(_ source: Node) -> Done { fatalError() }
                @Restoration
                static func restore(_ saved: Int) -> Restoration { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.phases.map(\.caseName) == ["graph", "done"])
        #expect(try Self.expansion(source).contains("static let graph: StateMachine::StateMachineGraph"))
    }

    @Test func anEdgeNamedForAnOwnedVerbIsDiagnosedAsShadowingIt() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case go(Int) }
                @Transition(on: Input.go)
                static func withValue(_ source: Idle, _ value: Int) -> Idle { fatalError() }
            }
            """#
        #expect(
            Self.diagnostics(source) == [
                "Transition 'withValue' would generate the Owned method withValue(_:), which shadows Owned's own withValue(_:) verb; rename the transition."
            ]
        )
    }

    // MARK: Confirmation

    /// A reading the macro confirms changes under nothing it cannot see; every other reading is checked
    /// by the expansion on the type it concludes about.
    @Test func aBareStandardNameOrAFreeSwiftIsUnconfirmed() throws {
        let scopes = try Self.parse(Self.loading(aliases: "", edges: Self.succeeds)).typeScopes
        for spelling in [
            "Void", "Never", "Error", "any Error", "Array<Int>", "Dictionary<Int, Int>", "Optional<Int>",
            "InlineArray<1, Int>", "Swift.Int", "Swift.Error", "[Never]", "(Int) throws(Never) -> Int",
        ] {
            #expect(!scopes.resolve(spelling).isConfirmed, "\(spelling)")
        }
        for spelling in [
            "Swift::Void", "Swift::Never", "Swift::Error", "any Swift::Error", "[Swift::Int]", "Swift::Array<Int>",
            "Int", "Outside", "Flow.Idle", "Self.Idle", "Idle", "()", "Any", "[2 of Idle]",
        ] {
            #expect(scopes.resolve(spelling).isConfirmed, "\(spelling)")
        }
    }

    /// A nested scope that finds a name in an enclosing one could hold a member that hides it, which an
    /// extension or a superclass gives it, so the reading is unconfirmed there and confirmed only where
    /// the name is declared, or through the schema's own name.
    @Test func aNameANestedScopeFindsOutsideItIsUnconfirmed() throws {
        let source = Self.loading(
            aliases: "",
            declarations: """
                struct Product {}
                class Parent { typealias Product = Swift::Never }
                final class Child: Parent { typealias Outcome = Product; struct Leaf {}; typealias Own = Leaf }
                enum Namespace { struct Inner {}; typealias Local = Inner; typealias Outer = Product }
                """,
            edges: Self.succeeds
        )
        let scopes = try Self.parse(source).typeScopes
        #expect(!scopes.resolve("Child.Outcome").isConfirmed)
        #expect(scopes.resolve("Child.Own").isConfirmed)
        #expect(scopes.resolve("Namespace.Local").isConfirmed)
        #expect(!scopes.resolve("Namespace.Outer").isConfirmed)
        let load = try #require(scopes.memberScope("Load"))
        #expect(!scopes.resolve("Product", in: load).isConfirmed)
        // The schema's own name too: an extension of the namespace could declare a member of that name.
        #expect(!scopes.resolve("Flow.Product", in: load).isConfirmed)
        #expect(scopes.resolve("Flow.Product").isConfirmed)
        #expect(scopes.resolve("Self.Output", in: load).isConfirmed)
        #expect(!scopes.resolve("Int", in: load).isConfirmed)
    }

    /// An alias that reaches `Never` through an inherited member, or a file-scope `Error` of `Never`, is
    /// read as a type with values the macro cannot confirm, so the expansion probes the operation's
    /// alias itself.
    @Test func anUnconfirmedReadingOfATypeWithValuesIsProbed() throws {
        let inherited = Self.loading(
            aliases: "typealias Input = Child.Outcome",
            declarations: """
                struct Product {}
                class Parent { typealias Product = Swift::Never }
                final class Child: Parent { typealias Outcome = Product }
                """,
            edges: Self.succeeds
        )
        #expect(try Self.parse(inherited).neverProbes == ["Load.Input"])
        let error = Self.loading(aliases: "typealias Input = Error", edges: Self.succeeds)
        #expect(try Self.parse(error).neverProbes == ["Load.Input"])
        // Spelled from the schema's name, it is unconfirmed too, since an extension of the namespace could
        // declare a member of the schema's name; a module selector's type is confirmed, and unchecked.
        let schemaNamed = Self.loading(
            aliases: "typealias Input = Flow.Product",
            declarations: "struct Product {}",
            edges: Self.succeeds
        )
        #expect(try Self.parse(schemaNamed).neverProbes == ["Load.Input"])
        let confirmed = Self.loading(aliases: "typealias Input = Swift::Int", edges: Self.succeeds)
        #expect(try Self.parse(confirmed).typeChecks.isEmpty)
    }

    /// Generated types repeat a value conformance through the module, so a bare one is checked on the
    /// schema itself, and the inheritance clause is read where the schema is declared, outside its body.
    @Test func aBareValueConformanceIsCheckedAgainstTheStandardLibrary() throws {
        let source = GraphStructureTests.base.replacingOccurrences(
            of: "enum Flow {",
            with: "enum Flow: Equatable, Hashable {"
        )
        func conformances(_ schema: Schema) -> [Schema.TypeCheck] {
            schema.typeChecks.filter { if case .conformsToStandard = $0.kind { true } else { false } }
        }
        let schema = try Self.parse(source)
        #expect(
            conformances(schema) == [
                Schema.TypeCheck(kind: .conformsToStandard("Equatable"), reference: "Self"),
                Schema.TypeCheck(kind: .conformsToStandard("Hashable"), reference: "Self"),
            ]
        )
        let text = try Self.expansion(source)
        #expect(text.contains("fileprivate static func _stateMachineConformsToSwiftEquatable<Value: Swift::Equatable>"))
        #expect(text.contains("_stateMachineConformsToSwiftHashable(Self.self)"))
        // A type of that name the body declares does not take the clause's name.
        let shadowed = source.replacingOccurrences(of: "struct Idle", with: "struct Equatable {}\nstruct Idle")
        #expect(try Self.parse(shadowed).valueConformances == ["Equatable", "Hashable"])
        let qualified = GraphStructureTests.base.replacingOccurrences(
            of: "enum Flow {",
            with: "enum Flow: Swift::Equatable, Swift::Hashable {"
        )
        #expect(conformances(try Self.parse(qualified)).isEmpty)
        #expect(try Self.parse(qualified).valueConformances == ["Equatable", "Hashable"])
    }

    // MARK: Keys

    /// A key keeps the precedence of an existential relative to a metatype, and normalizes only what
    /// names one type.
    @Test func keysKeepTheExistentialsPlaceAgainstAMetatype() throws {
        let scopes =
            try Self.parse(
                Self.loading(aliases: "", declarations: "protocol P {}; protocol Q {}", edges: Self.succeeds)
            )
            .typeScopes
        func key(_ spelling: String) -> TypeKey { scopes.resolve(spelling).key }
        // A protocol's bare `P.Type` is the existential `any P.Type`, and `(any P).Type`, which
        // `P.Protocol` also spells, is the metatype of the existential, as Swift reads them.
        #expect(key("any P.Type") != key("(any P).Type"))
        #expect(key("any P.Type") == key("any (P.Type)"))
        #expect(key("P.Type") == key("any P.Type"))
        #expect(key("(P).Type") == key("any P.Type"))
        #expect(key("P.Type") != key("(any P).Type"))
        #expect(key("P.Protocol") == key("(any P).Type"))
        #expect(key("any P.Type.Type") != key("(any P.Type).Type"))
        #expect(key("(any P.Type).Type") != key("(any P).Type.Type"))
        #expect(key("any P & Q") == key("Q & P"))
        #expect(key("any (P & Q)") == key("any P & Q"))
        #expect(key("(any P)?") == key("P?"))
        #expect(key("some P") != key("P"))
        #expect(key("(borrowing P) -> Int") != key("(P) -> Int"))
        #expect(key("(inout P) -> Int") != key("(P) -> Int"))
        #expect(key("(P...) -> Int") != key("([P]) -> Int"))
        #expect(key("@Sendable () -> Int") != key("() -> Int"))
    }

    /// Each type keeps its structure, so a metatype of a function, a function of a metatype, an optional
    /// function, and a function of an optional are four types, and a metatype follows Swift's rule for
    /// the way its base names its type.
    @Test func keysKeepTheBoundariesOfEveryStructure() throws {
        let scopes =
            try Self.parse(
                Self.loading(
                    aliases: "",
                    declarations: """
                        protocol P {}; struct S {}; typealias AP = P; typealias AnyP = any P; typealias Id<T> = T
                        typealias Constant<T> = P
                        """,
                    edges: Self.succeeds
                )
            )
            .typeScopes
        func key(_ spelling: String) -> TypeKey { scopes.resolve(spelling).key }
        for (left, right) in [
            ("(() -> Swift::Int).Type", "() -> Swift::Int.Type"), ("(() -> Swift::Int)?", "() -> Swift::Int?"),
            ("() -> (Swift::Int, Swift::Int)", "(() -> Swift::Int, Swift::Int)"),
            ("[() -> Swift::Int]", "() -> [Swift::Int]"),
            ("P.Type", "(any P).Type"), ("AnyP.Type", "P.Type"), ("Id<P>.Type", "P.Type"),
            ("Outside.Type", "(any Outside).Type"), ("Outside.Type", "Id<Outside>.Type"),
            ("P.Type.Type", "(any P.Type).Type"),
            ("(a: Swift::Int)", "(b: Swift::Int)"), ("some P", "P"),
        ] {
            #expect(key(left) != key(right), "\(left) \(right)")
        }
        // Each equivalence is one the compiler checks, as the failure identity fixture does; `any` keys as
        // what it constrains, which Swift accepts only where the two are one type.
        for (left, right) in [
            ("P.Type", "any P.Type"), ("(P).Type", "any P.Type"), ("AP.Type", "any P.Type"),
            ("Constant<Swift::Int>.Type", "any P.Type"), ("AnyP.Type", "(any P).Type"), ("Id<P>.Type", "(any P).Type"),
            ("P.Protocol", "(any P).Type"), ("P.Type.Type", "any P.Type.Type"), ("Id<S>.Type", "S.Type"),
            ("@Sendable @MainActor () -> Swift::Int", "@MainActor @Sendable () -> Swift::Int"),
            ("() throws(any Swift::Error) -> Swift::Int", "() throws -> Swift::Int"),
        ] {
            #expect(key(left) == key(right), "\(left) \(right)")
        }
    }

    /// An escaped `Type` declares the name a bare `Type` looks up wherever no period precedes it.
    @Test func aBareTypeNamesTheEscapedAlias() throws {
        let source = Self.loading(
            aliases: "typealias Failure = Type",
            declarations: "typealias `Type` = Swift::Never; enum Kinds { typealias `Type` = Swift::Void }",
            edges: Self.succeeds
        )
        let schema = try Self.parse(source)
        #expect(try #require(schema.operations.first).isInfallible)
        #expect(schema.typeScopes.resolve("Type").isNever)
        #expect(schema.typeScopes.resolve("Kinds.`Type`").isVoid)
        #expect(!schema.typeScopes.resolve("Kinds.Type").isVoid)
    }

    /// A completion's request keeps its `sending` convention on every generated parameter that passes it on.
    @Test func aCompletionRequestKeepsItsSendingConvention() throws {
        let source = #"""
            @StateMachine(mode: .isolated, owners: [.owned])
            enum Tray {
                final class LoadInput {}
                struct Idle {}
                struct Busy {}
                @Initial case idle(Idle)
                case busy(Busy)
                enum Input { case go(LoadInput) }
                @Operation(activeIn: [Busy.self])
                enum Load { typealias Input = LoadInput }
                @Transition(on: Input.go, starts: [Load.self])
                static func go(_ source: Idle, _ input: sending LoadInput) -> Change<Busy, Effect.Go> { fatalError() }
                @Transition(onSuccess: Load.self)
                static func done(_ busy: Busy, request: sending LoadRequest) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.transitions.last?.requestConvention == "sending ")
        #expect(!schema.typeChecks.contains { $0.kind == .isSendable })
        #expect(try Self.expansion(source).contains("consuming func done(request: sending LoadRequest)"))
        // An observing owner keeps the request, so the request must be `Sendable`, which the runtime's
        // request is exactly when its input is.
        let observingSource = source.replacingOccurrences(of: "owners: [.owned]", with: "owners: [.owned, .local]")
        let observing = try Self.parse(observingSource)
        #expect(observing.typeChecks.contains(Schema.TypeCheck(kind: .isSendable, reference: "LoadRequest")))
        #expect(
            try Self.expansion(observingSource)
                .contains("typealias LoadRequest = StateMachine::OperationRequest<Load, Load.Input>")
        )
        // An `Owned` router that gives the request away while an edge it selects takes it after must have
        // it `Sendable`; one whose candidates do not take it transfers it once.
        let router = source.replacingOccurrences(
            of: """
                @Transition(onSuccess: Load.self)
                    static func done(_ busy: Busy, request: sending LoadRequest) -> Idle { fatalError() }
                """,
            with: """
                @Route(onSuccess: Load.self)
                    static func pick(_ busy: Busy, request: sending LoadRequest) -> Route.Pick { fatalError() }
                    @Transition(onSuccess: Load.self)
                    static func done(_ busy: Busy) -> Idle { fatalError() }
                    @Transition(onSuccess: Load.self)
                    static func stay(_ busy: Busy, request: LoadRequest) -> Busy { fatalError() }
                """
        )
        let reused = Schema.TypeCheck(kind: .sharedAfterRouter(.routerSends), reference: "LoadRequest")
        #expect(try Self.parse(router).typeChecks.contains(reused))
        let once = router.replacingOccurrences(
            of: "stay(_ busy: Busy, request: LoadRequest)",
            with: "stay(_ busy: Busy)"
        )
        #expect(try !Self.parse(once).typeChecks.contains(reused))
    }

    /// Generated code names the schema by its name, so every expansion checks that it names the schema.
    @Test func everyExpansionChecksTheSchemasName() throws {
        let text = try Self.expansion(GraphStructureTests.base)
        #expect(text.contains("fileprivate static func _stateMachineNamesSchema(_ type: Self.Type)"))
        #expect(text.contains("_stateMachineNamesSchema(_StateMachineSchema.self)"))
        #expect(text.contains("typealias _StateMachineSchema = Flow"))
    }

    /// An owned-only edge without effects names `Never` as its effect, which an outside alias may.
    @Test func anUnconfirmedAdvanceEffectIsCheckedToBeNever() throws {
        let source = #"""
            @StateMachine(mode: .ownedOnly)
            enum Door: ~Copyable {
                enum Rejection: Error { case stuck }
                struct Closed: ~Copyable {}
                struct Open: ~Copyable {}
                @Initial case closed(Closed)
                @Terminal case open(Open)
                @Transition
                static func open(_ source: consuming Closed) -> Advance<Closed, Open, EFFECT, Rejection> { fatalError() }
            }
            """#
        let message =
            "This transition starts no operation, cancels no work, and emits no event; use Never as its effect type."
        let outside = try Self.parse(source.replacingOccurrences(of: "EFFECT", with: "Outside"))
        #expect(
            outside.typeChecks == [Schema.TypeCheck(kind: .isStandard("Never", message: message), reference: "Outside")]
        )
        #expect(Self.diagnostics(source.replacingOccurrences(of: "EFFECT", with: "Swift::Int")) == [message])
    }

    /// A thrown type the macro cannot confirm shares a failure only with the same spelling.
    @Test func anUnconfirmedFailureKeysByItsSpelling() throws {
        let schema = try Self.parse(
            Self.loading(aliases: "", declarations: "enum Problem: Error { case bad }", edges: Self.succeeds)
        )
        #expect(schema.failureKey("Problem") == schema.failureKey("Flow.Problem"))
        #expect(schema.failureKey("Problem") == schema.failureKey("Self.Problem"))
        #expect(schema.failureKey("[Problem]") == schema.failureKey("Swift::Array<Problem>"))
        #expect(schema.failureKey("Array<Problem>") != schema.failureKey("[Problem]"))
        #expect(schema.failureKey("any Error") == schema.failureKey("any /* boxed */ Error"))
        #expect(schema.failureKey("any Error") != schema.failureKey("any Swift::Error"))
    }

    /// Two failures are one only where the macro proves it: a qualified global actor names its own
    /// scope's type, and a member named through a module keeps the module.
    @Test func failuresTheMacroCannotProveEqualStayDistinct() throws {
        let schema = try Self.parse(
            Self.loading(
                aliases: "",
                declarations: """
                    struct Problem<T>: Error {}
                    enum Left { enum Actors { @globalActor actor A { static let shared = A() } }; typealias F = @Actors.A () -> Swift::Void }
                    enum Right { enum Actors { @globalActor actor A { static let shared = A() } }; typealias F = @Actors.A () -> Swift::Void }
                    """,
                edges: Self.succeeds
            )
        )
        #expect(schema.failureKey("Problem<Left.F>") != schema.failureKey("Problem<Right.F>"))
        #expect(schema.failureKey("Problem<Left.F>") == schema.failureKey("Problem<Self.Left.F>"))
        #expect(schema.failureKey("Swift.Int.Swift::Stride") != schema.failureKey("Swift.Int.Review::Stride"))
        #expect(schema.failureKey("Swift.Int.Review::Stride") == schema.failureKey("Swift.Int.Review::Stride"))
    }

    /// A composition keys as the set of its members, flattened, and the standard library's sugared types
    /// have the metatype their explicit spellings have, each as the compiler checks.
    @Test func compositionsAndStandardMetatypesKeyAsTheCompilerReadsThem() throws {
        let schema = try Self.parse(
            Self.loading(
                aliases: "",
                declarations: "protocol P {}; protocol Q {}; protocol R {}; typealias PQ = P & Q",
                edges: Self.succeeds
            )
        )
        let scopes = schema.typeScopes
        #expect(scopes.resolve("any PQ & R").key == scopes.resolve("any P & Q & R").key)
        #expect(scopes.resolve("any R & Q & P & P").key == scopes.resolve("any P & Q & R").key)
        #expect(scopes.resolve("any P & P").key == scopes.resolve("any P").key)
        #expect(scopes.resolve("(P & P).Type").key == scopes.resolve("P.Type").key)
        #expect(scopes.resolve("[Swift::Int].Type").key == scopes.resolve("Swift::Array<Swift::Int>.Type").key)
        #expect(scopes.resolve("Swift::Int?.Type").key == scopes.resolve("Swift::Optional<Swift::Int>.Type").key)
        #expect(scopes.resolve("P.Type").key != scopes.resolve("(any P).Type").key)
    }

    /// A success's output parameter is decided by the authored edges where the macro cannot confirm the
    /// `Output`: an edge that takes one says it has values, and edges that take none say it is `Void`,
    /// which the expansion checks with a message that names the cause.
    @Test func theAuthoredSuccessDecidesAnUnconfirmedOutput() throws {
        let declarations = "typealias Product = Swift::Void"
        let taking = Self.loading(
            aliases: "typealias Output = Product",
            declarations: declarations,
            edges:
                "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ result: Load.Output) -> Idle { fatalError() }"
        )
        let operation = try #require(try Self.parse(taking).operations.first)
        #expect(!operation.producesVoid && !operation.neverSucceeds)
        let none = try Self.parse(
            Self.loading(aliases: "typealias Output = Product", declarations: declarations, edges: Self.succeeds)
        )
        #expect(try #require(none.operations.first).producesVoid)
        #expect(
            TypeSpellingMatrixTests.checkMessage(none, at: "Load.Output")?
                .hasPrefix("Operation 'Load' succeeds without output, as its onSuccess: edges and routers take none")
                == true
        )
        // A parameter labeled `request:` is the request, and an operation without a key whose `Input` the
        // macro reads as `Void` without confirming it then carries its input.
        let request = Self.loading(
            aliases: "typealias Input = Body; typealias Output = Product",
            declarations: declarations + "; typealias Body = Swift::Void",
            edges:
                "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, request: Self.LoadRequest) -> Idle { fatalError() }"
        )
        let carried = try #require(try Self.parse(request).operations.first)
        #expect(carried.producesVoid && carried.takesInput && carried.hasRequest)
        // A confirmed `Output` with values still rejects a success edge that takes only the request.
        let confirmed = request.replacingOccurrences(
            of: "typealias Output = Product",
            with: "typealias Output = Swift::Int"
        )
        #expect(
            Self.diagnostics(confirmed) == [
                "Operation 'Load' succeeds with output, so its success edge takes the output, unlabeled, after the source, then the request, if any, labeled request:."
            ]
        )
    }

    /// Without a completion edge for an outcome the macro cannot confirm, the operation reads as one
    /// whose outcome never happens, and the expansion checks that the type is `Never`.
    @Test func theAuthoredCompletionsDecideAnUnconfirmedOutcome() throws {
        let schema = try Self.parse(
            Self.loading(
                aliases: "typealias Output = Data; typealias Failure = Problem",
                declarations: "enum Problem: Error {}",
                edges:
                    "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Data) -> Idle { fatalError() }"
            )
        )
        let operation = try #require(schema.operations.first)
        #expect(!operation.neverSucceeds && operation.isInfallible)
        #expect(
            TypeSpellingMatrixTests.checkMessage(schema, at: "Load.Failure")?
                .hasPrefix("Operation 'Load' has no onFailure: edge or router, so the macro reads its Failure as Never")
                == true
        )
        #expect(
            try Self.expansion(
                Self.loading(
                    aliases: "typealias Output = Data; typealias Failure = Problem",
                    declarations: "enum Problem: Error {}",
                    edges:
                        "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Data) -> Idle { fatalError() }"
                )
            )
            .contains("canFail: false")
        )
    }

    /// Each check belongs to the declaration whose conclusion needs it, so a router with no edge that
    /// shows a `Never` spelling names a type with values revises every function that throws it, and no
    /// other function's check is lost.
    @Test func aRouterWithoutEdgesRevisesEveryFunctionThatThrowsItsSpelling() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Done {}
                @Initial case idle(Idle)
                @Terminal case done(Done)
                enum Input { case go, stop }
                @Transition(on: Input.go)
                static func go(_ source: Idle) throws(Never) -> Done { fatalError() }
                @Route(on: Input.stop)
                static func stop(_ source: Idle) throws(Never) -> Swift::Never { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.transitions.first?.failureType == "Never")
        #expect(schema.routes.first?.failureType == "Never")
        let message = "A router with no edge to choose returns Never and throws a typed rejection."
        #expect(schema.typeChecks == [Schema.TypeCheck(kind: .isNotNever(message: message), reference: "Never")])
        let text = try Self.expansion(source)
        #expect(text.contains("case go(Never)"))
    }

    /// The schema's name is checked in type position, where a static property of its name, which an
    /// extension may declare, is no candidate; an initial default names the schema through its alias.
    @Test func theSchemasNameIsCheckedWhereItNamesAType() throws {
        let source = GraphStructureTests.base.replacingOccurrences(
            of: "@Initial case idle(Idle)",
            with: "@Initial case idle(Idle = Idle())"
        )
        let text = try Self.expansion(source)
        #expect(text.contains("_stateMachineNamesSchema(_StateMachineSchema.self)"))
        #expect(text.contains("= _StateMachineSchema.Idle()"))
        #expect(!text.contains("(Flow.self)"))
    }

    // MARK: Cost

    /// Each generic argument is read once for each use, so nested generic aliases read in steps
    /// proportional to their spelling, and an alias whose reading would double past the bound reads as
    /// itself.
    @Test func nestedGenericAliasesReadInBoundedSteps() throws {
        var nested = "Swift::Int"
        for _ in 0 ..< 40 { nested = "Id<\(nested)>" }
        // Each level of `Twice` nests a tuple, which a test's thread has stack for to about thirty levels.
        var doubled = "Swift::Int"
        for _ in 0 ..< 24 { doubled = "Twice<\(doubled)>" }
        let chain = (1 ... 40).map { "typealias Chain\($0) = (Chain\($0 - 1), Chain\($0 - 1))" }.joined(separator: "; ")
        let source = Self.loading(
            aliases: "typealias Output = \(nested); typealias Key = \(doubled); typealias Input = Chain40",
            declarations: "typealias Id<T> = T; typealias Twice<T> = (T, T); typealias Chain0 = Swift::Int; \(chain)",
            edges:
                "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Swift::Int) -> Idle { fatalError() }"
        )
        let schema = try Self.parse(source)
        #expect(schema.typeScopes.resolve(nested).key == .standard("Int"))
        #expect(!schema.typeScopes.resolve(doubled).key.exceeds(2 * LexicalScopes.keyBudget))
        // An alias whose key would outgrow its budget keeps its kind, and stands for its own identity.
        let chained = schema.typeScopes.resolve("Chain40")
        #expect(chained.reading == .visible && !chained.key.exceeds(LexicalScopes.keyBudget))
        // The schema's readings and the three above together charge fewer steps than the source has
        // characters, where reading `Chain40` or `Twice` by doubling would charge about 2^40 and 2^24.
        let work = schema.typeScopes.work
        #expect(work.steps <= source.utf8.count && !schema.typeScopes.exhaustedBudget, "\(work)")
        _ = try Generator(schema: schema).members()
    }

    // MARK: Transfer

    /// An `.isolated` payload need not be `Sendable`, so generated code transfers a `sending` payload as
    /// it is only where it holds the value alone and passes it on once, and elsewhere requires that type
    /// to be `Sendable`.
    @Test func anIsolatedSendingPayloadIsSendableWhereGeneratedCodeCannotTransferIt() throws {
        let source = #"""
            @StateMachine(mode: .isolated, owners: OWNERS)
            enum Tray {
                final class Item {}
                struct Idle {}
                struct Held {}
                struct Other {}
                @Initial case idle(Idle)
                @Terminal case held(Held)
                @Terminal case other(Other)
                enum Input { case pick(Item) }
                @Route(on: Input.pick)
                static func choose(_ source: Idle, _ item: ROUTER Item) -> Route.Choose { fatalError() }
                @Transition(on: Input.pick)
                static func hold(_ source: Idle, _ item: sending Item) -> Held { fatalError() }
                @Transition(on: Input.pick)
                static func keep(_ source: Idle, _ item: KEEP Item) -> Other { fatalError() }
            }
            """#
        func variant(owners: String, router: String, keep: String = "sending") -> String {
            source.replacingOccurrences(of: "OWNERS", with: owners).replacingOccurrences(of: "ROUTER", with: router)
                .replacingOccurrences(of: "KEEP", with: keep)
        }
        let sendable = Schema.TypeCheck(kind: .isSendable, reference: "Item")
        let owned = try Self.parse(variant(owners: "[.owned]", router: "borrowing"))
        #expect(!owned.typeChecks.contains(sendable))
        // The router reads the payload with its source phase, so the edges that then take it as `sending`
        // need one of the two to be `Sendable`, which the expansion checks.
        let joined = Schema.TypeCheck(kind: .transfersAfterRouter(other: "Idle", joined: .source), reference: "Item")
        #expect(owned.typeChecks == [joined])
        #expect(
            try Self.expansion(variant(owners: "[.owned]", router: "borrowing"))
                .contains("_stateMachineTransfersAfterRouter(other, value)")
        )
        // An edge that takes the payload `sending` without an ownership proves it copyable, so the method
        // takes it plain, `sending` as an edge does.
        #expect(
            try Self.expansion(variant(owners: "[.owned]", router: "borrowing"))
                .contains("consuming func choose(_ input: sending Item)")
        )
        // A router that takes it as `sending` gives it away before the edge takes it, and an edge that takes
        // it as it is while another takes it as `sending` leaves the method keeping a value it may give
        // away; an observing owner keeps it.
        for (owners, router, keep, check) in [
            (
                "[.owned]", "sending", "sending",
                Schema.TypeCheck(kind: .sharedAfterRouter(.routerSends), reference: "Item")
            ),
            (
                "[.owned]", "borrowing", "borrowing",
                Schema.TypeCheck(kind: .sharedAfterRouter(.edgesDiffer), reference: "Item")
            ),
            ("[.owned, .local]", "borrowing", "sending", sendable),
        ] {
            let schema = try Self.parse(variant(owners: owners, router: router, keep: keep))
            #expect(schema.typeChecks.contains(check), "\(owners) \(router)")
        }
        #expect(
            try Self.expansion(variant(owners: "[.owned, .local]", router: "borrowing"))
                .contains("let _ = _SendingValueIsSendable<_StateMachineChecked>()")
        )
        // A `.shared` payload is `Sendable`, which passes to a `sending` parameter as to any other.
        let shared = variant(owners: "[.owned, .local]", router: "sending")
            .replacingOccurrences(of: "mode: .isolated", with: "mode: .shared")
            .replacingOccurrences(of: "final class Item {}", with: "struct Item {}")
        #expect(Self.diagnostics(shared) == nil)
    }

    /// The routed-transfer rule, as Swift's region checker decides it for every combination of the
    /// values an `Owned` router reads and the edges it may select send, read, or leave out: a value an
    /// edge sends that the router joins with another value still in use needs one of the two `Sendable`,
    /// and a value one edge sends while another reads it needs itself `Sendable`, whether or not the
    /// router takes it.
    @Test func everyValueAnOwnedRouterJoinsIsChecked() throws {
        func routed(router: String, left: String, right: String) -> String {
            """
            @StateMachine(mode: .isolated, owners: [.owned])
            enum Tray {
                final class Item {}
                struct Idle {}
                struct Running {}
                @Initial case idle(Idle)
                case running(Running)
                enum Input { case go(Item) }
                @Operation(activeIn: [Running.self])
                enum Load { typealias Input = Item; typealias Output = Item }
                @Transition(on: Input.go, starts: [Load.self])
                static func go(_ source: Idle, _ input: Item) -> Change<Running, Effect.Go> { fatalError() }
                @Route(onSuccess: Load.self)
                static func pick(_ source: Running, \(router)) -> Route.Pick { fatalError() }
                @Transition(onSuccess: Load.self)
                static func left(_ source: Running, \(left)) -> Idle { fatalError() }
                @Transition(onSuccess: Load.self)
                static func right(_ source: Running, \(right)) -> Running { fatalError() }
            }
            """
        }
        func routedChecks(_ schema: Schema) -> [Schema.TypeCheck] {
            schema.typeChecks.filter { check in
                switch check.kind {
                case .sharedAfterRouter, .transfersAfterRouter: true
                default: false
                }
            }
        }
        // The reviewed router: a Sendable source joins nothing, but the request it also reads stays in use.
        let three = try Self.parse(
            routed(
                router: "_ output: Item, request: LoadRequest",
                left: "_ output: sending Item, request: LoadRequest",
                right: "_ output: sending Item, request: LoadRequest"
            )
        )
        #expect(
            routedChecks(three) == [
                Schema.TypeCheck(kind: .transfersAfterRouter(other: "Running", joined: .source), reference: "Item"),
                Schema.TypeCheck(kind: .transfersAfterRouter(other: "LoadRequest", joined: .value), reference: "Item"),
            ]
        )
        // An edge that leaves out a request the method receives as `sending` lets the output carry it away.
        let leaves = try Self.parse(
            routed(
                router: "_ output: Item, request: LoadRequest",
                left: "_ output: sending Item",
                right: "_ output: Item, request: sending LoadRequest"
            )
        )
        #expect(!leaves.typeChecks.contains { $0.kind == .transfersAfterRouter(other: "LoadRequest", joined: .value) })
        #expect(
            leaves.typeChecks.contains(Schema.TypeCheck(kind: .sharedAfterRouter(.edgesDiffer), reference: "Item"))
        )
        // Edges that differ about a request the router never reads still share it.
        let unread = try Self.parse(
            routed(
                router: "_ output: Item",
                left: "_ output: Item, request: sending LoadRequest",
                right: "_ output: Item, request: LoadRequest"
            )
        )
        #expect(
            routedChecks(unread) == [Schema.TypeCheck(kind: .sharedAfterRouter(.edgesDiffer), reference: "LoadRequest")]
        )
    }

    /// A restoring reset repeats the saved data's `sending`, which `RestoringLocalStateMachine` allows.
    @Test func aSendingArchiveIsRepeatedByEveryRestoringEntryPoint() throws {
        let source = GraphStructureTests.base.replacingOccurrences(
            of: "enum Input",
            with:
                "@Restoration\n    static func restore(_ saved: sending String) -> Restoration { fatalError() }\n    enum Input"
        )
        let text = try Self.expansion(source)
        #expect(text.contains("func reset(restoring saved: sending String) throws(CommitRejection) -> Receipt"))
        #expect(text.contains("init(restoring saved: sending String"))
    }

    /// An input the macro confirms is a function type is `@escaping` in the driver, which can keep it; one
    /// it cannot confirm reaches the driver as it is, which a closure does too, and the request and work
    /// store either through a generic parameter.
    @Test func aFunctionTypedInputIsEscapingInTheDriverOnlyWhereConfirmed() throws {
        let source = Self.loading(aliases: "typealias Input = @Sendable () -> Int", edges: Self.succeeds)
        let text = try Self.expansion(source)
        #expect(text.contains("@Sendable (@escaping Load.Input) async -> Swift::Void"))
        #expect(text.contains("typealias LoadRequest = StateMachine::OperationRequest<Load, Load.Input>"))
        // Through the schema's alias, an extension of the namespace could declare `Body` as another type.
        let unconfirmed = Self.loading(
            aliases: "typealias Input = Body",
            declarations: "typealias Body = @Sendable () -> Int",
            edges: Self.succeeds
        )
        let plain = try Self.expansion(unconfirmed)
        #expect(plain.contains("@Sendable (Load.Input) async -> Swift::Void"))
        #expect(!plain.contains("@escaping Load.Input"))
    }

    // MARK: Names

    /// Each check's local alias takes a name the schema never spells, and generated expressions name the
    /// schema through an alias, so a value of the schema's name hides nothing.
    @Test func generatedNamesAvoidTheSchemasOwnSpellings() throws {
        let checked = Self.loading(
            aliases: "typealias Output = _StateMachineChecked",
            edges:
                "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: _StateMachineChecked) -> Idle { fatalError() }"
        )
        let schema = try Self.parse(checked)
        #expect(schema.checkedAlias == "_StateMachineChecked2")
        #expect(try Self.expansion(checked).contains("do { typealias _StateMachineChecked2 = Load.Output;"))
        let lowercase = GraphStructureTests.base.replacingOccurrences(of: "enum Flow", with: "enum input")
        let text = try Self.expansion(lowercase)
        #expect(text.contains("internal typealias _StateMachineSchema = input"))
        #expect(text.contains("_StateMachineSchema.prepare(input"))
        #expect(!text.contains("input.prepare("))
    }

    /// A spelling that names a declaration outside the schema by one of the expansion's implementation
    /// names would name the expansion's own declaration, so it is diagnosed.
    @Test func aSpellingOfAnImplementationNameIsDiagnosed() throws {
        for name in ["_StateMachineEngine", "_StateMachineSchema", "_TransitionSourceIsPhasePayload"] {
            let source = Self.loading(
                aliases: "typealias Output = \(name)",
                edges:
                    "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Load.Output) -> Idle { fatalError() }"
            )
            #expect(
                Self.diagnostics(source) == [
                    "'\(name)' names a declaration the expansion makes inside the schema for its own use, which would hide any declaration of that name this spelling means; rename that declaration."
                ],
                "\(name)"
            )
        }
    }

    /// Redundant backticks change no name for any identifier Swift's lexer accepts bare.
    @Test func redundantBackticksFollowSwiftsIdentifierGrammar() throws {
        func unescaped(_ spelling: String) -> String {
            Array(TypeSyntax(stringLiteral: spelling).tokens(viewMode: .sourceAccurate)).first?.unescaped ?? ""
        }
        for name in ["🌱", "Café", "名前", "x₁", "_x9", "Δelta"] {
            #expect(unescaped("`\(name)`") == name, "\(name)")
        }
        for name in ["Type", "Self", "Any", "class", "my name", "9lives", "a-b"] {
            #expect(unescaped("`\(name)`") == "`\(name)`", "\(name)")
        }
        let source = Self.loading(
            aliases: "typealias Failure = `🌱`",
            declarations: "typealias 🌱 = Swift::Never",
            edges: Self.succeeds
        )
        #expect(try #require(try Self.parse(source).operations.first).isInfallible)
    }
}
