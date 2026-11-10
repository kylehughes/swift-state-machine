import Foundation
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

struct SchemaTests {
    static let schema = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            struct Idle {}
            struct Loading {}
            @Initial case idle(Idle)
            case loading(Loading)
            enum Scope { case load }
            enum Input { case start(Int); case cancel }
            @Operation(scope: Scope.load, activeIn: [Loading.self], admission: .latest)
            enum Fetch { typealias Input = Int; typealias Output = String; typealias Failure = Never }
            @Transition(on: Input.start, starts: [Fetch.self])
            static func begin(_ source: borrowing Idle, _ input: Int) throws(MyError) -> Change<Loading, Effect.Begin> { fatalError() }
            @Transition(on: Input.cancel, invalidates: [Scope.load])
            static func cancel(_ source: Loading) -> Idle { fatalError() }
            @Transition(onSuccess: Fetch.self)
            static func received(_ source: borrowing Loading, _ input: Fetch.Output) -> Idle { fatalError() }
        }
        """#
    private static func parse(_ text: String) throws -> Schema {
        let syntax = Parser.parse(source: text)
        guard let declaration = syntax.statements.first?.item.as(EnumDeclSyntax.self),
            let attribute = declaration.attributes.first?.as(AttributeSyntax.self)
        else { fatalError("Malformed test fixture") }
        return try Schema.parse(declaration, attribute: attribute, context: BasicMacroExpansionContext())
    }
    @Test func parsesLexicalSchemaAndTypedFailure() throws {
        let result = try Self.parse(Self.schema)
        #expect(result.phases.map(\.caseName) == ["idle", "loading"])
        #expect(result.initial == "idle")
        #expect(result.scopes == ["load"])
        #expect(result.transitions.count == 3)
        #expect(result.transitions.map(\.from) == ["idle", "loading", "loading"])
        #expect(result.transitions.map(\.to) == ["loading", "idle", "idle"])
        #expect(result.transitions.map(\.trigger.kind) == [.input, .input, .success])
        #expect(result.transitions.map(\.trigger.name) == ["start", "cancel", "fetch"])
        #expect(result.transitions.first?.starts == ["fetch"])
        #expect(result.transitions.map(\.effectNamespace) == ["Begin", nil, nil])
        #expect(result.operations.map(\.effect) == ["fetch"])
        #expect(result.operations.first?.activeIn == ["loading"])
        #expect(result.transitions.first?.failureType == "MyError")
        #expect(result.operations.first?.inputType == "Int")
    }

    @Test func rejectsMalformedMetadataAndSignatures() throws {
        let schema = Self.schema
        let failures: [(String, String)] = [
            ("generic schema", schema.replacingOccurrences(of: "enum Flow", with: "enum Flow<Value>")),
            ("aliased phase", schema.replacingOccurrences(of: "struct Idle {}", with: "typealias Idle = Loading")),
            ("input payload arity", schema.replacingOccurrences(of: "case start(Int)", with: "case start(Int, Int)")),
            (
                "hand-written effect",
                schema.replacingOccurrences(
                    of: "struct Idle {}",
                    with: "struct Idle {}\nenum Effect { case fetch(Int) }"
                )
            ),
            (
                "change without starts",
                schema.replacingOccurrences(of: "Loading) -> Idle", with: "Loading) -> Change<Idle, Never>")
            ),
            (
                "plain result with starts",
                schema.replacingOccurrences(of: "-> Change<Loading, Effect.Begin>", with: "-> Loading")
            ),
            ("schema-wide effect", schema.replacingOccurrences(of: "Effect.Begin", with: "Effect")),
            ("another edge's effect", schema.replacingOccurrences(of: "Effect.Begin", with: "Effect.Cancel")),
            (
                "advance in a value mode",
                schema.replacingOccurrences(
                    of: "throws(MyError) -> Change<Loading, Effect.Begin>",
                    with: "-> Advance<Idle, Loading, Effect.Begin, MyError>"
                )
            ),
            ("keyword effect case", schema.replacingOccurrences(of: "Fetch", with: "Default")),
            ("effect case colliding with a command", schema.replacingOccurrences(of: "Fetch", with: "Cancel")),
            ("uncapitalized operation", schema.replacingOccurrences(of: "Fetch", with: "fetch")),
            (
                "unavailable effect namespace",
                schema.replacingOccurrences(of: "func begin(", with: "func effect(")
                    .replacingOccurrences(of: "Effect.Begin", with: "Effect.Effect")
            ),
            ("consuming value source", schema.replacingOccurrences(of: "borrowing Idle", with: "consuming Idle")),
            (
                "invalid invalidation",
                schema.replacingOccurrences(of: "invalidates: [Scope.load]", with: "invalidates: [Scope.absent]")
            ),
            (
                "unsupported marker placement",
                schema.replacingOccurrences(
                    of: "struct Idle {}",
                    with:
                        "@Operation(scope: Scope.load, activeIn: [Loading.self], admission: .latest) struct Idle {}"
                )
            ),
            ("missing initial", schema.replacingOccurrences(of: "@Initial case idle", with: "case idle")),
            (
                "duplicate initial",
                schema.replacingOccurrences(of: "case loading(Loading)", with: "@Initial case loading(Loading)")
            ),
            ("initial arguments", schema.replacingOccurrences(of: "@Initial case", with: "@Initial(true) case")),
            (
                "initial on a type",
                schema.replacingOccurrences(of: "struct Loading {}", with: "@Initial struct Loading {}")
            ),
            (
                "scope payload",
                schema.replacingOccurrences(of: "enum Scope { case load }", with: "enum Scope { case load(Int) }")
            ),
            (
                "duplicate scopes",
                schema.replacingOccurrences(of: "enum Scope { case load }", with: "enum Scope { case load, load }")
            ),
            ("string metadata", schema.replacingOccurrences(of: "on: Input.start", with: "on: \"start\"")),
            ("implicit member metadata", schema.replacingOccurrences(of: "on: Input.start", with: "on: .start")),
            ("qualified metadata", schema.replacingOccurrences(of: "on: Input.start", with: "on: Flow.Input.start")),
            ("computed metadata", schema.replacingOccurrences(of: "scope: Scope.load", with: "scope: primaryScope")),
            ("misplaced case reference", schema.replacingOccurrences(of: "on: Input.start", with: "on: Scope.load")),
            (
                "removed endpoint labels",
                schema.replacingOccurrences(of: "on: Input.cancel", with: "from: Loading.self, on: Input.cancel")
            ),
            ("unknown starts", schema.replacingOccurrences(of: "starts: [Fetch.self]", with: "starts: [Missing.self]")),
            (
                "phase as operation",
                schema.replacingOccurrences(of: "starts: [Fetch.self]", with: "starts: [Loading.self]")
            ),
            (
                "duplicate starts",
                schema.replacingOccurrences(of: "starts: [Fetch.self]", with: "starts: [Fetch.self, Fetch.self]")
            ),
            (
                "ineligible starts",
                schema.replacingOccurrences(of: "activeIn: [Loading.self]", with: "activeIn: [Idle.self]")
            ),
            (
                "operation as active phase",
                schema.replacingOccurrences(of: "activeIn: [Loading.self]", with: "activeIn: [Fetch.self]")
            ),
            ("unknown source", schema.replacingOccurrences(of: "borrowing Idle", with: "borrowing Missing")),
            (
                "unknown destination",
                schema.replacingOccurrences(
                    of: "throws(MyError) -> Change<Loading,",
                    with: "-> Change<Missing,"
                )
            ),
            (
                "two triggers",
                schema.replacingOccurrences(of: "on: Input.cancel", with: "on: Input.cancel, onSuccess: Fetch.self")
            ),
            ("no trigger", schema.replacingOccurrences(of: "@Transition(onSuccess: Fetch.self)", with: "@Transition")),
            (
                "unknown completion",
                schema.replacingOccurrences(of: "onSuccess: Fetch.self", with: "onSuccess: Missing.self")
            ),
            ("untyped throws", schema.replacingOccurrences(of: "throws(MyError)", with: "throws")),
            ("async transition", schema.replacingOccurrences(of: "throws(MyError)", with: "async throws(MyError)")),
            ("reused phase", schema.replacingOccurrences(of: "case loading(Loading)", with: "case loading(Idle)")),
            ("malformed admission", schema.replacingOccurrences(of: ".latest", with: ".parallel(limit: 0)")),
            ("unknown trigger", schema.replacingOccurrences(of: "on: Input.start", with: "on: Input.absent")),
            (
                "missing completion route",
                schema.replacingOccurrences(
                    of:
                        "@Transition(onSuccess: Fetch.self)\n    static func received(_ source: borrowing Loading, _ input: Fetch.Output) -> Idle { fatalError() }",
                    with: ""
                )
            ),
            (
                "reserved declaration",
                schema.replacingOccurrences(of: "struct Idle {}", with: "struct Idle {}\nstruct Owned {}")
            ),
        ]
        for (label, text) in failures {
            do {
                _ = try Self.parse(text)
                Issue.record("Expected rejection: \(label)")
            } catch let error as DiagnosticsError {
                #expect(!error.diagnostics.isEmpty, "Missing diagnostic: \(label)")
            }
        }
    }

    @Test func diagnosesEndpointsAndReferencesAtTheirSpelling() throws {
        let failures: [(String, String)] = [
            (
                Self.schema.replacingOccurrences(of: "borrowing Idle", with: "borrowing Missing"),
                "Source 'Missing' is not a phase payload type declared in this schema."
            ),
            (
                Self.schema.replacingOccurrences(of: "Change<Loading,", with: "Change<Missing,"),
                "Destination 'Missing' is not a phase payload type declared in this schema."
            ),
            (
                Self.schema.replacingOccurrences(of: "on: Input.start", with: "on: \"start\""),
                "Reference a declared case as Input.<case>."
            ),
            (
                Self.schema.replacingOccurrences(of: "starts: [Fetch.self]", with: "starts: [Missing.self]"),
                "'Missing' is not a declared @Operation namespace."
            ),
            (
                Self.schema.replacingOccurrences(of: "struct Idle {}", with: "struct Idle {}\nenum Effect {}"),
                "Effect is generated from the @Operation namespaces; delete this declaration."
            ),
            (
                Self.schema.replacingOccurrences(of: "-> Change<Loading, Effect.Begin>", with: "-> Loading"),
                "This transition starts Fetch; return Change<Loading, Effect.Begin>."
            ),
            (
                Self.schema.replacingOccurrences(of: "Loading) -> Idle", with: "Loading) -> Change<Idle, Never>"),
                "This transition starts no operation; return Idle directly."
            ),
            (
                Self.schema.replacingOccurrences(of: "Effect.Begin", with: "Effect"),
                "This transition starts Fetch; name its effects Effect.Begin."
            ),
            (
                Self.schema.replacingOccurrences(of: "@Initial case idle", with: "case idle"),
                "Mark exactly one phase case with @Initial."
            ),
        ]
        for (source, message) in failures {
            do {
                _ = try Self.parse(source)
                Issue.record("Expected rejection: \(message)")
            } catch let error as DiagnosticsError {
                #expect(error.diagnostics.map(\.message) == [message])
            }
        }
    }

    @Test func schemaWithoutScopesNeedsNoScopeEnum() throws {
        let source = Self.schema.replacingOccurrences(of: "enum Scope { case load }\n", with: "")
        #expect(throws: DiagnosticsError.self) { try Self.parse(source) }
        let scopeless = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Done {}
                @Initial case idle(Idle)
                case done(Done)
                enum Input { case finish }
                @Transition(on: Input.finish)
                static func finish(_ source: Flow.Idle) -> Self.Done { fatalError() }
            }
            """#
        let result = try Self.parse(scopeless)
        #expect(result.scopes.isEmpty)
        #expect(result.transitions.first?.from == "idle")
        #expect(result.transitions.first?.to == "done")
    }

    @Test func acceptsPositiveBoundedAdmission() throws {
        let result = try Self.parse(Self.schema.replacingOccurrences(of: ".latest", with: ".parallel(limit: 2)"))
        #expect(result.operations.first?.admission == .parallel(limit: 2))
    }

    @Test func payloadFieldsMayUseGenericContainers() throws {
        let source = Self.schema.replacingOccurrences(
            of: "struct Idle {}",
            with: "struct Idle { var values: [String: Result<Int, MyError>] }"
        )
        let result = try Self.parse(source)
        #expect(result.phases.first?.typeName == "Idle")
    }

    @Test func extractsOwnedFailureWithoutRequiringCopyablePayloads() throws {
        let source = #"""
            @StateMachine(mode: .ownedOnly)
            enum Resource {
                struct Idle: ~Copyable {}
                struct Finished: ~Copyable {}
                @Initial case idle(Idle)
                case finished(Finished)
                enum Input { case finish }
                @Transition(on: Input.finish)
                static func finish(_ source: consuming Idle) -> Advance<Idle, Finished, Never, MyFailure> { fatalError() }
            }
            """#
        let result = try Self.parse(source)
        #expect(result.mode == .ownedOnly)
        #expect(result.transitions.first?.from == "idle")
        #expect(result.transitions.first?.to == "finished")
        #expect(result.transitions.first?.failureType == "MyFailure")
    }

    @Test func multipleEdgesRequireExactlyOneRouter() throws {
        let secondEdge = #"""
            @Transition(on: Input.start)
            static func alternate(_ source: Idle, _ input: Int) -> Loading { fatalError() }
            """#
        let ambiguous = Self.schema.replacingOccurrences(of: "struct Idle {}", with: "struct Idle {}\n" + secondEdge)
        #expect(throws: DiagnosticsError.self) { try Self.parse(ambiguous) }
        let router = #"""
            @Route(on: Input.start)
            static func choose(_ source: Idle, _ input: Int) -> Route.Choose { fatalError() }
            """#
        let routed = ambiguous.replacingOccurrences(of: "struct Idle {}", with: "struct Idle {}\n" + router)
        let result = try Self.parse(routed)
        #expect(result.routes.count == 1)
        #expect(result.routes.first?.from == "idle")
        #expect(result.routes.first?.namespace == "Choose")
        #expect(result.routes.first?.choices == ["alternate", "begin"])
        #expect(result.transitions.count == 4)
        let duplicate = routed.replacingOccurrences(
            of: "struct Idle {}",
            with: "struct Idle {}\n" + router.replacingOccurrences(of: "choose", with: "chooseAgain")
        )
        #expect(throws: DiagnosticsError.self) { try Self.parse(duplicate) }
    }

    @Test func rejectsRedundantOrUndeclaredDependencies() {
        for dependency in ["load", "absent"] {
            let source = Self.schema.replacingOccurrences(
                of: "scope: Scope.load,",
                with: "scope: Scope.load, requires: [Scope.\(dependency)],"
            )
            #expect(throws: DiagnosticsError.self) { try Self.parse(source) }
        }
    }

    @Test func routerMayExplicitlyRejectAnOutcomeWithoutMatchingEdges() throws {
        let source = Self.schema.replacingOccurrences(
            of:
                "@Transition(onSuccess: Fetch.self)\n    static func received(_ source: borrowing Loading, _ input: Fetch.Output) -> Idle { fatalError() }",
            with:
                "@Route(onSuccess: Fetch.self)\n    static func reject(_ source: Loading, _ output: Fetch.Output) throws(MyError) -> Never { fatalError() }"
        )
        let result = try Self.parse(source)
        #expect(result.routes.count == 1)
        #expect(result.transitions.count == 2)
        #expect(result.routes.first?.trigger.kind == .success)
        #expect(result.routes.first?.namespace == nil)
        #expect(result.routes.first?.failureType == "MyError")
    }

    @Test func reservesAllGeneratedSupportNames() {
        for name in [
            "Host", "owned", "ExecutionHandle", "CommandBatch", "PendingCompletion", "_StateMachineEngine",
            "_stateMachinePrepare",
            "FetchWork", "_OperationFailureIsError", "_EffectIsCopyable", "_stateMachineEligibility",
            "Phase", "RuntimeState",
        ] {
            let source = Self.schema.replacingOccurrences(
                of: "struct Idle {}",
                with: "struct Idle {}\nstruct \(name) {}"
            )
            #expect(throws: DiagnosticsError.self) { try Self.parse(source) }
        }
    }

    @Test func diagnosesReservedHostSchemaAndInitialPhasePayload() throws {
        let failures: [(String, String)] = [
            (
                Self.schema.replacingOccurrences(of: "enum Flow", with: "enum Host"),
                "The schema name is reserved or shadowed by a direct member; choose a distinct domain name."
            ),
            (
                Self.schema.replacingOccurrences(of: "Idle", with: "Host"),
                "'Host' is reserved for generated members; rename the authored declaration."
            ),
        ]
        for (source, message) in failures {
            do {
                _ = try Self.parse(source)
                Issue.record("Expected rejection: \(message)")
            } catch let error as DiagnosticsError {
                #expect(error.diagnostics.map(\.message) == [message])
            }
        }
    }

    @Test func ownershipSyntaxAllowsCommentsAndLeavesTypeIdentityToCompilerWitnesses() throws {
        let source = Self.schema.replacingOccurrences(
            of: "borrowing Idle",
            with: "borrowing /* explicit ownership */ Self.Idle"
        )
        let result = try Self.parse(source)
        #expect(result.transitions.first?.name == "begin")
    }

    @Test func diagnosesTransitionWrapperMemberCollisions() {
        let source = Self.schema.replacingOccurrences(of: "func begin(", with: "func revision(")
        #expect(throws: DiagnosticsError.self) { try Self.parse(source) }
    }

    @Test func diagnosesSnapshotCaseMemberCollisions() {
        let source = Self.schema.replacingOccurrences(of: "case idle(Idle)", with: "case revision(Idle)")
        #expect(throws: DiagnosticsError.self) { try Self.parse(source) }
    }

    @Test func unlabeledCasesMayNameTheirPayloadInternally() throws {
        let source = Self.schema.replacingOccurrences(of: "case idle(Idle)", with: "case idle(_ value: Idle)")
            .replacingOccurrences(of: "case start(Int)", with: "case start(_ value: Int)")
        let parsed = try Self.parse(source)
        #expect(parsed.phases.first?.typeName == "Idle")
        #expect(parsed.inputs.first?.payloadType == "Int")
    }

    @Test func effectCasesLowerTheLeadingCapitalRunOfTheOperationName() throws {
        for (operation, effect) in [("URLLoad", "urlLoad"), ("A", "a"), ("SecondOperation", "secondOperation")] {
            let source = Self.schema.replacingOccurrences(of: "Fetch", with: operation)
            #expect(try Self.parse(source).operations.first?.effect == effect)
        }
    }

    @Test func ownedOnlyAcceptsPlainChangeAndAdvanceResults() throws {
        let source = #"""
            @StateMachine(mode: .ownedOnly)
            enum Resource {
                struct Idle: ~Copyable {}
                struct Finished: ~Copyable {}
                @Initial case idle(Idle)
                case finished(Finished)
                enum Scope { case work }
                enum Input { case finish, log, check }
                @Operation(scope: Scope.work, activeIn: [Finished.self], admission: .latest)
                enum Audit { typealias Input = Int; typealias Output = Int; typealias Failure = Never }
                @Transition(on: Input.finish)
                static func finish(_ source: consuming Idle) -> Finished { fatalError() }
                @Transition(on: Input.log, starts: [Audit.self])
                static func log(_ source: consuming Idle) -> Change<Finished, Effect.Log> { fatalError() }
                @Transition(on: Input.check, starts: [Audit.self])
                static func check(_ source: consuming Idle) -> Advance<Idle, Finished, Effect.Check, MyFailure> { fatalError() }
                @Transition(onSuccess: Audit.self)
                static func audited(_ source: consuming Finished, _ output: Audit.Output) -> Finished { fatalError() }
            }
            """#
        let result = try Self.parse(source)
        #expect(result.transitions.map(\.effectNamespace) == [nil, "Log", "Check", nil])
        #expect(result.transitions.map(\.failureType) == [nil, nil, "MyFailure", nil])
        let throwing = source.replacingOccurrences(
            of: "Idle) -> Finished {",
            with: "Idle) throws(MyFailure) -> Finished {"
        )
        #expect(throws: DiagnosticsError.self) { try Self.parse(throwing) }
        let borrowed = source.replacingOccurrences(of: "consuming Idle) -> Finished", with: "Idle) -> Finished")
        #expect(throws: DiagnosticsError.self) { try Self.parse(borrowed) }
    }

    @Test func caseNamesFollowSwiftIdentifierGrammar() throws {
        let source = Self.schema.replacingOccurrences(of: "case idle(Idle)", with: "case начало(Idle)")
        #expect(try Self.parse(source).initial == "начало")
    }

}
