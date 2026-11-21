import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

/// Authored spellings resolve by syntax where the author wrote them, and generated names are checked
/// where the expansion emits them.
struct EmittedNameTests {
    static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }
    static func diagnostics(_ text: String) -> [String]? { DeclarationHygieneTests.diagnostics(text) }
    static func expansion(_ text: String) throws -> String {
        let members = try Generator(schema: parse(text)).members()
        #expect(members.allSatisfy { !$0.hasError })
        return members.map(\.description).joined(separator: "\n")
    }

    /// A graph whose only entrance to `Failed` is the failure of `Fetch`; `FAILURE` is the namespace's alias, if any.
    static let fetching = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            DECLARATIONS
            struct Idle {}
            struct Running {}
            struct Failed {}
            @Initial case idle(Idle)
            case running(Running)
            @Terminal case failed(Failed)
            enum Input { case start }
            @Operation(activeIn: [Running.self])
            enum Fetch { FAILURE }
            @Transition(on: Input.start, starts: [Fetch.self])
            static func start(_ source: Idle) -> Change<Running, Effect.Start> { fatalError() }
            @Transition(onSuccess: Fetch.self)
            static func done(_ source: Running) -> Idle { fatalError() }
            @Transition(onFailure: Fetch.self)
            static func failed(_ source: Running, _ failure: Fetch.Failure) -> Failed { fatalError() }
        }
        """#

    static func fetching(failure: String, declarations: String = "") -> String {
        fetching.replacingOccurrences(of: "FAILURE", with: failure)
            .replacingOccurrences(of: "DECLARATIONS", with: declarations)
    }

    // MARK: Outcomes that cannot happen

    @Test func aFailureEdgeOfAnOperationThatCannotFailIsDiagnosedBeforeTheGraphIsAnalyzed() throws {
        let omitted = Self.fetching(failure: "")
            .replacingOccurrences(of: "_ failure: Fetch.Failure", with: "_ failure: Never")
        #expect(
            Self.diagnostics(omitted) == [
                "Operation 'Fetch' cannot fail: it declares no Failure, which means Never, so this onFailure: transition can never run; remove it, or declare the Failure the operation reports."
            ]
        )
        #expect(
            Self.diagnostics(Self.fetching(failure: "typealias Failure = Swift::Never")) == [
                "Operation 'Fetch' cannot fail: its Failure is Never, so this onFailure: transition can never run; remove it, or declare the Failure the operation reports."
            ]
        )
        // A `Never` the namespace reads through a name a member of its own could hide gives way to the
        // failure edge, and the expansion checks it instead.
        for spelling in ["Never", "Swift.Never", "( Never /* none */ )"] {
            let schema = try Self.parse(Self.fetching(failure: "typealias Failure = \(spelling)"))
            #expect(schema.operations.first?.isInfallible == false, "\(spelling)")
            #expect(
                TypeSpellingMatrixTests.checkMessage(schema, at: "Fetch.Failure")?
                    .hasPrefix("Operation 'Fetch' cannot fail: its Failure is Never") == true,
                "\(spelling)"
            )
        }
        // A router of the same outcome is diagnosed the same way.
        let routed = Self.fetching(failure: "typealias Failure = Swift::Never")
            .replacingOccurrences(
                of: "@Transition(onFailure: Fetch.self)",
                with: """
                    @Route(onFailure: Fetch.self)
                    static func triage(_ source: Running, _ failure: Fetch.Failure) -> Route.Triage { fatalError() }
                    @Transition(onFailure: Fetch.self)
                    """
            )
        #expect(
            Self.diagnostics(routed) == [
                "Operation 'Fetch' cannot fail: its Failure is Never, so this onFailure: router can never run; remove it, or declare the Failure the operation reports."
            ]
        )
    }

    @Test func aSchemaOwnNeverIsTheTypeItDeclares() throws {
        let source = Self.fetching(
            failure: "typealias Failure = Never",
            declarations: "enum Never: Error { case offline }"
        )
        let operation = try #require(try Self.parse(source).operations.first)
        #expect(!operation.isInfallible)
        #expect(operation.failure == "Fetch.Failure")
        #expect(try Self.expansion(source).contains("Swift::Result<Swift::Void, Fetch.Failure>"))
        // Its failure needs an edge, as every fallible operation's does.
        let unaccepted = source.replacingOccurrences(of: "@Transition(onFailure: Fetch.self)", with: "")
            .replacingOccurrences(
                of: "static func failed(_ source: Running, _ failure: Fetch.Failure) -> Failed { fatalError() }",
                with: "@Transition(on: Input.start)\nstatic func failed(_ source: Running) -> Failed { fatalError() }"
            )
        // Without a failure edge the operation reads as one that cannot fail, which the expansion checks,
        // since a member a namespace extension declares could take the name `Never`.
        let unacceptedSchema = try Self.parse(unaccepted)
        #expect(unacceptedSchema.operations.first?.isInfallible == true)
        #expect(
            TypeSpellingMatrixTests.checkMessage(unacceptedSchema, at: "Fetch.Failure")?
                .hasPrefix("Operation 'Fetch' has no onFailure: edge or router") == true
        )
        // Spelled through the standard library, `Never` keeps meaning the standard library's type.
        // A free `Swift` could be another declaration, so the failure edge decides and the expansion checks.
        let standard = Self.fetching(failure: "typealias Failure = Swift.Never", declarations: "enum Never: Error {}")
        #expect(
            TypeSpellingMatrixTests.checkMessage(try Self.parse(standard), at: "Fetch.Failure")?
                .hasPrefix("Operation 'Fetch' cannot fail") == true
        )
    }

    @Test func aSchemaOwnVoidIsTheTypeItDeclares() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Void {}
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case go }
                @Operation(activeIn: [Idle.self])
                enum Fetch { typealias Input = Void; typealias Output = Void }
                @Event enum Logged { typealias Payload = Void }
                @Transition(on: Input.go, starts: [Fetch.self], emits: [Logged.self])
                static func go(_ source: Idle) -> Change<Idle, Effect.Go> { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func done(_ source: Idle, _ output: Void) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        let operation = try #require(schema.operations.first)
        #expect(operation.takesInput && !operation.producesVoid)
        #expect(schema.events.first?.takesPayload == true)
        let text = try Self.expansion(source)
        #expect(text.contains("case fetch(Flow.Fetch.Input)"))
        #expect(text.contains("case logged(Flow.Logged.Payload)"))
        // The standard library's empty tuple still means no value.
        let standard =
            source.replacingOccurrences(
                of: "typealias Input = Void; typealias Output = Void",
                with: "typealias Input = Swift.Void; typealias Output = ()"
            )
            .replacingOccurrences(of: ", _ output: Void", with: "")
        #expect(try #require(try Self.parse(standard).operations.first).takesInput == false)
    }

    @Test func aNamespaceOwnNeverOrVoidIsTheTypeItDeclares() throws {
        let never = Self.fetching(failure: "enum Never: Error { case offline }; typealias Failure = Never")
        let operation = try #require(try Self.parse(never).operations.first)
        // The namespace declares the `Never` its alias names, so the macro confirms the reading.
        #expect(try !operation.isInfallible && Self.parse(never).typeChecks.isEmpty)
        #expect(try Self.expansion(never).contains("Swift::Result<Swift::Void, Fetch.Failure>"))
        #expect(!(try Self.expansion(never)).contains("_stateMachineIsSwiftNever"))
        let void = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case go }
                @Operation(activeIn: [Idle.self])
                enum Fetch { struct Void {}; typealias Input = Void; typealias Output = Void }
                @Event enum Logged { struct Void {}; typealias Payload = Void }
                @Transition(on: Input.go, starts: [Fetch.self], emits: [Logged.self])
                static func go(_ source: Idle) -> Change<Idle, Effect.Go> { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func done(_ source: Idle, _ output: Fetch.Void) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(void)
        #expect(try #require(schema.operations.first).takesInput)
        #expect(schema.events.first?.takesPayload == true && schema.standardNameChecks.isEmpty)
        #expect(schema.neverProbes.isEmpty)
    }

    /// A bare `Void` or `Never` is read as the standard library's type, which the macro cannot confirm
    /// for a type declared outside the schema, so the expansion checks each type read through one.
    @Test func aBareVoidOrNeverIsCheckedAgainstTheStandardLibrary() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Running {}
                @Initial case idle(Idle)
                case running(Running)
                enum Input { case start }
                @Operation(activeIn: [Running.self])
                enum Fetch { typealias Input = Void; typealias Output = Void; typealias Failure = Never }
                @Operation(activeIn: [Running.self])
                enum Upload { typealias Output = Never; typealias Failure = Problem }
                @Event enum Logged { typealias Payload = Void }
                @Transition(on: Input.start, starts: [Fetch.self, Upload.self], emits: [Logged.self])
                static func start(_ source: Idle) -> Change<Running, Effect.Start> { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func done(_ source: Running) -> Idle { fatalError() }
                @Transition(onFailure: Upload.self)
                static func lost(_ source: Running, _ failure: Upload.Failure) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        // Each alias and payload is checked itself, at the schema's scope, where it names the type its
        // declaration resolves to however its spelling's names resolve.
        let expected = [
            "Void Fetch.Input", "Void Fetch.Output", "Never Fetch.Failure", "Never Upload.Output",
            "Void Logged.Payload",
        ]
        #expect(schema.standardNameChecks.map { "\($0.standard) \($0.reference)" } == expected)
        let text = try Self.expansion(source)
        #expect(text.contains("fileprivate static func _stateMachineIsSwiftVoid(_ type: Swift::Void.Type) {}"))
        #expect(text.contains("fileprivate static func _stateMachineIsSwiftNever(_ type: Swift::Never.Type) {}"))
        #expect(
            text.contains(
                "do { typealias _StateMachineChecked = Fetch.Input; _stateMachineIsSwiftVoid(_StateMachineChecked.self) }"
            )
        )
        #expect(
            text.contains(
                "do { typealias _StateMachineChecked = Upload.Output; _stateMachineIsSwiftNever2(_StateMachineChecked.self) }"
            )
        )
        #expect(schema.fixedGeneratedNames.isSuperset(of: ["_stateMachineIsSwiftVoid", "_stateMachineIsSwiftNever"]))
        // A spelling through a free `Swift` is checked as well, since a declaration outside the schema
        // could take the module's name.
        let qualified = source.replacingOccurrences(
            of: "typealias Output = Never;",
            with: "typealias Output = Swift.Never;"
        )
        #expect(try Self.parse(qualified).standardNameChecks.map { "\($0.standard) \($0.reference)" } == expected)
        // A spelling that no declaration can shadow needs no check, and neither does an omitted alias.
        let unshadowable =
            source.replacingOccurrences(
                of: "typealias Input = Void; typealias Output = Void; typealias Failure = Never",
                with: "typealias Input = Swift::Void; typealias Output = (); typealias Failure = Swift::Never"
            )
            .replacingOccurrences(of: "typealias Output = Never;", with: "typealias Output = Swift::Never;")
            .replacingOccurrences(of: "typealias Payload = Void", with: "")
        let checked = try Self.parse(unshadowable)
        #expect(checked.standardNameChecks.isEmpty)
        #expect(!(try Self.expansion(unshadowable)).contains("_stateMachineIsSwift"))
        #expect(!(try Self.parse(unshadowable).fixedGeneratedNames).contains("_stateMachineIsSwiftVoid"))
    }

    @Test func aBareNeverInASchemaSignatureIsCheckedAtTheSchemaScope() throws {
        let advancing = #"""
            @StateMachine(mode: .ownedOnly)
            enum Flow {
                struct Idle {}
                struct Done {}
                @Initial case idle(Idle)
                @Terminal case done(Done)
                @Transition
                static func go(_ source: consuming Idle) -> Advance<Idle, Done, Never, Problem> { fatalError() }
            }
            """#
        let schema = try Self.parse(advancing)
        #expect(schema.standardNameChecks.map(\.reference) == ["Never"])
        let advanced = try Self.expansion(advancing)
        #expect(
            advanced.contains(
                "do { typealias _StateMachineChecked = Never; _stateMachineIsSwiftNever(_StateMachineChecked.self) }"
            )
        )
        let qualified = advancing.replacingOccurrences(of: "Done, Never, Problem", with: "Done, Swift::Never, Problem")
        #expect(try Self.parse(qualified).standardNameChecks.isEmpty)
        let routing = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Done {}
                @Initial case idle(Idle)
                @Terminal case done(Done)
                enum Input { case go, finish }
                @Transition(on: Input.finish)
                static func finish(_ source: Idle) -> Done { fatalError() }
                @Route(on: Input.go, failure: Problem.self)
                static func route(_ source: Idle) throws(Problem) -> Never { fatalError() }
            }
            """#
        #expect(try Self.parse(routing).standardNameChecks.map(\.reference) == ["Never"])
        let spelled = routing.replacingOccurrences(of: "-> Never", with: "-> Swift::Never")
        #expect(try Self.parse(spelled).standardNameChecks.isEmpty)
    }

    @Test func onlyAStandardReadingThroughANameTheMacroCannotConfirmIsChecked() {
        let scopes = LexicalScopes()
        func unconfirmedStandard(_ reading: ResolvedType) -> Bool {
            (reading.isVoid || reading.isNever) && !reading.isConfirmed
        }
        for spelling in ["Void", "Never", "( Never /*none*/ )", "((Void))", "Swift.Void", "Swift . Never"] {
            #expect(unconfirmedStandard(scopes.resolve(spelling)), "\(spelling)")
        }
        for spelling in [
            "Swift::Void", "()", "( )", "Swift::Never", "Void?", "Module.Void", "(Void, Void)", "Module::Never",
        ] {
            #expect(!unconfirmedStandard(scopes.resolve(spelling)), "\(spelling)")
        }
        for spelling in ["Module.Void", "Module::Never", "Problem", "Item.ID"] {
            #expect(scopes.resolve(spelling).isOpaque, "\(spelling)")
        }
        for spelling in ["Void?", "(Void, Void)", "[Never]", "() -> Void", "Swift.Int", "Swift::Int"] {
            #expect(scopes.resolve(spelling).reading == .visible, "\(spelling)")
        }
    }

    @Test func anOperationWhoseOutputIsNeverHasNoSuccessEdge() throws {
        let listening =
            Self.fetching(
                failure: "typealias Output = Never; typealias Failure = Problem",
                declarations: "enum Problem: Error { case lost }"
            )
            .replacingOccurrences(of: "@Transition(onSuccess: Fetch.self)", with: "")
            .replacingOccurrences(of: "static func done(_ source: Running) -> Idle { fatalError() }", with: "")
        let schema = try Self.parse(listening)
        #expect(try #require(schema.operations.first).neverSucceeds)
        #expect(!(try Self.expansion(listening)).contains("func succeeded(_ value: Fetch.Output)"))
        let succeeding =
            Self.fetching(
                failure: "typealias Output = Never; typealias Failure = Problem",
                declarations: "enum Problem: Error { case lost }"
            )
            .replacingOccurrences(
                of: "static func done(_ source: Running) -> Idle",
                with: "static func done(_ source: Running, _ value: Never) -> Idle"
            )
        // The namespace's bare `Never` could be a member an extension gives it, so the success edge decides
        // and the expansion checks; `Swift::Never` is confirmed and diagnosed.
        #expect(
            TypeSpellingMatrixTests.checkMessage(try Self.parse(succeeding), at: "Fetch.Output")?
                .hasPrefix("Operation 'Fetch' never succeeds") == true
        )
        #expect(
            Self.diagnostics(
                succeeding.replacingOccurrences(of: "typealias Output = Never", with: "typealias Output = Swift::Never")
            ) == [
                "Operation 'Fetch' never succeeds: its Output is Never, so this onSuccess: transition can never run; remove it, or declare the Output the operation produces."
            ]
        )
        let neverFinishing = listening.replacingOccurrences(of: "typealias Failure = Problem", with: "")
            .replacingOccurrences(of: "@Transition(onFailure: Fetch.self)", with: "")
            .replacingOccurrences(
                of: "static func failed(_ source: Running, _ failure: Fetch.Failure) -> Failed { fatalError() }",
                with: ""
            )
        let finishing =
            "Operation 'Fetch' can never finish: its Output and its Failure are both Never, so its driver could never return, even once its work is cancelled; declare the Output it produces, or a Failure it reports when it stops."
        // An unconfirmed `Never` is checked to be one, and then the pair is checked not to be.
        let leaving = neverFinishing.replacingOccurrences(
            of: "@Transition(on: Input.start, starts: [Fetch.self])",
            with:
                "@Transition(on: Input.start)\nstatic func stop(_ source: Running) -> Failed { fatalError() }\n@Transition(on: Input.start, starts: [Fetch.self])"
        )
        #expect(TypeSpellingMatrixTests.checkMessage(try Self.parse(leaving), at: "Fetch") == finishing)
        #expect(
            Self.diagnostics(
                neverFinishing.replacingOccurrences(
                    of: "typealias Output = Never",
                    with: "typealias Output = Swift::Never"
                )
            )
                == [finishing]
        )
    }

    @Test func triggersAndStartsThatCarryNeverAreDiagnosed() throws {
        let input = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Done {}
                @Initial case idle(Idle)
                @Terminal case done(Done)
                enum Input { case finish(Swift::Never), skip }
                @Transition(on: Input.finish)
                static func finish(_ source: Idle, _ value: Never) -> Done { fatalError() }
                @Transition(on: Input.skip)
                static func skip(_ source: Idle) -> Idle { fatalError() }
            }
            """#
        let carries =
            "Input case 'finish' carries Never, so no input can ever have this case; remove the case, or give it a payload that has values."
        #expect(Self.diagnostics(input) == [carries])
        // A case that no edge uses is diagnosed where it is declared, as is one that carries `Never`
        // through an alias `Input` declares.
        let unused =
            input
            .replacingOccurrences(of: "@Transition(on: Input.finish)", with: "")
            .replacingOccurrences(
                of: "static func finish(_ source: Idle, _ value: Never) -> Done { fatalError() }",
                with: ""
            )
        #expect(Self.diagnostics(unused)?.first?.hasPrefix("Input case 'finish' carries Never") == true)
        let aliased = unused.replacingOccurrences(
            of: "enum Input { case finish(Swift::Never), skip }",
            with: "enum Input { typealias Nothing = Swift::Never; case finish(Nothing), skip }"
        )
        #expect(Self.diagnostics(aliased)?.first?.hasPrefix("Input case 'finish' carries Never") == true)
        // A `Never` that `Input` reads through a name a member of its own could hide is checked where
        // `Input` resolves it, through the case's constructor.
        for unconfirmed in [
            "enum Input { case finish(Never), skip }",
            "enum Input { typealias Nothing = Swift.Never; case finish(Nothing), skip }",
            "typealias Nothing = Never\n    enum Input { case finish(Nothing), skip }",
        ] {
            let source = input.replacingOccurrences(
                of: "enum Input { case finish(Swift::Never), skip }",
                with: unconfirmed
            )
            let schema = try Self.parse(source)
            #expect(TypeSpellingMatrixTests.checkMessage(schema, at: "finish") == carries, "\(unconfirmed)")
            #expect(try Self.expansion(source).contains("case .finish(let bound):"), "\(unconfirmed)")
            #expect(try Self.expansion(source).contains("_stateMachineCasePayload(bound)"), "\(unconfirmed)")
        }
        // A type of that name the schema declares has values.
        let own = unused.replacingOccurrences(of: "case finish(Swift::Never)", with: "case finish(Never)")
            .replacingOccurrences(of: "enum Input {", with: "enum Never {}\n    enum Input {")
        #expect(Self.diagnostics(own)?.first?.hasPrefix("Input case") != true)
        let key =
            "Operation 'Fetch' takes Never as its key, so no transition can start it; declare a key type that has values, or remove the operation."
        #expect(Self.diagnostics(Self.fetching(failure: "typealias Key = Swift::Never")) == [key])
        let start = try Self.parse(
            Self.fetching(
                failure: "typealias Key = Never; typealias Failure = Problem",
                declarations: "enum Problem: Error { case lost }"
            )
        )
        #expect(TypeSpellingMatrixTests.checkMessage(start, at: "Fetch.Key") == key)
    }

    // MARK: Authored spellings

    @Test func customAttributesInSpellingsAreQualifiedAndBuiltInOnesAreKept() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input {
                    @globalActor actor DecodeActor { static let shared = DecodeActor() }
                    struct Int {}
                    struct Sendable {}
                    case decode(@DecodeActor @Sendable () -> Swift::Int)
                    case local(Int)
                }
                @Transition(on: Input.decode)
                static func decode(_ source: Idle, _ work: @Input.DecodeActor @Sendable () -> Swift.Int) -> Idle { fatalError() }
                @Transition(on: Input.local)
                static func local(_ source: Idle, _ value: Input.Int) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        // An input payload means what it means inside `Input`, so it keeps its authored spelling.
        #expect(schema.inputs.map(\.payloadType) == ["@DecodeActor @Sendable () -> Swift::Int", "Int"])
        #expect(
            TypeQualifier.qualify("@convention(c) () -> Int", owner: "Input", names: ["Int", "c"])
                == "@convention(c) () -> Input.Int"
        )
        #expect(
            Schema.freeNames("@MainActor (Swift::Int, Phase.Value, [Owner: Host]) -> Never") == [
                "MainActor", "Phase", "Owner", "Host", "Never",
            ]
        )
    }

    @Test func routerFailuresAndResultsCompareByWhatTheyName() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                enum Problem: Error { case no }
                struct Idle {}
                struct A {}
                struct B {}
                @Initial case idle(Idle)
                case a(A)
                case b(B)
                enum Input { case go, back }
                @Route(on: Input.go)
                static func choose(_ source: Idle) -> RESULT { fatalError() }
                @Transition(on: Input.go)
                static func toA(_ source: Idle) throws(Problem) -> A { fatalError() }
                @Transition(on: Input.go)
                static func toB(_ source: Idle) throws(Self /* the schema */ .Problem) -> B { fatalError() }
                @Transition(from: [A.self, B.self], on: Input.back)
                static func back() -> Idle { fatalError() }
            }
            """#
        for result in ["Route.Choose", "Self.Route.Choose", "Flow.Route.Choose", "Route /* choice */ .Choose"] {
            let schema = try Self.parse(source.replacingOccurrences(of: "RESULT", with: result))
            let route = try #require(schema.routes.first)
            #expect(Generator(schema: schema).routedFailure(route) == "Problem", "\(result)")
            #expect(
                Schema.rejectionCase("toA", from: "idle", distinguished: schema.namesThrowingDifferentFailures) == "toA"
            )
        }
        #expect(
            Schema.relativeKey("Self.Route.Choose", schema: "Flow")
                == Schema.relativeKey("Route.Choose", schema: "Flow")
        )
        #expect(
            Schema.relativeKey("Other.Route.Choose", schema: "Flow")
                != Schema.relativeKey("Route.Choose", schema: "Flow")
        )
    }

    // MARK: Names generated namespaces declare

    @Test func aGeneratedNamespaceNamedForAModuleSpellsThatModuleThroughASelector() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow: Hashable {
                struct Idle: Hashable {}
                struct A: Hashable {}
                @Initial case idle(Idle)
                case a(A)
                enum Input { case go, back, log }
                @Event enum Logged {}
                @Route(on: Input.go)
                static func swift(_ source: Idle) -> Route.Swift { fatalError() }
                @Transition(on: Input.go)
                static func stay(_ source: Idle) -> Idle { fatalError() }
                @Transition(on: Input.go)
                static func leave(_ source: Idle) -> A { fatalError() }
                @Transition(on: Input.back)
                static func back(_ source: A) -> Idle { fatalError() }
                @Transition(on: Input.log, emits: [Logged.self])
                static func stateMachine(_ source: Idle) -> Change<Idle, Effect.StateMachine> { fatalError() }
            }
            """#
        let text = try Self.expansion(source)
        #expect(text.contains("enum Swift: Swift::Sendable, Swift::Equatable, Swift::Hashable, Swift::CaseIterable"))
        #expect(text.contains("enum StateMachine: Swift::Sendable, Swift::Hashable"))
        // Every module the expansion names, it names through a selector.
        #expect(!text.contains("Swift.") && !text.contains("StateMachine."))
    }

    @Test func anOwnedResultThatWouldHideTheSchemaIsDiagnosed() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum FlowResult {
                struct Idle {}
                struct A {}
                @Initial case idle(Idle)
                case a(A)
                enum Input { case go, back }
                @Route(on: Input.go)
                static func flow(_ source: Idle) -> Route.Flow { fatalError() }
                @Transition(on: Input.go)
                static func stay(_ source: Idle) -> Idle { fatalError() }
                @Transition(on: Input.go)
                static func leave(_ source: Idle) -> A { fatalError() }
                @Transition(on: Input.back)
                static func back(_ source: A) -> Idle { fatalError() }
            }
            """#
        #expect(
            Self.diagnostics(source) == [
                "This router's owned result type would be Route.FlowResult, which hides the schema 'FlowResult' inside Route; rename the router."
            ]
        )
        // Without `Owned`, no result type exists to hide the schema.
        #expect(
            Self.diagnostics(source.replacingOccurrences(of: "mode: .shared", with: "mode: .shared, owners: [.local]"))
                == nil
        )
    }

    @Test func authoredTypesThatANestedGeneratedScopeWouldCaptureGoThroughSchemaAliases() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Open {}
                @Initial case idle(Idle)
                case open(Open)
                enum Input { case open(Phase), close }
                @Transition(on: Input.open)
                static func open(_ source: Idle, _ phase: Phase) throws(Host) -> Open { fatalError() }
                @Transition(on: Input.close)
                static func close(_ source: Open) -> Idle { fatalError() }
                @Restoration
                static func restore(_ saved: Owner) -> Restoration { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.shieldedSpellings.map(\.spelling) == ["Phase", "Host", "Owner"])
        #expect(schema.reservedNames.isDisjoint(with: ["_StateMachineType1", "_StateMachineType2"]))
        let text = try Self.expansion(source)
        // `Owned` and `Observed` declare `Phase`, which captures the payload; nothing around a use of
        // the failure declares `Host`, so it is spelled as authored; `IsolatedHost` declares `Owner`.
        #expect(
            text.split(separator: "\n").filter { $0.contains("typealias _StateMachineType") } == [
                "internal typealias _StateMachineType1 = Phase", "internal typealias _StateMachineType2 = Owner",
            ]
        )
        #expect(text.contains("init(restoring saved: _StateMachineType2, isolation: isolated Owner"))
        #expect(text.contains("func open(_ input: _StateMachineType1) throws(Host)"))
        // A spelling no nested scope captures is repeated as written.
        let plain = try Self.parse(source.replacingOccurrences(of: "Owner", with: "Archive"))
        #expect(plain.shieldedSpellings.map(\.spelling) == ["Phase", "Host"])
    }

    /// An alias exists only for a use that a generated scope captures, with that use's access, and its
    /// documentation shows the spelling on one line.
    @Test func aSpellingAliasFollowsTheUsesThatNeedIt() throws {
        let multiline = #"""
            @StateMachine(mode: .shared)
            public enum Flow {
                public struct Idle {}
                public struct Busy {}
                @Initial case idle(Idle)
                case busy(Busy)
                public enum Input {
                    case go((
                        Phase, // the outer phase
                        Int
                    ))
                    case back
                }
                @Transition(on: Input.go)
                public static func go(_ source: Idle, _ value: (
                    Phase, // the outer phase
                    Int
                )) -> Busy { fatalError() }
                @Transition(on: Input.back)
                public static func back(_ source: Busy) -> Idle { fatalError() }
            }
            """#
        let text = try Self.expansion(multiline)
        #expect(text.contains("/// `(Phase, Int)` as the schema resolves it"))
        #expect(text.contains("public typealias _StateMachineType1 = ("))
        // An authored identifier is never taken by an alias, so the alias cannot capture it.
        let named = multiline.replacingOccurrences(of: "        Int\n", with: "        _StateMachineType1\n")
        let renamed = try Self.expansion(named)
        #expect(renamed.contains("public typealias _StateMachineType2 = ("))
        #expect(!renamed.contains("typealias _StateMachineType1 ="))
        // A failure that only an unused router throws needs no alias at all.
        let refusing = #"""
            @StateMachine(mode: .shared, owners: [.owned])
            public enum Flow {
                public struct Idle {}
                public struct Busy {}
                @Initial case idle(Idle)
                case busy(Busy)
                public enum Input { case go, back }
                @Route(on: Input.back)
                fileprivate static func refuse(_ source: Busy) throws(Phase) -> Never { fatalError() }
                @Transition(on: Input.go)
                public static func go(_ source: Idle) -> Busy { fatalError() }
                @Transition(on: Input.go)
                public static func again(_ source: Busy) -> Idle { fatalError() }
            }
            """#
        #expect(!(try Self.expansion(refusing)).contains("_StateMachineType"))
        // A use inside routed edges' file-private methods gives a file-private alias.
        let routed = #"""
            @StateMachine(mode: .shared, owners: [.owned])
            public enum Flow {
                public struct Idle {}
                public struct Busy {}
                @Initial case idle(Idle)
                case busy(Busy)
                public enum Input { case go(Int), back }
                @Transition(on: Input.go)
                static func stay(_ source: Idle, _ value: Phase.Count) -> Idle { fatalError() }
                @Transition(on: Input.go)
                static func leave(_ source: Idle, _ value: Phase.Count) -> Busy { fatalError() }
                @Route(on: Input.go)
                public static func pick(_ source: Idle, _ value: Int) -> Route.Pick { fatalError() }
                @Transition(on: Input.back)
                public static func back(_ source: Busy) -> Idle { fatalError() }
            }
            """#
        let routedText = try Self.expansion(routed)
        #expect(
            routedText.contains("fileprivate typealias _StateMachineType1 = Phase.Count"),
            "\(routedText.split(separator: "\n").filter { $0.contains("_StateMachineType") })"
        )
    }

    @Test func cancellationCasesAreCheckedAgainstEveryEmittedEffectCase() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case start(Int), stop(Int) }
                @Operation(activeIn: [Idle.self])
                enum Sync { typealias Key = Int }
                @Operation(activeIn: [Idle.self])
                enum AllSync { typealias Key = Int }
                @Transition(on: Input.start, starts: [Sync.self, AllSync.self])
                static func start(_ source: Idle, _ id: Int) -> Change<Idle, Effect.Start> { fatalError() }
                @Transition(on: Input.stop, cancels: [Sync.self, AllSync.self])
                static func stop(_ source: Idle, _ id: Int) -> Change<Idle, Effect.Stop> { fatalError() }
                @Transition(onSuccess: Sync.self)
                static func synced(_ source: Idle) -> Idle { fatalError() }
                @Transition(onSuccess: AllSync.self)
                static func allSynced(_ source: Idle) -> Idle { fatalError() }
            }
            """#
        #expect(
            Self.diagnostics(source) == [
                "Keyed operation 'Sync' generates the effect case 'cancelAllSync' to cancel all of its work, which keyed operation 'AllSync' also generates to cancel one key's work; rename one.",
                "Keyed operation 'AllSync' generates the effect case 'cancelAllSync' to cancel one key's work, which keyed operation 'Sync' also generates to cancel all of its work; rename one.",
            ]
        )
        // Cancelling only one of them emits no second case of that name.
        #expect(
            Self.diagnostics(
                source.replacingOccurrences(of: "cancels: [Sync.self, AllSync.self]", with: "cancels: [AllSync.self]")
            ) == nil
        )
    }

    @Test func rejectionCasesAreCheckedByTheNamesTheyFinallyHave() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                enum ProblemA: Error { case a }
                enum ProblemB: Error { case b }
                struct A {}
                struct B {}
                @Initial case a(A)
                case b(B)
                enum Input { case go }
                @Transition(on: Input.go)
                static func invalidPhase(_ source: A) throws(ProblemA) -> B { fatalError() }
                @Transition(on: Input.go)
                static func invalidPhase(_ source: B) throws(ProblemB) -> A { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(
            Schema.rejectionCase("invalidPhase", from: "a", distinguished: schema.namesThrowingDifferentFailures)
                == "aInvalidPhase"
        )
        #expect(
            Schema.rejectionCase("invalidPhase", from: "b", distinguished: schema.namesThrowingDifferentFailures)
                == "bInvalidPhase"
        )
        // One failure type, however it is spelled, keeps the function's own name.
        let same = source.replacingOccurrences(of: "throws(ProblemB)", with: "throws(Self.ProblemA)")
        #expect(
            Self.diagnostics(same) == [
                "'invalidPhase' is already a PreparationRejection case; rename this throwing transition."
            ]
        )
    }

    @Test func effectNamesAreCheckedAgainstTheMembersTheirEnumsDeclare() throws {
        let events = #"""
            @StateMachine(mode: .shared, owners: OWNERS)
            enum Flow {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case go, fetch }
                @Event enum Cancel {}
                @Event enum Authority {}
                @Transition(on: Input.go, emits: [Cancel.self, Authority.self])
                static func go(_ source: Idle) -> Change<Idle, Effect.Go> { fatalError() }
                OPERATION
            }
            """#
        func source(owners: String, operation: String = "") -> String {
            events.replacingOccurrences(of: "OWNERS", with: owners)
                .replacingOccurrences(of: "OPERATION", with: operation)
        }
        // Without operations, `Command` has no cancel case and `Completion` does not exist.
        #expect(Self.diagnostics(source(owners: "[.local]")) == nil)
        #expect(Self.diagnostics(source(owners: "[.local, .shared]")) == nil)
        let fetch = """
            @Operation(activeIn: [Idle.self])
            enum Fetch {}
            @Transition(on: Input.fetch, starts: [Fetch.self])
            static func fetch(_ source: Idle) -> Change<Idle, Effect.Fetch> { fatalError() }
            @Transition(onSuccess: Fetch.self)
            static func fetched(_ source: Idle) -> Idle { fatalError() }
            """
        #expect(
            Self.diagnostics(source(owners: "[.local]", operation: fetch)) == [
                "Event 'Cancel' would generate the case 'cancel' in Local's Command, which already has a cancel case that cancels work; rename the namespace with a distinct capitalized name."
            ]
        )
        // An event is never a case of `Completion`, and only `Local` has `Command`.
        #expect(Self.diagnostics(source(owners: "[.shared]", operation: fetch)) == nil)
        let authority = fetch.replacingOccurrences(of: "enum Fetch", with: "enum Authority")
            .replacingOccurrences(of: "Fetch.self", with: "Authority.self")
        let operations = events.replacingOccurrences(of: "@Event enum Authority {}", with: "")
            .replacingOccurrences(of: ", Authority.self]", with: "]")
            .replacingOccurrences(of: "OWNERS", with: "[.shared]")
            .replacingOccurrences(of: "OPERATION", with: authority)
        // `Completion`'s `authority` case is a different declaration from its `authority` property.
        #expect(Self.diagnostics(operations) == nil, "\(Self.diagnostics(operations) ?? [])")
        #expect(try Self.expansion(operations).contains("case authority(AuthorityCompletion)"))
    }

    @Test func anOperationTypeThatTheExpansionAlreadyDeclaresIsDiagnosed() throws {
        let source = #"""
            @StateMachine(mode: .shared, owners: OWNERS)
            enum Flow {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case go }
                @Operation(activeIn: [Idle.self])
                enum Pending {}
                @Transition(on: Input.go, starts: [Pending.self])
                static func go(_ source: Idle) -> Change<Idle, Effect.Go> { fatalError() }
                @Transition(onSuccess: Pending.self)
                static func done(_ source: Idle) -> Idle { fatalError() }
            }
            """#
        #expect(
            Self.diagnostics(source.replacingOccurrences(of: "OWNERS", with: "[.shared]")) == [
                "Operation 'Pending' would generate the type 'PendingCompletion', which the expansion already declares for this schema's owners; rename the operation."
            ]
        )
        // `Owned` alone generates neither type.
        #expect(Self.diagnostics(source.replacingOccurrences(of: "OWNERS", with: "[.owned]")) == nil)
    }

    @Test func macroAttributesAndValueConformancesResolveThroughSyntax() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow: Swift /* standard */ .Hashable {
                struct Idle: Hashable {}
                @Initial case idle(Idle)
                enum Input { case go }
                @StateMachine::Transition(on: Input.go)
                static func go(_ source: Idle) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.valueConformances == ["Hashable"])
        #expect(schema.transitions.map(\.name) == ["go"])
        // A schema's own `Hashable` is not the standard library's.
        let shadowed = source.replacingOccurrences(of: "Swift /* standard */ .Hashable", with: "Hashable")
            .replacingOccurrences(of: "struct Idle: Hashable {}", with: "protocol Hashable {}\nstruct Idle {}")
        // The clause is read where the schema is declared, so a protocol the body declares does not take it.
        #expect(try Self.parse(shadowed).valueConformances == ["Hashable"])
    }
}
