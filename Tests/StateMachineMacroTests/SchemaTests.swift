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
            enum Effect { case fetch(Fetch.Input) }
            @Operation(scope: Scope.load, activeIn: [Loading.self], admission: .latest)
            enum Fetch { typealias Input = Int; typealias Output = String; typealias Failure = Never }
            @Transition(on: Input.start, starts: [Fetch.self])
            static func begin(_ source: borrowing Idle, _ input: Int) throws(MyError) -> Change<Loading, Effect> { fatalError() }
            @Transition(on: Input.cancel, invalidates: [Scope.load])
            static func cancel(_ source: borrowing Loading) -> Change<Idle, Effect> { fatalError() }
            @Transition(onSuccess: Fetch.self)
            static func received(_ source: borrowing Loading, _ input: Fetch.Output) -> Change<Idle, Effect> { fatalError() }
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
        #expect(result.transitions.map(\.trigger.kind) == ["input", "input", "success"])
        #expect(result.transitions.map(\.trigger.name) == ["start", "cancel", "fetch"])
        #expect(result.transitions.first?.starts == ["fetch"])
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
            ("effect without payload", schema.replacingOccurrences(of: "case fetch(Fetch.Input)", with: "case fetch")),
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
                    of: "throws(MyError) -> Change<Loading, Effect>",
                    with: "-> Change<Missing, Effect>"
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
            ("missing borrow", schema.replacingOccurrences(of: "borrowing Idle", with: "Idle")),
            ("reused phase", schema.replacingOccurrences(of: "case loading(Loading)", with: "case loading(Idle)")),
            ("malformed admission", schema.replacingOccurrences(of: ".latest", with: ".parallel(limit: 0)")),
            ("unknown trigger", schema.replacingOccurrences(of: "on: Input.start", with: "on: Input.absent")),
            (
                "missing completion route",
                schema.replacingOccurrences(
                    of:
                        "@Transition(onSuccess: Fetch.self)\n    static func received(_ source: borrowing Loading, _ input: Fetch.Output) -> Change<Idle, Effect> { fatalError() }",
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
                Self.schema.replacingOccurrences(of: "Change<Loading, Effect>", with: "Change<Missing, Effect>"),
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
                Self.schema.replacingOccurrences(of: "case fetch(Fetch.Input)", with: "case fetch(Int)"),
                "Exactly one Effect case must request this operation by carrying Fetch.Input."
            ),
            (
                Self.schema.replacingOccurrences(
                    of: "case fetch(Fetch.Input)",
                    with: "case fetch(Fetch.Input); case again(Fetch.Input)"
                ),
                "Exactly one Effect case must request this operation by carrying Fetch.Input."
            ),
            (
                Self.schema.replacingOccurrences(
                    of: "case fetch(Fetch.Input)",
                    with: "case fetch(Fetch.Input); case stray(Int)"
                ),
                "Effect case 'stray' must request an @Operation namespace by carrying its Input alias, such as Fetch.Input."
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
                enum Effect {}
                @Transition(on: Input.finish)
                static func finish(_ source: borrowing Flow.Idle) -> Change<Self.Done, Effect> { fatalError() }
            }
            """#
        let result = try Self.parse(scopeless)
        #expect(result.scopes.isEmpty)
        #expect(result.transitions.first?.from == "idle")
        #expect(result.transitions.first?.to == "done")
    }

    @Test func acceptsPositiveBoundedAdmission() throws {
        let result = try Self.parse(Self.schema.replacingOccurrences(of: ".latest", with: ".parallel(limit: 2)"))
        #expect(result.operations.first?.admission == ".parallel(limit: 2)")
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
                enum Effect {}
                @Transition(on: Input.finish)
                static func finish(_ source: consuming Idle) -> Advance<Idle, Finished, Effect, MyFailure> { fatalError() }
            }
            """#
        let result = try Self.parse(source)
        #expect(result.mode == "ownedOnly")
        #expect(result.transitions.first?.from == "idle")
        #expect(result.transitions.first?.to == "finished")
        #expect(result.transitions.first?.failureType == "MyFailure")
    }

    @Test func multipleEdgesRequireExactlyOneRouter() throws {
        let secondEdge = #"""
            @Transition(on: Input.start)
            static func alternate(_ source: borrowing Idle, _ input: Int) -> Change<Loading, Effect> { fatalError() }
            """#
        let ambiguous = Self.schema.replacingOccurrences(of: "struct Idle {}", with: "struct Idle {}\n" + secondEdge)
        #expect(throws: DiagnosticsError.self) { try Self.parse(ambiguous) }
        let router = #"""
            @Route(on: Input.start)
            static func choose(_ source: Observed<Idle>, _ input: Int) -> PreparationResult { fatalError() }
            """#
        let routed = ambiguous.replacingOccurrences(of: "struct Idle {}", with: "struct Idle {}\n" + router)
        let result = try Self.parse(routed)
        #expect(result.routes.count == 1)
        #expect(result.routes.first?.from == "idle")
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
                "@Transition(onSuccess: Fetch.self)\n    static func received(_ source: borrowing Loading, _ input: Fetch.Output) -> Change<Idle, Effect> { fatalError() }",
            with:
                "@Route(onSuccess: Fetch.self)\n    static func reject(_ source: Observed<Loading>, _ completion: FetchSuccessCompletion) -> PreparationResult { fatalError() }"
        )
        let result = try Self.parse(source)
        #expect(result.routes.count == 1)
        #expect(result.transitions.count == 2)
        #expect(result.routes.first?.trigger.kind == "success")
    }

    @Test func reservesAllGeneratedSupportNames() {
        for name in [
            "Host", "owned", "ExecutionHandle", "CommandBatch", "PendingCompletion", "_AtomicEngine", "_atomicPrepare",
            "FetchWork", "_AtomicErrorWitness", "_AtomicCopyableWitness", "_atomicEligibility", "Phase", "RuntimeState",
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
        let source = Self.schema.replacingOccurrences(of: "func begin(", with: "func ordinal(")
        #expect(throws: DiagnosticsError.self) { try Self.parse(source) }
    }

    @Test func diagnosesSnapshotCaseMemberCollisions() {
        let source = Self.schema.replacingOccurrences(of: "case idle(Idle)", with: "case ordinal(Idle)")
        #expect(throws: DiagnosticsError.self) { try Self.parse(source) }
    }

    @Test func unlabeledCasesMayNameTheirPayloadInternally() throws {
        let source = Self.schema.replacingOccurrences(of: "case idle(Idle)", with: "case idle(_ value: Idle)")
            .replacingOccurrences(of: "case start(Int)", with: "case start(_ value: Int)")
            .replacingOccurrences(of: "case fetch(Fetch.Input)", with: "case fetch(_ request: Fetch.Input)")
        let parsed = try Self.parse(source)
        #expect(parsed.phases.first?.typeName == "Idle")
        #expect(parsed.inputs.first?.payloadType == "Int")
    }

    @Test func caseNamesFollowSwiftIdentifierGrammar() throws {
        let source = Self.schema.replacingOccurrences(of: "case idle(Idle)", with: "case начало(Idle)")
        #expect(try Self.parse(source).initial == "начало")
    }

}
