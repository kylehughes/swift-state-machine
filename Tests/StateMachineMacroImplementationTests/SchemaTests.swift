import Foundation
import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
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
            enum Scope { @Active(in: [Loading.self]) case load }
            enum Input { case start(Int); case cancel }
            @Operation(scope: Scope.load, admission: .latest)
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
        return try Schema.parse(declaration, attribute: attribute)
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

    @Test func acceptsEscapedKeywordArgumentLabel() throws {
        let escaped = Self.schema.replacingOccurrences(of: "@Active(in:", with: "@Active(`in`:")
        let result = try Self.parse(escaped)
        #expect(result.scopes == ["load"])
        #expect(result.operations.first?.activeIn == ["loading"])
    }

    @Test func acceptsModuleQualifiedMarkersAndRuntimeTypes() throws {
        let qualified = Self.schema
            .replacingOccurrences(of: "@StateMachine(mode:", with: "@StateMachine.StateMachine(mode:")
            .replacingOccurrences(of: "@Initial", with: "@StateMachine.Initial")
            .replacingOccurrences(of: "@Operation(", with: "@StateMachine.Operation(")
            .replacingOccurrences(of: "@Transition(", with: "@StateMachine.Transition(")
            .replacingOccurrences(of: "-> Change<Loading", with: "-> StateMachine.Change<Loading")
        let result = try Self.parse(qualified)
        #expect(result.initial == "idle")
        #expect(result.operations.map(\.effect) == ["fetch"])
        #expect(result.transitions.map(\.name) == ["begin", "cancel", "received"])
        #expect(result.transitions.first?.effectNamespace == "Begin")
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
                        "@Operation(scope: Scope.load, admission: .latest) struct Idle {}"
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
                schema.replacingOccurrences(
                    of: "enum Scope { @Active(in: [Loading.self]) case load }",
                    with: "enum Scope { case load(Int) }"
                )
            ),
            (
                "duplicate scopes",
                schema.replacingOccurrences(
                    of: "enum Scope { @Active(in: [Loading.self]) case load }",
                    with: "enum Scope { case load, load }"
                )
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
                schema.replacingOccurrences(of: "@Active(in: [Loading.self])", with: "@Active(in: [Idle.self])")
            ),
            (
                "operation as active phase",
                schema.replacingOccurrences(of: "@Active(in: [Loading.self])", with: "@Active(in: [Fetch.self])")
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
                .replacingOccurrences(of: "typealias Output = String", with: "typealias Output = Swift::String")
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
                Self.schema.replacingOccurrences(of: "@Active(in:", with: "@Active(`in`: [], in:"),
                "Specify 'in' only once."
            ),
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
                "This transition starts no operation, cancels no work, and emits no event; return Idle directly."
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
        let source = Self.schema.replacingOccurrences(
            of: "enum Scope { @Active(in: [Loading.self]) case load }\n",
            with: ""
        )
        #expect(throws: DiagnosticsError.self) { try Self.parse(source) }
        let scopeless = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Done {}
                @Initial case idle(Idle)
                @Terminal case done(Done)
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
                @Terminal case finished(Finished)
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

    @Test func diagnosesRouterNamesThatTheirGeneratedMethodsWouldShadow() throws {
        let edges = #"""
            @Transition(on: Input.start)
            static func alternate(_ source: Idle, _ input: Int) -> Loading { fatalError() }
            @Route(on: Input.start)
            static func choose(_ source: Idle, _ input: Int) throws(MyError) -> Route.Choose { fatalError() }
            """#
        let routed = Self.schema.replacingOccurrences(of: "struct Idle {}", with: "struct Idle {}\n" + edges)
        _ = try Self.parse(routed)
        // A router that takes a payload generates `revision(_:)`, which a `revision` property does not redeclare.
        _ = try Self.parse(
            routed.replacingOccurrences(of: "func choose(", with: "func revision(")
                .replacingOccurrences(of: "Route.Choose", with: "Route.Revision")
        )
        let bare = Self.schema.replacingOccurrences(
            of: "struct Idle {}",
            with: """
                struct Idle {}
                @Transition(on: Input.cancel)
                static func stay(_ source: Loading) -> Loading { fatalError() }
                @Route(on: Input.cancel)
                static func revision(_ source: Loading) -> Route.Revision { fatalError() }
                """
        )
        let failures: [(String, String)] = [
            (
                bare,
                "Router 'revision' would generate the Observed method revision(), which redeclares Observed's revision property; rename the router."
            ),
            (
                routed.replacingOccurrences(of: "func choose(", with: "func invalidPhase(")
                    .replacingOccurrences(of: "Route.Choose", with: "Route.InvalidPhase"),
                "'invalidPhase' is already a PreparationRejection case; rename this throwing router."
            ),
            (
                routed.replacingOccurrences(of: "func alternate(", with: "func rejected("),
                "A throwing router cannot choose an edge named 'rejected', which its owned result uses; rename the edge."
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

    @Test func diagnosesARouterResultNameAnotherRouterUses() throws {
        let edges = #"""
            @Transition(on: Input.start)
            static func alternate(_ source: Idle, _ input: Int) -> Loading { fatalError() }
            @Route(on: Input.start)
            static func pick(_ source: Idle, _ input: Int) -> Route.Pick { fatalError() }
            @Transition(on: Input.cancel)
            static func stay(_ source: Loading) -> Loading { fatalError() }
            @Route(on: Input.cancel)
            static func pickResult(_ source: Loading) -> Route.PickResult { fatalError() }
            """#
        let source = Self.schema.replacingOccurrences(of: "struct Idle {}", with: "struct Idle {}\n" + edges)
        do {
            _ = try Self.parse(source)
            Issue.record("Expected a Route.PickResult collision")
        } catch let error as DiagnosticsError {
            #expect(
                error.diagnostics.map(\.message) == [
                    "Router 'pickResult' would generate Route.PickResult, which router 'pick' also generates; rename one."
                ]
            )
        }
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
        // `Loading` refuses every success, which stays pending until `Paused`, where the work is still
        // active, accepts it; the failure is accepted in `Loading`.
        let source = Self.schema
            .replacingOccurrences(of: "struct Loading {}", with: "struct Loading {}\n    struct Paused {}")
            .replacingOccurrences(of: "case loading(Loading)", with: "case loading(Loading)\n    case paused(Paused)")
            .replacingOccurrences(of: "@Active(in: [Loading.self])", with: "@Active(in: [Loading.self, Paused.self])")
            .replacingOccurrences(of: "case cancel }", with: "case cancel; case pause }")
            .replacingOccurrences(
                of:
                    "@Transition(onSuccess: Fetch.self)\n    static func received(_ source: borrowing Loading, _ input: Fetch.Output) -> Idle { fatalError() }",
                with: """
                    @Route(onSuccess: Fetch.self)
                        static func reject(_ source: Loading, _ output: Fetch.Output) throws(MyError) -> Never { fatalError() }
                        @Transition(onFailure: Fetch.self)
                        static func failed(_ source: Loading, _ failure: Fetch.Failure) -> Idle { fatalError() }
                        @Transition(on: Input.pause)
                        static func pause(_ source: Loading) -> Paused { fatalError() }
                        @Transition(onSuccess: Fetch.self)
                        static func received(_ source: Paused, _ output: Fetch.Output) -> Idle { fatalError() }
                        @Transition(onFailure: Fetch.self)
                        static func failed(_ source: Paused, _ failure: Fetch.Failure) -> Idle { fatalError() }
                    """
            )
            .replacingOccurrences(of: "typealias Failure = Never", with: "typealias Failure = MyError")
        let result = try Self.parse(source)
        #expect(result.routes.count == 1)
        #expect(result.transitions.count == 6)
        #expect(result.routes.first?.trigger.kind == .success)
        #expect(result.routes.first?.namespace == nil)
        #expect(result.routes.first?.failureType == "MyError")
    }

    @Test func reservesAllGeneratedSupportNames() {
        for name in [
            "Host", "owned", "ExecutionHandle", "CommandBatch", "PendingCompletion", "_StateMachineEngine",
            "_stateMachinePrepare",
            "FetchWork", "_OperationFailureIsError", "_EffectIsCopyable", "_stateMachineEligibility",
            "Phase", "_StateMachineScopeID", "Change",
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
            (
                Self.schema.replacingOccurrences(
                    of: "struct Loading {}",
                    with: "struct Loading {}\nstruct FlushResult {}"
                ),
                "'FlushResult' is reserved for generated members; rename the authored declaration."
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

    /// Generated code names modules through selectors, so a schema may take a module's name.
    @Test func aSchemaMayTakeAModuleName() throws {
        for name in ["Swift", "StateMachine"] {
            _ = try Self.parse(Self.schema.replacingOccurrences(of: "enum Flow", with: "enum \(name)"))
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

    /// An edge collides with a wrapper member only when its generated method has the member's full name.
    @Test func diagnosesTransitionWrapperMemberCollisionsBySignature() throws {
        // `begin` takes a payload, so its methods are `revision(_:)`.
        _ = try Self.parse(
            Self.schema.replacingOccurrences(of: "func begin(", with: "func revision(")
                .replacingOccurrences(of: "Effect.Begin", with: "Effect.Revision")
        )
        // `cancel` takes none, so its `Observed` method would be `revision()`.
        let bare = Self.schema.replacingOccurrences(of: "func cancel(", with: "func revision(")
        #expect(
            DeclarationHygieneTests.diagnostics(bare) == [
                "Transition 'revision' would generate the Observed method revision(), which redeclares Observed's revision property; rename the transition."
            ]
        )
        // Without an observing owner, no `Observed` method exists to collide.
        #expect(
            DeclarationHygieneTests.diagnostics(
                bare.replacingOccurrences(of: "mode: .shared", with: "mode: .shared, owners: [.owned]")
            ) == nil
        )
    }

    @Test func phaseCasesMayShareSnapshotMemberNames() throws {
        for name in ["record", "model", "revision", "isClosed", "description"] {
            _ = try Self.parse(Self.schema.replacingOccurrences(of: "case idle(Idle)", with: "case \(name)(Idle)"))
        }
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
                enum Scope { @Active(in: [Finished.self]) case work }
                enum Input { case finish, log, check }
                @Operation(scope: Scope.work, admission: .latest)
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

    static let restorable = schema.replacingOccurrences(
        of: "struct Idle {}",
        with:
            "struct Idle {}\n    @Restoration\n    static func restore(_ saved: Int) throws(MyError) -> Restoration { fatalError() }"
    )

    @Test func restorationCoversOnlyPhasesWithoutActiveOperations() throws {
        let result = try Self.parse(Self.restorable)
        #expect(result.restingPhases.map(\.caseName) == ["idle"])
        #expect(result.restoration?.name == "restore")
        #expect(result.restoration?.archiveType == "Int")
        #expect(result.restoration?.failureType == "MyError")
        let plain = try Self.parse(Self.schema)
        #expect(plain.restoration == nil)
        #expect(plain.restingPhases.map(\.caseName) == ["idle"])
        let qualified = try Self.parse(
            Self.restorable.replacingOccurrences(
                of: "(_ saved: Int) throws(MyError) -> Restoration",
                with: "(_ saved: Self.Archive) throws(Self.Problem) -> Self.Restoration"
            )
        )
        #expect(qualified.restoration?.archiveType == "Flow.Archive")
        #expect(qualified.restoration?.failureType == "Flow.Problem")
        let infallible = try Self.parse(Self.restorable.replacingOccurrences(of: " throws(MyError) ->", with: " ->"))
        #expect(infallible.restoration?.failureType == nil)
    }

    @Test func diagnosesMalformedRestoration() throws {
        let validator = "static func restore(_ saved: Int) throws(MyError) -> Restoration"
        let owned = #"""
            @StateMachine(mode: .ownedOnly)
            enum Resource {
                struct Idle: ~Copyable {}
                @Initial case idle(Idle)
                enum Input {}
                @Restoration
                static func restore(_ saved: Int) -> Restoration { fatalError() }
            }
            """#
        let failures: [(String, String)] = [
            (
                Self.restorable.replacingOccurrences(
                    of: "struct Loading {}",
                    with:
                        "struct Loading {}\n    @Restoration\n    static func again(_ saved: Int) -> Restoration { fatalError() }"
                ),
                "Declare at most one @Restoration function in a schema."
            ),
            (owned, "@Restoration is unavailable in .ownedOnly, which generates no owner to restore."),
            (
                Self.restorable.replacingOccurrences(of: validator, with: "static func restore(_ saved: Int) -> Idle"),
                "A @Restoration function returns Restoration, the phase to restore."
            ),
            (
                Self.restorable.replacingOccurrences(
                    of: validator,
                    with: "static func restore(_ saved: Int, _ other: Int) -> Restoration"
                ),
                "A @Restoration function takes exactly one unlabeled parameter: the saved data it validates."
            ),
            (
                Self.restorable.replacingOccurrences(of: validator, with: "static func restore() -> Restoration"),
                "A @Restoration function takes exactly one unlabeled parameter: the saved data it validates."
            ),
            (
                Self.restorable.replacingOccurrences(
                    of: "throws(MyError) -> Restoration",
                    with: "throws -> Restoration"
                ),
                "Restoration functions must use typed throws(Failure), or omit throws."
            ),
            (
                Self.restorable.replacingOccurrences(of: validator, with: "func restore(_ saved: Int) -> Restoration"),
                "Use a synchronous nongeneric static function with unlabeled, nonvariadic parameters and no defaults."
            ),
            (
                Self.restorable.replacingOccurrences(of: "(_ saved: Int)", with: "(_ saved: inout Int)"),
                "Pass the saved data to a @Restoration function by value, not inout."
            ),
            (
                Self.restorable.replacingOccurrences(of: "@Restoration\n", with: "@Restoration(true)\n"),
                "Unexpected metadata argument; supported labels are allows, only."
            ),
            (
                Self.restorable.replacingOccurrences(
                    of: "@Restoration\n",
                    with: "@Restoration @Transition(on: Input.cancel)\n"
                ),
                "A @Restoration function cannot also be a transition or a router."
            ),
            (
                Self.schema.replacingOccurrences(of: "struct Loading {}", with: "@Restoration struct Loading {}"),
                "@Restoration must mark a static function declared directly inside the schema."
            ),
            (
                Self.schema.replacingOccurrences(of: "struct Idle {}", with: "struct Idle {}\nenum Restoration {}"),
                "'Restoration' is reserved for generated members; rename the authored declaration."
            ),
            (
                Self.schema.replacingOccurrences(of: "struct Idle {}", with: "struct Idle {}\nenum ShutdownResult {}"),
                "'ShutdownResult' is reserved for generated members; rename the authored declaration."
            ),
            (
                Self.schema.replacingOccurrences(
                    of: "struct Idle {}",
                    with: "struct Idle {}\nstruct ShutdownDiagnostics {}"
                ),
                "'ShutdownDiagnostics' is reserved for generated members; rename the authored declaration."
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

    @Test func restorationMayAllowPhasesInWhichAnOperationIsActive() throws {
        let allowed = try Self.parse(
            Self.restorable.replacingOccurrences(of: "@Restoration\n", with: "@Restoration(allows: [Loading.self])\n")
        )
        #expect(allowed.restoration?.allows == ["loading"])
        #expect(allowed.restingPhases.map(\.caseName) == ["idle"])
        #expect(allowed.restorablePhases.map(\.caseName) == ["idle", "loading"])
        let qualified = try Self.parse(
            Self.restorable.replacingOccurrences(
                of: "@Restoration\n",
                with: "@StateMachine.Restoration(allows: [])\n"
            )
        )
        #expect(qualified.restoration?.allows == [])
        #expect(qualified.restorablePhases.map(\.caseName) == ["idle"])
    }

    /// Listing a phase that is already restorable pins it, so it stays restorable once an operation
    /// becomes active there.
    @Test func restorationMayListAPhaseInWhichNoOperationIsActive() throws {
        func allowing(_ list: String) -> String {
            Self.restorable.replacingOccurrences(of: "@Restoration\n", with: "@Restoration(allows: \(list))\n")
        }
        let listed = try Self.parse(allowing("[Idle.self, Loading.self]"))
        #expect(listed.restoration?.allows == ["idle", "loading"])
        #expect(listed.restorablePhases.map(\.caseName) == ["idle", "loading"])
        // An operation that becomes active in the listed resting phase leaves it restorable.
        let pinned = try Self.parse(
            allowing("[Idle.self]")
                .replacingOccurrences(
                    of: "@Active(in: [Loading.self])",
                    with: "@Active(in: [Idle.self, Loading.self])"
                )
                .replacingOccurrences(
                    of: "@Transition(onSuccess: Fetch.self)",
                    with:
                        "@Transition(on: Input.cancel, starts: [Fetch.self])\n    static func again(_ source: Idle) -> Change<Idle, Effect.Again> { fatalError() }\n    @Transition(onSuccess: Fetch.self)\n    static func settled(_ source: Idle, _ input: Fetch.Output) -> Idle { fatalError() }\n    @Transition(onSuccess: Fetch.self)"
                )
        )
        #expect(pinned.restingPhases.isEmpty)
        #expect(pinned.restorablePhases.map(\.caseName) == ["idle"])
    }

    @Test func diagnosesMalformedRestorationAllowances() throws {
        func allowing(_ list: String) -> String {
            Self.restorable.replacingOccurrences(of: "@Restoration\n", with: "@Restoration(allows: \(list))\n")
        }
        let failures: [(String, String)] = [
            (allowing("[Fetch.self]"), "'Fetch' is not a phase payload type declared in this schema."),
            (allowing("[Loading.self, Loading.self]"), "Remove duplicate references from this metadata list."),
            (allowing("Loading.self"), "Use an array literal of <Type>.self references."),
            (
                Self.restorable.replacingOccurrences(
                    of: "@Restoration\n",
                    with: "@Restoration(phases: [Loading.self])\n"
                ),
                "Unexpected metadata argument; supported labels are allows, only."
            ),
            (
                Self.schema.replacingOccurrences(
                    of: "struct Loading {}",
                    with: "@Restoration(allows: [Loading.self]) struct Loading {}"
                ),
                "@Restoration must mark a static function declared directly inside the schema."
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

    @Test func operationsDefaultTheirScopeAdmissionAndFailure() throws {
        let source = Self.schema.replacingOccurrences(
            of:
                "@Operation(scope: Scope.load, admission: .latest)\n    enum Fetch { typealias Input = Int; typealias Output = String; typealias Failure = Never }",
            with:
                "@Operation(activeIn: [Loading.self])\n    enum Fetch { typealias Input = Int; typealias Output = String }"
        )
        let result = try Self.parse(source)
        let operation = try #require(result.operations.first)
        #expect(operation.scope == nil)
        #expect(operation.admission == .latest)
        #expect(operation.failureType == "Swift::Never")
        #expect(!operation.declaresFailure)
        #expect(operation.failure == "Swift::Never")
        #expect(operation.isInfallible)
        // The private scope follows every declared one and has a key no authored reference can spell.
        #expect(result.scopes == ["load"])
        #expect(result.scopeKeys == ["load", "Fetch.self"])
        let declared = try #require(try Self.parse(Self.schema).operations.first)
        #expect(declared.scope == "load")
        #expect(declared.declaresFailure)
        #expect(declared.failure == "Fetch.Failure")
        #expect(declared.isInfallible)
        let qualified = try #require(
            try Self.parse(Self.schema.replacingOccurrences(of: "Failure = Never", with: "Failure = Swift.Never"))
                .operations.first
        )
        #expect(qualified.isInfallible)
        let failureEdge =
            "struct Idle {}\n    @Transition(onFailure: Fetch.self)\n    static func failed(_ source: Loading, _ failure: Fetch.Failure) -> Idle { fatalError() }"
        let fallible = try #require(
            try Self.parse(
                Self.schema.replacingOccurrences(of: "Failure = Never", with: "Failure = MyError")
                    .replacingOccurrences(of: "struct Idle {}", with: failureEdge)
            )
            .operations.first
        )
        #expect(!fallible.isInfallible)
    }

    @Test func operationsWithoutScopesNeedNoScopeEnumAndMayDisagreeAboutActivePhases() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Loading {}
                @Initial case idle(Idle)
                case loading(Loading)
                enum Input { case start }
                @Operation(activeIn: [Loading.self])
                enum Fetch { typealias Input = Int; typealias Output = String }
                @Operation(activeIn: [Idle.self, Loading.self], admission: .parallel(limit: 2))
                enum Audit { typealias Input = Int; typealias Output = Int }
                @Transition(on: Input.start, starts: [Fetch.self, Audit.self])
                static func begin(_ source: Idle) -> Change<Loading, Effect.Begin> { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func received(_ source: Loading, _ output: Fetch.Output) -> Idle { fatalError() }
                @Transition(onSuccess: Audit.self)
                static func audited(_ source: Loading, _ output: Audit.Output) -> Loading { fatalError() }
                @Transition(onSuccess: Audit.self)
                static func checked(_ source: Idle, _ output: Audit.Output) -> Idle { fatalError() }
            }
            """#
        let result = try Self.parse(source)
        #expect(result.scopes.isEmpty)
        #expect(result.scopeKeys == ["Fetch.self", "Audit.self"])
        #expect(result.operations.map(\.admission) == [.latest, .parallel(limit: 2)])
        #expect(result.restingPhases.isEmpty)
    }

    @Test func diagnosesOperationMetadataAndAliases() throws {
        let metadata =
            "Operation metadata must reference declared Scope cases, require no scope twice or as its own primary scope, and name at least one active phase."
        let aliases =
            "An operation declares only nongeneric Input, Output, Failure, and Key typealiases, each at most once; an omitted Input or Output is Void, an omitted Failure is Never, and an omitted Key leaves the operation unkeyed."
        let failures: [(String, String)] = [
            (Self.schema.replacingOccurrences(of: "scope: Scope.load,", with: "scope: Scope.absent,"), metadata),
            (
                Self.schema.replacingOccurrences(
                    of: "scope: Scope.load,",
                    with: "requires: [Scope.absent], activeIn: [Loading.self],"
                ),
                metadata
            ),
            (Self.schema.replacingOccurrences(of: "scope: Scope.load,", with: "activeIn: [],"), metadata),
            (
                Self.schema.replacingOccurrences(of: "@Active(in: [Loading.self])", with: "@Active(in: [])"),
                "List at least one phase in @Active(in:)."
            ),
            (
                Self.schema.replacingOccurrences(of: "scope: Scope.load, admission:", with: "admission:"),
                "Name the phases in which operation 'Fetch' may run with activeIn:, or name the scope it holds with scope:."
            ),
            (
                Self.schema.replacingOccurrences(
                    of: "scope: Scope.load,",
                    with: "scope: Scope.load, activeIn: [Loading.self],"
                ),
                "Operation 'Fetch' runs in the phases of its scope's @Active(in:); remove activeIn:, or remove scope: to give the operation a private scope."
            ),
            (
                Self.schema.replacingOccurrences(of: " typealias Output = String;", with: " typealias Output<T> = T;"),
                aliases
            ),
            (
                Self.schema.replacingOccurrences(of: " typealias Output = String;", with: " typealias Input = Int;"),
                aliases
            ),
            (
                Self.schema.replacingOccurrences(of: "typealias Failure = Never", with: "typealias Input = Never"),
                aliases
            ),
            (
                Self.schema.replacingOccurrences(of: "typealias Failure = Never", with: "typealias Problem = Never"),
                aliases
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

    @Test func diagnosesAnEdgeNamedForTheOwnedPayloadExit() throws {
        // A method of the same full name would take the call meant for the payload exit.
        let source = Self.schema.replacingOccurrences(of: "func cancel(", with: "func takeValue(")
        do {
            _ = try Self.parse(source)
            Issue.record("Expected rejection of takeValue")
        } catch let error as DiagnosticsError {
            #expect(
                error.diagnostics.map(\.message) == [
                    "Transition 'takeValue' would generate the Owned method takeValue(), which shadows Owned's own takeValue() verb; rename the transition."
                ]
            )
        }
        // An edge that takes a payload generates `takeValue(_:)`, a different method.
        _ = try Self.parse(
            Self.schema.replacingOccurrences(of: "func begin(", with: "func takeValue(")
                .replacingOccurrences(of: "Effect.Begin", with: "Effect.TakeValue")
        )
    }

    @Test func initialCaseMayDeclareADefaultConstruction() throws {
        #expect(try Self.parse(Self.schema).initialDefault == nil)
        let helper = "struct Idle {}\n    static func makeIdle() -> Idle { Idle() }"
        let spellings: [(String, String)] = [
            ("Idle()", "_StateMachineSchema.Idle()"),
            (".init()", "_StateMachineSchema.Idle()"),
            ("Idle.init()", "_StateMachineSchema.Idle()"),
            ("Flow.Idle()", "_StateMachineSchema.Idle()"),
            ("Self.Idle()", "_StateMachineSchema.Idle()"),
            ("makeIdle()", "_StateMachineSchema.makeIdle()"),
            ("Flow.makeIdle()", "_StateMachineSchema.makeIdle()"),
            ("Self.makeIdle()", "_StateMachineSchema.makeIdle()"),
        ]
        for (written, generated) in spellings {
            let source = Self.schema.replacingOccurrences(of: "struct Idle {}", with: helper)
                .replacingOccurrences(of: "@Initial case idle(Idle)", with: "@Initial case idle(Idle = \(written))")
            let result = try Self.parse(source)
            #expect(result.initialDefault == generated, "\(written)")
            #expect(result.phases.first?.typeName == "Idle")
        }
        let unlabeled = Self.schema.replacingOccurrences(
            of: "@Initial case idle(Idle)",
            with: "@Initial case idle(_ value: Idle = Idle())"
        )
        #expect(try Self.parse(unlabeled).initialDefault == "_StateMachineSchema.Idle()")
        // A case that qualifies its payload names the same phase, which the construction names once.
        for payload in ["Flow.Idle", "Self.Idle", "`Idle`"] {
            for written in ["Idle()", ".init()", "\(payload)()", "\(payload).init()", "Flow.makeIdle()"] {
                let source = Self.schema.replacingOccurrences(of: "struct Idle {}", with: helper)
                    .replacingOccurrences(
                        of: "@Initial case idle(Idle)",
                        with: "@Initial case idle(\(payload) = \(written))"
                    )
                let generated =
                    written.contains("makeIdle") ? "_StateMachineSchema.makeIdle()" : "_StateMachineSchema.Idle()"
                #expect(try Self.parse(source).initialDefault == generated, "\(payload) = \(written)")
            }
        }
    }

    @Test func ownedOnlyInitialCaseMayDeclareADefaultConstruction() throws {
        let source = #"""
            @StateMachine(mode: .ownedOnly)
            enum Resource {
                struct Idle: ~Copyable {}
                @Initial @Terminal case idle(Idle = Idle())
                enum Input {}
            }
            """#
        #expect(try Self.parse(source).initialDefault == "_StateMachineSchema.Idle()")
    }

    @Test func diagnosesAnInitialDefaultThatIsNotAPlainConstructionOrStaticFunctionCall() throws {
        let helper =
            "struct Idle {}\n    static func makeIdle() -> Idle { Idle() }\n    func notStatic() -> Idle { Idle() }"
        let message = "Put this construction in a static function that returns Idle and name that function here."
        for written in [
            "Idle(attempts: 0)",
            "Idle(0)",
            "Loading()",
            "Idle().self",
            "makeIdle(1)",
            "makeIdle",
            "unknown()",
            "notStatic()",
            "Other.makeIdle()",
            ".makeIdle()",
            "Flow.Idle.makeIdle()",
            "makeIdle() ?? makeIdle()",
            "try makeIdle()",
            "makeIdle { Idle() }",
            "Idle<Int>()",
            "0",
        ] {
            let source = Self.schema.replacingOccurrences(of: "struct Idle {}", with: helper)
                .replacingOccurrences(of: "@Initial case idle(Idle)", with: "@Initial case idle(Idle = \(written))")
            do {
                _ = try Self.parse(source)
                Issue.record("Expected rejection of the default \(written)")
            } catch let error as DiagnosticsError {
                #expect(error.diagnostics.map(\.message) == [message], "\(written)")
                #expect(error.diagnostics.first?.node.trimmedDescription == written, "\(written)")
            }
        }
    }

    @Test func diagnosesDefaultsOutsideTheInitialCase() throws {
        let message = "Use an unlabeled payload without a default value."
        let failures: [(String, String)] = [
            (
                "another phase",
                Self.schema.replacingOccurrences(of: "case loading(Loading)", with: "case loading(Loading = Loading())")
            ),
            ("an input", Self.schema.replacingOccurrences(of: "case start(Int)", with: "case start(Int = 0)")),
            (
                "a phase of an initial case with a default",
                Self.schema
                    .replacingOccurrences(of: "@Initial case idle(Idle)", with: "@Initial case idle(Idle = Idle())")
                    .replacingOccurrences(of: "case loading(Loading)", with: "case loading(Loading = Loading())")
            ),
        ]
        for (name, source) in failures {
            do {
                _ = try Self.parse(source)
                Issue.record("Expected rejection of a default on \(name)")
            } catch let error as DiagnosticsError {
                #expect(error.diagnostics.map(\.message) == [message], "\(name)")
            }
        }
        let labeled = Self.schema.replacingOccurrences(
            of: "@Initial case idle(Idle)",
            with: "@Initial case idle(value: Idle = Idle())"
        )
        do {
            _ = try Self.parse(labeled)
            Issue.record("Expected rejection of a labeled initial payload")
        } catch let error as DiagnosticsError {
            #expect(error.diagnostics.map(\.message) == ["Use an unlabeled payload."])
        }
    }

    @Test func caseNamesFollowSwiftIdentifierGrammar() throws {
        let source = Self.schema.replacingOccurrences(of: "case idle(Idle)", with: "case начало(Idle)")
        #expect(try Self.parse(source).initial == "начало")
    }

}
