import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

/// Authored spellings are read for the types they name where the author wrote them, through the
/// declarations the schema makes visible, before any decision depends on them.
struct TypeResolutionTests {
    private static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }
    private static func diagnostics(_ text: String) -> [String]? { DeclarationHygieneTests.diagnostics(text) }
    private static func expansion(_ text: String) throws -> String {
        try Generator(schema: parse(text)).members().map(\.description).joined(separator: "\n")
    }

    /// A schema with one operation; `ALIASES` declares the operation's aliases and `DECLARATIONS`
    /// adds members to the schema.
    static let loading = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            DECLARATIONS
            struct Idle {}
            struct Running {}
            struct Failed {}
            @Initial case idle(Idle)
            case running(Running)
            @Terminal case failed(Failed)
            enum Input { case go, stop }
            @Operation(activeIn: [Running.self])
            enum Load { ALIASES }
            @Transition(on: Input.go, starts: [Load.self])
            static func go(_ source: Idle) -> Change<Running, Effect.Go> { fatalError() }
            @Transition(on: Input.stop)
            static func stop(_ source: Running) -> Idle { fatalError() }
            @Transition(on: Input.stop)
            static func abandon(_ source: Idle) -> Failed { fatalError() }
            EDGES
        }
        """#

    static func loading(aliases: String, declarations: String = "", edges: String) -> String {
        loading.replacingOccurrences(of: "ALIASES", with: aliases)
            .replacingOccurrences(of: "DECLARATIONS", with: declarations)
            .replacingOccurrences(of: "EDGES", with: edges)
    }

    // MARK: Aliases the schema declares

    @Test func anAliasOfVoidGivesTheSuccessEdgeNoOutput() throws {
        let void = """
            @Transition(onSuccess: Load.self)
            static func done(_ source: Running) -> Idle { fatalError() }
            """
        for (declarations, aliases) in [
            ("typealias Unit = Swift.Void", "typealias Output = Unit"),
            ("typealias Unit = ()", "typealias Output = Unit"),
            ("typealias Unit = Empty; typealias Empty = Swift::Void", "typealias Output = Unit"),
            ("", "typealias Input = Swift.Void; typealias Output = Input"),
            ("typealias Unit = Void", "typealias Output = Self.Input; typealias Input = Unit"),
            ("", "enum Values { typealias Unit = () }; typealias Output = Values.Unit"),
        ] {
            let source = Self.loading(aliases: aliases, declarations: declarations, edges: void)
            let schema = try Self.parse(source)
            let operation = try #require(schema.operations.first, "\(declarations) \(aliases)")
            #expect(operation.producesVoid, "\(declarations) \(aliases)")
            // An output parameter spelled through the alias is diagnosed as one spelled `Void` when the macro
            // confirms the reading; otherwise the edge says the operation produces a value, which it carries.
            let taking = source.replacingOccurrences(
                of: "func done(_ source: Running)",
                with: "func done(_ source: Running, _ value: Load.Output)"
            )
            if schema.typeScopes.resolve("Load.Output").isConfirmed {
                #expect(
                    Self.diagnostics(taking)?.first?.hasPrefix("Operation 'Load' succeeds without output") == true,
                    "\(declarations) \(aliases)"
                )
            } else {
                #expect(try Self.parse(taking).operations.first?.producesVoid == false, "\(declarations) \(aliases)")
            }
        }
        // An alias of a type the schema declares named `Void` keeps that type.
        let own = Self.loading(
            aliases: "typealias Output = Unit",
            declarations: "struct Void {}; typealias Unit = Void",
            edges: void.replacingOccurrences(of: "(_ source: Running)", with: "(_ source: Running, _ value: Unit)")
        )
        #expect(try #require(try Self.parse(own).operations.first).producesVoid == false)
    }

    /// A tuple element's wildcard `_` is no label, as Swift reads it, so `(_: A, B)` is `(A, B)` and
    /// `(_: A)` is `A`; a backticked `` `_` `` is a label of its own.
    @Test func aWildcardTupleLabelIsNoLabel() throws {
        let scopes = try Self.parse(GraphStructureTests.base).typeScopes
        #expect(scopes.resolve("(_: Swift::Int, Swift::Bool)").key == scopes.resolve("(Swift::Int, Swift::Bool)").key)
        #expect(scopes.resolve("(`_`: Swift::Int, Swift::Bool)").key != scopes.resolve("(Swift::Int, Swift::Bool)").key)
        #expect(
            scopes.resolve("(`_`: Swift::Int, Swift::Bool)").key != scopes.resolve("(_: Swift::Int, Swift::Bool)").key
        )
        #expect(scopes.resolve("(_: (_: ()))").isVoid && scopes.resolve("(_: (_: ()))").confirmsShape)
        #expect(scopes.resolve("(_: Swift::Never)").isConfirmedNever)
        #expect(scopes.resolve("(_: (), ())").reading == .visible)
    }

    /// A standard-library name confirms its kind only when the macro knows that kind: `UnboundedRange`
    /// is the function type it aliases, and a name outside the table, such as the caseless `Unicode`,
    /// keeps its identity but leaves its kind for the expansion to check.
    @Test func standardNamesConfirmOnlyTheKindsTheMacroKnows() throws {
        let scopes = try Self.parse(GraphStructureTests.base).typeScopes
        let range = scopes.resolve("Swift::UnboundedRange")
        #expect(range.isConfirmedFunction && range.isConfirmed)
        #expect(range.key == scopes.resolve("(Swift::UnboundedRange_) -> ()").key)
        let unicode = scopes.resolve("Swift::Unicode")
        #expect(unicode.isConfirmed && !unicode.confirmsShape)
        #expect(scopes.resolve("Swift::Int").confirmsShape && scopes.resolve("Swift::Array<Swift::Int>").confirmsShape)
        // An unconfirmed kind is checked wherever the shape rests on it.
        let source = Self.loading(
            aliases: "typealias Output = Swift::Unicode",
            edges:
                "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Load.Output) -> Idle { fatalError() }"
        )
        #expect(try Self.parse(source).typeChecks.contains { $0.reference == "Load.Output" })
    }

    @Test func anAliasOfNeverMakesTheOperationInfallible() throws {
        let failing = """
            @Transition(onSuccess: Load.self)
            static func done(_ source: Running) -> Idle { fatalError() }
            @Transition(onFailure: Load.self)
            static func broke(_ source: Running, _ failure: Problem) -> Failed { fatalError() }
            """
        let message = "Operation 'Load' cannot fail: its Failure is Never"
        for (declarations, aliases) in [
            ("typealias Problem = Swift.Never", "typealias Failure = Problem"),
            ("typealias Problem = Nothing; typealias Nothing = Never", "typealias Failure = Problem"),
            ("", "enum Errors { typealias Problem = Swift::Never }; typealias Failure = Errors.Problem"),
        ] {
            let source = Self.loading(aliases: aliases, declarations: declarations, edges: failing)
            if declarations.isEmpty {
                // A failure edge of an operation that cannot fail can never run.
                #expect(Self.diagnostics(source)?.first?.hasPrefix(message) == true, "\(aliases)")
            } else {
                // The namespace reads the schema's alias through a name a member of its own could hide, so the
                // failure edge decides, and the expansion checks that the failure is no `Never`.
                let schema = try Self.parse(source)
                #expect(schema.operations.first?.isInfallible == false, "\(declarations)")
                #expect(
                    TypeSpellingMatrixTests.checkMessage(schema, at: "Load.Failure")?.hasPrefix(message) == true,
                    "\(declarations)"
                )
            }
        }
        let graph = try Self.parse(
            Self.loading(
                aliases: "typealias Failure = Problem",
                declarations: "typealias Problem = Swift.Never",
                edges:
                    "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running) -> Failed { fatalError() }"
            )
        )
        let operation = try #require(graph.operations.first)
        #expect(operation.isInfallible && operation.failureType == "Problem")
        // The graph keeps the authored spelling and reports that the operation cannot fail.
        let text = Generator(schema: graph).graph()
        #expect(text.contains(#"failure: "Problem", canFail: false, canSucceed: true"#))
    }

    @Test func anAliasOfNeverAsTheOutputLeavesNoSuccessEdge() throws {
        let source = Self.loading(
            aliases: "typealias Output = Nothing; typealias Failure = Problem",
            declarations: "typealias Nothing = Never; enum Problem: Error { case lost }",
            edges: """
                @Transition(onSuccess: Load.self)
                static func done(_ source: Running, _ value: Nothing) -> Idle { fatalError() }
                @Transition(onFailure: Load.self)
                static func broke(_ source: Running, _ failure: Problem) -> Failed { fatalError() }
                """
        )
        // The namespace reads `Nothing` from the schema, so the success edge decides, and the expansion
        // checks that the output is no `Never`.
        let schema = try Self.parse(source)
        #expect(schema.operations.first?.neverSucceeds == false)
        #expect(
            TypeSpellingMatrixTests.checkMessage(schema, at: "Load.Output")?
                .hasPrefix("Operation 'Load' never succeeds")
                == true
        )
        let confirmed = source.replacingOccurrences(
            of: "typealias Output = Nothing",
            with: "typealias Output = Swift::Never"
        )
        #expect(Self.diagnostics(confirmed)?.first?.hasPrefix("Operation 'Load' never succeeds") == true)
    }

    @Test func aMemberAliasReadsThroughItsBase() throws {
        let source = Self.loading(
            aliases: "typealias Failure = Errors.Problem",
            declarations: "enum Errors { typealias Problem = Never }",
            edges: "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running) -> Failed { fatalError() }"
        )
        #expect(try #require(try Self.parse(source).operations.first).isInfallible)
        let scopes = try Self.parse(source).typeScopes
        #expect(scopes.resolve("Errors.Problem").isNever)
        #expect(scopes.resolve("Flow.Errors.Problem").isNever)
        #expect(scopes.resolve("Self.Errors.Problem").isNever)
    }

    // MARK: Dotted names

    /// A dotted name means what its first component resolves to where the author wrote it.
    @Test func aDottedNameKeepsItsLexicalMeaning() throws {
        let failing = """
            @Transition(onSuccess: Load.self)
            static func done(_ source: Running) -> Idle { fatalError() }
            @Transition(onFailure: Load.self)
            static func broke(_ source: Running, _ failure: Load.Failure) -> Failed { fatalError() }
            """
        let nested = Self.loading(
            aliases: "enum Swift { enum Never: Error { case broken } }; typealias Failure = Swift.Never",
            edges: failing
        )
        #expect(Self.diagnostics(nested) == nil)
        #expect(try #require(try Self.parse(nested).operations.first).isInfallible == false)
        // The same holds for a `Swift` the schema declares.
        let schemaOwn = Self.loading(
            aliases: "typealias Failure = Swift.Never",
            declarations: "enum Swift { enum Never: Error { case broken } }",
            edges: failing
        )
        #expect(try #require(try Self.parse(schemaOwn).operations.first).isInfallible == false)
        // A module selector always names the module.
        let selected = Self.loading(
            aliases: "enum Swift { enum Never: Error { case broken } }; typealias Failure = Swift::Never",
            edges: failing
        )
        #expect(Self.diagnostics(selected)?.first?.hasPrefix("Operation 'Load' cannot fail") == true)
    }

    @Test func generatedCodeNamesModulesThroughSelectors() throws {
        let source = Self.loading(
            aliases: "typealias Output = Int",
            declarations: "enum Swift {}; enum StateMachine {}",
            edges:
                "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Int) -> Idle { fatalError() }"
        )
        let text = try Self.expansion(source)
        #expect(!text.contains("Swift.") && !text.contains("StateMachine."))
        #expect(text.contains("Swift::Sendable") && text.contains("StateMachine::RuntimeTicket"))
        #expect(try Self.parse(source).reservedNames.isDisjoint(with: ["Swift", "StateMachine"]))
    }

    // MARK: Router failures

    @Test func candidatesThatThrowOneTypeThroughAnAliasShareOneFailureAndOneResult() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                enum Problem: Error { case bad }
                typealias Alias = Problem
                struct Idle {}
                struct A {}
                @Initial case idle(Idle)
                case a(A)
                enum Input { case go, back }
                @Transition(on: Input.go)
                static func left(_ source: Idle) throws(Problem) -> A { fatalError() }
                @Transition(on: Input.go)
                static func right(_ source: Idle) throws(Alias) -> A { fatalError() }
                @Route(on: Input.go)
                static func choose(_ source: Idle) -> Route.Choose { fatalError() }
                @Transition(on: Input.back)
                static func back(_ source: A) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        let route = try #require(schema.routes.first)
        let generator = Generator(schema: schema)
        #expect(generator.routedFailure(route) == "Problem")
        #expect(!schema.needsOwnedResult(route))
        #expect(
            Schema.rejectionCase("left", from: "idle", distinguished: schema.namesThrowingDifferentFailures) == "left"
        )
        #expect(schema.failureKey("Alias") == schema.failureKey("Flow.Problem"))
    }

    /// Every throwing function of a pinned group is checked against the pinned failure, whichever
    /// methods the owners generate.
    @Test func aPinnedFailureIsCheckedForEveryOwnerSelection() throws {
        let source = #"""
            @StateMachine(mode: .shared, owners: OWNERS)
            enum Flow {
                enum Problem: Error { case bad }
                enum Other: Error { case worse }
                struct Idle {}
                struct A {}
                @Initial case idle(Idle)
                case a(A)
                enum Input { case go, back, refuse }
                @Transition(on: Input.go)
                static func left(_ source: Idle) throws(Other) -> A { fatalError() }
                @Transition(on: Input.go)
                static func right(_ source: Idle) -> A { fatalError() }
                @Route(on: Input.go, failure: Problem.self)
                static func choose(_ source: Idle) -> Route.Choose { fatalError() }
                @Route(on: Input.refuse, failure: Problem.self)
                static func refuse(_ source: Idle) throws(Other) -> Never { fatalError() }
                @Transition(on: Input.back)
                static func back(_ source: A) -> Idle { fatalError() }
            }
            """#
        for owners in ["[.owned]", "[.local]", "[.shared]", "[.owned, .local]"] {
            let text = try Self.expansion(source.replacingOccurrences(of: "OWNERS", with: owners))
            #expect(text.contains("let _ = _OperationFailureIsError<Problem>()"), "\(owners)")
            #expect(text.contains("let _ = { (failure: Other) throws(Problem) in throw failure }"), "\(owners)")
            // One witness for the candidate of `choose`, one for the router `refuse` with no choices.
            #expect(text.components(separatedBy: "throws(Problem) in throw failure").count == 3, "\(owners)")
        }
    }

    // MARK: Types the macro cannot see

    /// An `Output` or `Failure` that names a type declared outside the schema may be an alias of
    /// `Never`, so the expansion checks it names another type.
    @Test func anOutcomeOfATypeOutsideTheSchemaIsCheckedNotToBeNever() throws {
        let source = Self.loading(
            aliases: "typealias Output = Data; typealias Failure = NetworkError",
            edges: """
                @Transition(onSuccess: Load.self)
                static func done(_ source: Running, _ value: Data) -> Idle { fatalError() }
                @Transition(onFailure: Load.self)
                static func broke(_ source: Running, _ failure: NetworkError) -> Failed { fatalError() }
                """
        )
        let schema = try Self.parse(source)
        #expect(schema.neverProbes == ["Load.Output", "Load.Failure"])
        let text = try Self.expansion(source)
        #expect(
            text.contains(
                "do { typealias _StateMachineChecked = Load.Failure; let probe = _stateMachineNeverProbe(_StateMachineChecked.self); _stateMachineIsNotSwiftNever2(probe) }"
            )
        )
        #expect(text.contains("fileprivate static func _stateMachineNeverProbe(_ type: Swift::Never.Type)"))
        #expect(schema.fixedGeneratedNames.isSuperset(of: ["_stateMachineNeverProbe", "_stateMachineIsNotSwiftNever"]))
        // A type the macro can confirm needs no check: one the namespace declares, or one named through
        // a module selector, so no member an extension or a superclass gives the namespace could hide it,
        // or omitted.
        let visible = Self.loading(
            aliases: "enum Problem: Error { case lost }; typealias Output = [Swift::Int]; typealias Failure = Problem",
            edges: """
                @Transition(onSuccess: Load.self)
                static func done(_ source: Running, _ value: [Int]) -> Idle { fatalError() }
                @Transition(onFailure: Load.self)
                static func broke(_ source: Running, _ failure: Load.Problem) -> Failed { fatalError() }
                """
        )
        #expect(try Self.parse(visible).neverProbes.isEmpty)
        #expect(!(try Self.expansion(visible)).contains("_stateMachineNeverProbe"))
    }

    // MARK: Declared names

    @Test func everyDirectTypeAndBoundIdentifierIsCheckedAgainstGeneratedNames() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                DECLARATION
                struct Idle {}
                @Initial @Terminal case idle(Idle)
                enum Input {}
            }
            """#
        for (declaration, name) in [
            ("protocol Owned {}", "Owned"), ("static let (graph, other) = (1, 2)", "graph"),
            ("static var (first, (second, Snapshot)) = (1, (2, 3))", "Snapshot"),
        ] {
            #expect(
                Self.diagnostics(source.replacingOccurrences(of: "DECLARATION", with: declaration)) == [
                    "'\(name)' is reserved for generated members; rename the authored declaration."
                ],
                "\(declaration)"
            )
        }
    }
}
