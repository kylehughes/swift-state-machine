import Foundation
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

struct SchemaTests {
    static let schema = #"""
        @StateMachine(mode: .shared, initial: "idle", scopes: ["load"])
        enum Flow {
            struct Idle {}
            struct Loading {}
            case idle(Idle)
            case loading(Loading)
            enum Input { case start(Int); case cancel }
            enum Effect { case fetch(Fetch.Input) }
            @Operation(effect: "fetch", scope: "load", activeIn: ["loading"], admission: .latest)
            enum Fetch { typealias Input = Int; typealias Output = String; typealias Failure = Never }
            @Transition(from: "idle", to: "loading", on: .input("start"), starts: ["fetch"])
            static func begin(_ source: borrowing Idle, _ input: Int) throws(MyError) -> Change<Loading, Effect> { fatalError() }
            @Transition(from: "loading", to: "idle", on: .input("cancel"), invalidates: ["load"])
            static func cancel(_ source: borrowing Loading) -> Change<Idle, Effect> { fatalError() }
            @Transition(from: "loading", to: "idle", on: .success("fetch"))
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
        #expect(result.transitions.count == 3)
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
                schema.replacingOccurrences(of: "invalidates: [\"load\"]", with: "invalidates: [\"absent\"]")
            ),
            (
                "unsupported marker placement",
                schema.replacingOccurrences(
                    of: "struct Idle {}",
                    with:
                        "@Operation(effect: \"fetch\", scope: \"load\", activeIn: [\"loading\"], admission: .latest) struct Idle {}"
                )
            ),
            ("invalid initial", schema.replacingOccurrences(of: "initial: \"idle\"", with: "initial: \"missing\"")),
            (
                "duplicate scopes",
                schema.replacingOccurrences(of: "scopes: [\"load\"]", with: "scopes: [\"load\", \"load\"]")
            ),
            ("computed metadata", schema.replacingOccurrences(of: "initial: \"idle\"", with: "initial: initialPhase")),
            ("unknown starts", schema.replacingOccurrences(of: "starts: [\"fetch\"]", with: "starts: [\"missing\"]")),
            (
                "ineligible starts",
                schema.replacingOccurrences(of: "activeIn: [\"loading\"]", with: "activeIn: [\"idle\"]")
            ),
            ("untyped throws", schema.replacingOccurrences(of: "throws(MyError)", with: "throws")),
            ("async transition", schema.replacingOccurrences(of: "throws(MyError)", with: "async throws(MyError)")),
            ("missing borrow", schema.replacingOccurrences(of: "borrowing Idle", with: "Idle")),
            ("reused phase", schema.replacingOccurrences(of: "case loading(Loading)", with: "case loading(Idle)")),
            ("malformed admission", schema.replacingOccurrences(of: ".latest", with: ".parallel(limit: 0)")),
            ("unknown trigger", schema.replacingOccurrences(of: ".input(\"start\")", with: ".input(\"absent\")")),
            (
                "missing completion route",
                schema.replacingOccurrences(of: ".success(\"fetch\")", with: ".input(\"cancel\")")
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
            @StateMachine(mode: .ownedOnly, initial: "idle", scopes: [])
            enum Resource {
                struct Idle: ~Copyable {}
                struct Finished: ~Copyable {}
                case idle(Idle)
                case finished(Finished)
                enum Input { case finish }
                enum Effect {}
                @Transition(from: "idle", to: "finished", on: .input("finish"))
                static func finish(_ source: consuming Idle) -> Advance<Idle, Finished, Effect, MyFailure> { fatalError() }
            }
            """#
        let result = try Self.parse(source)
        #expect(result.mode == "ownedOnly")
        #expect(result.transitions.first?.failureType == "MyFailure")
    }

    @Test func multipleEdgesRequireExactlyOneRouter() throws {
        let secondEdge = #"""
            @Transition(from: "idle", to: "loading", on: .input("start"))
            static func alternate(_ source: borrowing Idle, _ input: Int) -> Change<Loading, Effect> { fatalError() }
            """#
        let ambiguous = Self.schema.replacingOccurrences(of: "struct Idle {}", with: "struct Idle {}\n" + secondEdge)
        #expect(throws: DiagnosticsError.self) { try Self.parse(ambiguous) }
        let router = #"""
            @Route(from: "idle", on: .input("start"))
            static func choose(_ source: Observed<Idle>, _ input: Int) -> PreparationResult { fatalError() }
            """#
        let routed = ambiguous.replacingOccurrences(of: "struct Idle {}", with: "struct Idle {}\n" + router)
        let result = try Self.parse(routed)
        #expect(result.routes.count == 1)
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
                of: "scope: \"load\",",
                with: "scope: \"load\", requires: [\"\(dependency)\"],"
            )
            #expect(throws: DiagnosticsError.self) { try Self.parse(source) }
        }
    }

    @Test func routerMayExplicitlyRejectAnOutcomeWithoutMatchingEdges() throws {
        let source = Self.schema.replacingOccurrences(
            of:
                "@Transition(from: \"loading\", to: \"idle\", on: .success(\"fetch\"))\n    static func received(_ source: borrowing Loading, _ input: Fetch.Output) -> Change<Idle, Effect> { fatalError() }",
            with:
                "@Route(from: \"loading\", on: .success(\"fetch\"))\n    static func reject(_ source: Observed<Loading>, _ completion: FetchSuccessCompletion) -> PreparationResult { fatalError() }"
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
        let source = Self.schema.replacingOccurrences(of: "\"idle\"", with: "\"ordinal\"")
            .replacingOccurrences(of: "case idle(Idle)", with: "case ordinal(Idle)")
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

    @Test func literalNamesFollowSwiftIdentifierGrammar() throws {
        let source = Self.schema.replacingOccurrences(of: "\"idle\"", with: "\"начало\"")
            .replacingOccurrences(of: "case idle(Idle)", with: "case начало(Idle)")
        #expect(try Self.parse(source).initial == "начало")
    }

}
