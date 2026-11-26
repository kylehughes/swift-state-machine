import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

/// Keyed operations, completion requests, the completion policy default, and the names they generate.
struct OperationsTests {
    static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }
    static func diagnostics(_ text: String) -> [String]? { DeclarationHygieneTests.diagnostics(text) }

    /// The generated members of a schema, as one source text.
    static func expansion(_ text: String) throws -> String {
        try Generator(schema: parse(text)).members().map(\.description).joined(separator: "\n")
    }

    /// A browser with one keyed download, which `remove` cancels by key.
    static let keyed = #"""
        @StateMachine(mode: .shared)
        enum Files {
            struct Browsing {}
            @Initial case browsing(Browsing)
            enum Input { case open(Int), remove(Int) }
            @Operation(activeIn: [Browsing.self])
            enum Download {
                typealias Key = Int
                typealias Input = String
                typealias Output = String
            }
            @Transition(on: Input.open, starts: [Download.self])
            static func open(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Open> { fatalError() }
            @Transition(on: Input.remove, cancels: [Download.self])
            static func remove(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Remove> { fatalError() }
            @Transition(onSuccess: Download.self)
            static func opened(_ source: Browsing, _ output: Download.Output, request: DownloadRequest) -> Browsing {
                fatalError()
            }
        }
        """#

    @Test func aKeyedOperationGeneratesKeyedEffectsRequestsAndDrivers() throws {
        let schema = try Self.parse(Self.keyed)
        let download = try #require(schema.operations.first)
        #expect(download.keyType == "Int")
        #expect(schema.transitions.first { $0.name == "remove" }?.cancels == ["download"])
        #expect(schema.transitions.first { $0.name == "opened" }?.requestType == "DownloadRequest")
        let text = try Self.expansion(Self.keyed)
        #expect(text.contains("case download(key: Files.Download.Key, input: Files.Download.Input)"))
        #expect(text.contains("case cancelDownload(key: Files.Download.Key)"))
        #expect(text.contains("case cancelAllDownload"))
        // A request that carries an input is the runtime's request specialized at it, so it stores any
        // input and is `Sendable` exactly when its input is.
        #expect(
            text.contains(
                "typealias DownloadRequest = StateMachine::KeyedOperationRequest<Download, Download.Key, Download.Input>"
            )
        )
        #expect(text.contains("@Sendable (Download.Key, Download.Input) async -> Download.Output"))
        #expect(text.contains("let _ = _OperationKeyIsHashable<Download.Key>()"))
    }

    @Test func cancellingAnUnkeyedOperationOrAnEventIsDiagnosed() {
        let unkeyed = Self.keyed.replacingOccurrences(of: "typealias Key = Int\n", with: "")
            .replacingOccurrences(of: "request: DownloadRequest", with: "request: Int")
        #expect(
            Self.diagnostics(unkeyed) == [
                "'Download' declares no Key, so it has no work to cancel by key; declare a Key, or revoke its work by invalidating its scope with invalidates:."
            ]
        )
        let event = Self.keyed
            .replacingOccurrences(
                of: "@Transition(on: Input.remove, cancels: [Download.self])",
                with: "@Transition(on: Input.remove, cancels: [Opened.self])"
            )
            .replacingOccurrences(of: "enum Input {", with: "@Event enum Opened {}\nenum Input {")
        #expect(Self.diagnostics(event) == ["'Opened' is an @Event, which has no work to cancel."])
    }

    @Test func aCaseThatCollidesWithACancellationIsDiagnosed() {
        let source = Self.keyed.replacingOccurrences(
            of: "enum Input {",
            with: "@Event enum CancelDownload {}\nenum Input {"
        )
        #expect(
            Self.diagnostics(source) == [
                "Event 'CancelDownload' generates the effect case 'cancelDownload', which keyed operation 'Download' uses to cancel its work; rename one.",
                "Keyed operation 'Download' generates the effect case 'cancelDownload' to cancel one key's work, which event 'CancelDownload' also generates; rename one.",
            ]
        )
    }

    @Test func aRequestParameterNeedsAnOperationWithARequest() {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case go }
                @Operation(activeIn: [Idle.self])
                enum Refresh {}
                @Transition(on: Input.go, starts: [Refresh.self])
                static func go(_ source: Idle) -> Change<Idle, Effect.Go> { fatalError() }
                @Transition(onSuccess: Refresh.self)
                static func refreshed(_ source: Idle, request: Int) -> Idle { fatalError() }
            }
            """#
        #expect(
            Self.diagnostics(source) == [
                "Operation 'Refresh' has no Key and takes no input, so its completion carries no request; remove this parameter."
            ]
        )
        let extra = source.replacingOccurrences(of: ", request: Int)", with: ", _ more: Int, request: Int)")
        #expect(
            Self.diagnostics(extra) == [
                "Operation 'Refresh' succeeds without output, so its success edge takes no output parameter; remove this parameter, and take the operation's request, if any, labeled request:."
            ]
        )
        let fallible =
            source.replacingOccurrences(of: "enum Refresh {}", with: "enum Refresh { typealias Output = Int }")
            .replacingOccurrences(of: ", request: Int)", with: ", _ output: Int, _ more: Int, request: Int)")
        #expect(
            Self.diagnostics(fallible) == [
                "This trigger requires source and trigger payload parameters, and optionally the operation's request, labeled request:."
            ]
        )
    }

    /// An edge named after its schema would generate `Effect.Search`, which hides the schema inside `Effect`.
    @Test func anEffectTypeNamedLikeItsSchemaIsDiagnosed() {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Search {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case search }
                @Operation(activeIn: [Idle.self])
                enum Fetch {}
                @Transition(on: Input.search, starts: [Fetch.self])
                static func search(_ source: Idle) -> Change<Idle, Effect.Search> { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func fetched(_ source: Idle, _ output: Fetch.Output) -> Idle { fatalError() }
            }
            """#
        #expect(
            Self.diagnostics(source) == [
                "This transition's effect type would be Effect.Search, which hides the schema 'Search' inside Effect; rename the transition."
            ]
        )
        let routed = #"""
            @StateMachine(mode: .shared)
            enum Pick {
                struct Idle {}
                struct Busy {}
                @Initial case idle(Idle)
                case busy(Busy)
                enum Input { case go }
                @Transition(on: Input.go)
                static func left(_ source: Idle) -> Busy { fatalError() }
                @Transition(on: Input.go)
                static func right(_ source: Idle) -> Idle { fatalError() }
                @Route(on: Input.go)
                static func pick(_ source: Idle) -> Route.Pick { fatalError() }
                @Transition(on: Input.go)
                static func back(_ source: Busy) -> Idle { fatalError() }
            }
            """#
        #expect(
            Self.diagnostics(routed) == [
                "This router's choice type would be Route.Pick, which hides the schema 'Pick' inside Route; rename the router."
            ]
        )
    }

    @Test func managedInitializersDefaultToRetryOnlyWhenNoCompletionCanRefuse() throws {
        let text = try Self.expansion(Self.keyed)
        #expect(text.contains("completionPolicy: CompletionPolicy = .retry"))
        #expect(!text.contains("completionPolicy: CompletionPolicy)"))
        // A throwing completion edge can refuse an outcome.
        let throwing = try Self.expansion(
            Self.keyed
                .replacingOccurrences(
                    of: "request: DownloadRequest) -> Browsing {",
                    with: "request: DownloadRequest) throws(Refusal) -> Browsing {"
                )
                .replacingOccurrences(of: "enum Input {", with: "enum Refusal: Error {}\nenum Input {")
        )
        #expect(!throwing.contains("= .retry"))
        #expect(throwing.contains("completionPolicy: CompletionPolicy)"))
        // So can a completion edge that starts an operation whose admission can reject it.
        let starting = try Self.parse(
            Self.keyed
                .replacingOccurrences(
                    of: "@Transition(onSuccess: Download.self)",
                    with: "@Transition(onSuccess: Download.self, starts: [Download.self])"
                )
                .replacingOccurrences(
                    of: "@Operation(activeIn: [Browsing.self])",
                    with: "@Operation(activeIn: [Browsing.self], admission: .rejectWhenActive)"
                )
                .replacingOccurrences(
                    of: "request: DownloadRequest) -> Browsing",
                    with: "request: DownloadRequest) -> Change<Browsing, Effect.Opened>"
                )
        )
        #expect(starting.completionCanRefuse)
        let latest = try Self.parse(
            Self.keyed
                .replacingOccurrences(
                    of: "@Transition(onSuccess: Download.self)",
                    with: "@Transition(onSuccess: Download.self, starts: [Download.self])"
                )
                .replacingOccurrences(
                    of: "request: DownloadRequest) -> Browsing",
                    with: "request: DownloadRequest) -> Change<Browsing, Effect.Opened>"
                )
        )
        #expect(!latest.completionCanRefuse)
    }

    @Test func aLocalOwnerConformsForTheHarnessThroughTheProtocolItsSurfaceSupports() throws {
        let delivering = try Self.expansion(Self.keyed)
        #expect(delivering.contains("struct Local: ~Swift::Copyable, StateMachine::DeliveringLocalStateMachine"))
        #expect(delivering.contains("struct CommandBatch: Swift::Sendable, StateMachine::LocalCommandBatch"))
        #expect(delivering.contains("typealias Completion = Files.Completion"))
        #expect(delivering.contains("static func receipt(of result: DeliveryResult) -> Receipt?"))
        #expect(delivering.contains("case .browsing: return \"browsing\""))
        // Every edge's plan records its identifier, which the accepted receipt reports.
        #expect(delivering.contains("edge: \"browsing.remove\")"))
        #expect(delivering.contains("var edgeID: Swift::String? { snapshot.record.edge }"))
        let plain = try Self.expansion(
            Self.keyed.replacingOccurrences(
                of: "@StateMachine(mode: .shared)",
                with: "@StateMachine(mode: .shared, owners: [.local, .shared])"
            )
        )
        #expect(plain.contains("StateMachine::DeliveringLocalStateMachine"))
        let managed = try Self.expansion(
            Self.keyed.replacingOccurrences(
                of: "@StateMachine(mode: .shared)",
                with: "@StateMachine(mode: .shared, owners: [.shared])"
            )
        )
        // Without `Local`, nothing names the harness, and receipts still name their edges.
        #expect(!managed.contains("LocalStateMachine"))
        #expect(!managed.contains("LocalCommandBatch"))
        #expect(managed.contains("edge: \"browsing.remove\")"))
        let draining = try Self.expansion(GraphStructureTests.tracked)
        #expect(draining.contains("struct Local: ~Swift::Copyable, StateMachine::DrainingLocalStateMachine"))
        let bare = try Self.expansion(
            #"""
            @StateMachine(mode: .shared)
            enum Toggle {
                struct Off {}
                @Initial case off(Off)
                enum Input { case flip }
                @Transition(on: Input.flip)
                static func flip(_ source: Off) -> Off { fatalError() }
            }
            """#
        )
        #expect(bare.contains("struct Local: ~Swift::Copyable, StateMachine::LocalStateMachine"))
        #expect(!bare.contains("LocalCommandBatch"))
    }

    @Test func namesAreReservedOnlyForTheOwnersThatGenerateThem() {
        let local = Self.keyed.replacingOccurrences(
            of: "@StateMachine(mode: .shared)",
            with: "@StateMachine(mode: .shared, owners: [.local])"
        )
        for name in ["Shared", "ActorHost", "Drivers", "Configuration", "ShutdownResult", "PendingCompletionUpdates"] {
            let source = local.replacingOccurrences(
                of: "struct Browsing {}",
                with: "struct Browsing {}\nstruct \(name) {}"
            )
            #expect(Self.diagnostics(source) == nil, "'\(name)' is free when no managed owner is generated")
        }
        for name in ["Local", "DownloadWork", "DownloadRequest", "CommandBatch", "InitialPhase"] {
            let source = local.replacingOccurrences(
                of: "struct Browsing {}",
                with: "struct Browsing {}\nstruct \(name) {}"
            )
            #expect(
                Self.diagnostics(source) == [
                    "'\(name)' is reserved for generated members; rename the authored declaration."
                ]
            )
        }
        let managed = Self.keyed.replacingOccurrences(
            of: "@StateMachine(mode: .shared)",
            with: "@StateMachine(mode: .shared, owners: [.shared])"
        )
        for name in ["Local", "DownloadWork", "LocalConfiguration", "MainActorHost", "InitialPhase"] {
            let source = managed.replacingOccurrences(
                of: "struct Browsing {}",
                with: "struct Browsing {}\nstruct \(name) {}"
            )
            #expect(
                Self.diagnostics(source) == nil,
                "'\(name)' is free when neither Local nor MainActorHost is generated"
            )
        }
        for name in ["PendingCompletionUpdates", "Shared", "Drivers", "DownloadCompletion"] {
            let source = managed.replacingOccurrences(
                of: "struct Browsing {}",
                with: "struct Browsing {}\nstruct \(name) {}"
            )
            #expect(
                Self.diagnostics(source) == [
                    "'\(name)' is reserved for generated members; rename the authored declaration."
                ]
            )
        }
    }

    @Test func theConfinedHostReservesItsNameItsOwnerParameterAndItsSequences() {
        func declaring(_ name: String, owners: String, mode: String = ".shared") -> String {
            Self.keyed
                .replacingOccurrences(
                    of: "@StateMachine(mode: .shared)",
                    with: "@StateMachine(mode: \(mode), owners: \(owners))"
                )
                .replacingOccurrences(of: "struct Browsing {}", with: "struct Browsing {}\nstruct \(name) {}")
        }
        for name in ["IsolatedHost", "Owner", "IsolatedSubscription", "Drivers"] {
            #expect(
                Self.diagnostics(declaring(name, owners: "[.isolatedHost]")) == [
                    "'\(name)' is reserved for generated members; rename the authored declaration."
                ]
            )
            #expect(Self.diagnostics(declaring(name, owners: "[.local]")) == nil, "'\(name)' is free without it")
        }
        for name in ["IsolatedSnapshots", "IsolatedPendingCompletionUpdates"] {
            #expect(
                Self.diagnostics(declaring(name, owners: "[.isolatedHost]", mode: ".isolated")) == [
                    "'\(name)' is reserved for generated members; rename the authored declaration."
                ]
            )
            // A shared-mode confined host returns the shared sequences, so these names stay free there.
            #expect(Self.diagnostics(declaring(name, owners: "[.isolatedHost]")) == nil)
        }
        // An isolated schema with only a confined host has no MainActor sequence aliases to reserve.
        for name in ["MainActorSnapshots", "PendingCompletionUpdates"] {
            #expect(Self.diagnostics(declaring(name, owners: "[.isolatedHost]", mode: ".isolated")) == nil)
        }
    }

    @Test func aThrowingRestorationReservesTheResetRejection() {
        let base = Self.keyed.replacingOccurrences(
            of: "enum Input {",
            with: """
                enum Refusal: Error {}
                @Restoration
                static func restore(_ saved: Int) throws(Refusal) -> Restoration { fatalError() }
                enum Input {
                """
        )
        let source = base.replacingOccurrences(
            of: "struct Browsing {}",
            with: "struct Browsing {}\nstruct ResetRejection {}"
        )
        #expect(
            Self.diagnostics(source) == [
                "'ResetRejection' is reserved for generated members; rename the authored declaration."
            ]
        )
        let infallible = source.replacingOccurrences(of: " throws(Refusal) -> Restoration", with: " -> Restoration")
        #expect(Self.diagnostics(infallible) == nil)
    }
    /// Same-named edges share the short `Effect.<Edge>` only when they declare the same starts,
    /// cancellations, and events; otherwise each keeps its phase-qualified type.
    @Test func sameNamedEdgesShareAnEffectTypeOnlyWithTheSameEffects() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Draft {}
                struct Review {}
                @Initial case draft(Draft)
                case review(Review)
                enum Input { case save }
                @Operation(activeIn: [Draft.self, Review.self])
                enum Store {}
                @Event enum Saved {}
                @Transition(on: Input.save, starts: [Store.self])
                static func save(_ source: Draft) -> Change<Review, Effect.Draft.Save> { fatalError() }
                @Transition(on: Input.save, starts: [Store.self], emits: [Saved.self])
                static func save(_ source: Review) -> Change<Draft, Effect.Review.Save> { fatalError() }
                @Transition(onSuccess: Store.self)
                static func stored(_ source: Draft) -> Draft { fatalError() }
                @Transition(onSuccess: Store.self)
                static func stored(_ source: Review) -> Review { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(!schema.sharesEffect("save"))
        let review = try #require(schema.transitions.first { $0.name == "save" && $0.from == "review" })
        #expect(schema.effectType(review) == "Effect.Review.Save")
        let text = try Self.expansion(source)
        #expect(!text.contains("typealias Save ="))
    }

    // MARK: Carriage and roles

    /// An input's carriage is decided before what it must be: an omitted input must be `Void`, and a
    /// carried one, of any reading, must not be `Never`, so an input carried because a completion takes
    /// the request cannot hide `Never` behind a name that reads as `Void`.
    @Test func aCarriedInputIsCheckedToHaveValues() throws {
        let never =
            "Operation 'Load' takes Never as its input, so no transition can start it; declare an input type that has values, or remove the operation."
        let carried = TypeResolutionTests.loading(
            aliases: "typealias Input = Void",
            edges:
                "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, request: LoadRequest) -> Idle { fatalError() }"
        )
        let schema = try Self.parse(carried)
        let operation = try #require(schema.operations.first)
        #expect(operation.takesInput)
        #expect(schema.typeChecks == [Schema.TypeCheck(kind: .isNotNever(message: never), reference: "Load.Input")])
        let omitted = TypeResolutionTests.loading(
            aliases: "typealias Input = Void",
            edges: "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running) -> Idle { fatalError() }"
        )
        let plain = try Self.parse(omitted)
        let omittedOperation = try #require(plain.operations.first)
        #expect(!omittedOperation.takesInput)
        #expect(plain.typeChecks == [Schema.TypeCheck(kind: .isStandard("Void"), reference: "Load.Input")])
    }

    /// The argument label alone decides a completion parameter's role.
    ///
    /// `request:` is the request, and an unlabeled parameter after the source is the output, whatever
    /// either spells. No reading of a type, an `Output` that is the request's own type included, changes
    /// the generated shape.
    @Test func aCompletionParameterTakesItsRoleFromItsLabel() throws {
        func fetching(output: String, parameters: String, declarations: String = "") -> String {
            """
            @StateMachine(mode: .shared)
            enum Flow {
                \(declarations)
                struct Idle {}
                struct Running {}
                @Initial case idle(Idle)
                case running(Running)
                enum Input { case go(Swift::Int) }
                @Operation(activeIn: [Running.self])
                enum Fetch { typealias Input = Swift::Int; typealias Output = \(output) }
                @Transition(on: Input.go, starts: [Fetch.self])
                static func go(_ source: Idle, _ value: Swift::Int) -> Change<Running, Effect.Go> { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func done(_ source: Running\(parameters)) -> Idle { fatalError() }
            }
            """
        }
        let declarations =
            "typealias Started = FetchRequest; typealias SelfStarted = Self.FetchRequest; enum Names { typealias Started = FetchRequest }"
        // Unlabeled, every spelling is the output, the request's own type included.
        for parameter in ["FetchRequest", "Fetch.Output", "Self.FetchRequest", "Started", "Swift::Int"] {
            for output in ["FetchRequest", "Outside", "Swift::Int"] {
                let schema = try Self.parse(
                    fetching(output: output, parameters: ", _ value: \(parameter)", declarations: declarations)
                )
                let operation = try #require(schema.operations.first)
                #expect(!operation.producesVoid, "\(parameter), \(output)")
                #expect(schema.transitions.last?.payloadType != nil, "\(parameter), \(output)")
                #expect(schema.transitions.last?.requestType == nil, "\(parameter), \(output)")
            }
        }
        // Labeled `request:`, every spelling is the request; with no unlabeled parameter, a success with
        // an output the macro cannot read carries none.
        for parameter in ["Started", "SelfStarted", "Names.Started", "Flow.FetchRequest", "Swift::Int"] {
            let schema = try Self.parse(
                fetching(output: "Outside", parameters: ", request: \(parameter)", declarations: declarations)
            )
            let operation = try #require(schema.operations.first)
            #expect(operation.producesVoid, "\(parameter)")
            #expect(schema.transitions.last?.requestType == parameter, "\(parameter)")
            #expect(schema.transitions.last?.payloadType == nil, "\(parameter)")
        }
        let both = try Self.parse(
            fetching(output: "FetchRequest", parameters: ", _ output: FetchRequest, request: FetchRequest")
        )
        #expect(both.transitions.last?.payloadType == "FetchRequest")
        #expect(both.transitions.last?.requestType == "FetchRequest")
        // An operation that succeeds with output takes the output first; the request alone is diagnosed.
        #expect(
            Self.diagnostics(
                fetching(output: "Swift::Int", parameters: ", request: Started", declarations: declarations)
            ) == [
                "Operation 'Fetch' succeeds with output, so its success edge takes the output, unlabeled, after the source, then the request, if any, labeled request:."
            ]
        )
        // The request follows every other parameter, once.
        #expect(
            Self.diagnostics(fetching(output: "Swift::Int", parameters: ", request: FetchRequest, _ value: Swift::Int"))
                == ["Take the request last, labeled request:, after the source and the operation's output."]
        )
        #expect(
            Self.diagnostics(
                fetching(
                    output: "Swift::Int",
                    parameters: ", _ value: Swift::Int, request: FetchRequest, request: FetchRequest"
                )
            ) == ["Take the operation's request once, in the last parameter, labeled request:."]
        )
    }

    /// Only a completion takes a request: an input edge, a router of an input, and a restoration take
    /// unlabeled parameters.
    @Test func onlyACompletionTakesARequestLabel() {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case go(Int) }
                @Transition(on: Input.go)
                static func go(_ source: Idle, request: Int) -> Idle { fatalError() }
            }
            """#
        #expect(
            Self.diagnostics(source) == [
                "Only a completion edge or router takes its operation's request, labeled request:; take this parameter without a label."
            ]
        )
        let labeled = source.replacingOccurrences(of: "request: Int", with: "value: Int")
        #expect(
            Self.diagnostics(labeled) == [
                "Use a synchronous nongeneric static function with nonvariadic parameters and no defaults, each unlabeled except a completion's request, labeled request:."
            ]
        )
    }

    /// Exported schemas retain the typed phase payload alongside the pointer-sized raw snapshot,
    /// while non-exported schemas project through a sealed per-phase noncapturing extractor.
    ///
    /// Both paths avoid generic dynamic casts, `@inlinable` interface exposure, and unsafe pointer
    /// loads, keep `record`, `claim`, `_StateMachineEngine`, and `Observed.init` `fileprivate`,
    /// and append underscores deterministically when authored verbs collide with private fields.
    @Test func observationValueAvoidsDynamicCastInterfaceLeaksAndVerbCollisions() throws {
        func schema(access: String, mode: String) -> String {
            let prefix = access.isEmpty ? "" : "\(access) "
            let member = (access == "public" || access == "package") ? "\(access) " : ""
            let sendable = mode == ".shared" ? ": Sendable" : ""
            return """
                @StateMachine(mode: \(mode), owners: [.local])
                \(prefix)nonisolated enum Flow\(sendable) {
                    \(member)struct First\(sendable) { \(member)let n: Int }
                    \(member)struct Result\(sendable) { \(member)let s: String }
                    \(member)struct Model\(sendable) { \(member)let v: Int }
                    @Initial case first(First)
                    case result(Result)
                    @Terminal case model(Model)
                    \(member)enum Input\(sendable) { case payload, project }
                    @Transition(on: Input.payload)
                    static func payload(_ source: First) -> Result { fatalError() }
                    @Transition(on: Input.project)
                    static func project(_ source: Result) -> Model { fatalError() }
                }
                """
        }

        for (access, mode) in [("public", ".isolated"), ("public", ".shared"), ("package", ".isolated")] {
            let source = schema(access: access, mode: mode)
            #expect(Self.diagnostics(source) == nil, "\(access) \(mode) schema must expand cleanly")
            let text = try Self.expansion(source)
            #expect(text.contains("fileprivate let _stateMachinePayload: Phase"))
            #expect(text.contains("_stateMachinePayload: payload"))
            #expect(!text.contains("_stateMachineProject"))
            #expect(text.contains("fileprivate let record: _StateMachineEngine.Snapshot"))
            #expect(text.contains("fileprivate let claim: StateMachine::RuntimeDeliveryClaim?"))
            #expect(text.contains("fileprivate typealias _StateMachineEngine ="))
            #expect(!text.contains("as Phase"), "Observed.value must not fall back to generic dynamic cast")
            #expect(!text.contains("UnsafeRawPointer"), "Observed.value must stay memory-safe")
            #expect(!text.contains("@inlinable"), "Observed.value must not leak into module interfaces")
            #expect(!text.contains("@usableFromInline"), "Observed.value must not expose internal helpers")
        }

        for (access, mode) in [("", ".isolated"), ("internal", ".shared"), ("private", ".isolated")] {
            let source = schema(access: access, mode: mode)
            #expect(Self.diagnostics(source) == nil, "\(access) \(mode) schema must expand cleanly")
            let text = try Self.expansion(source)
            let expectedProjectType =
                mode == ".shared"
                ? "@Sendable (borrowing _StateMachineEngine.Snapshot) -> Phase"
                : "(borrowing _StateMachineEngine.Snapshot) -> Phase"
            #expect(text.contains("fileprivate let _stateMachineProject: \(expectedProjectType)"))
            #expect(text.contains("_stateMachineProject(record)"))
            #expect(text.contains("_stateMachineProject: { record in"))
            #expect(!text.contains("fileprivate let _stateMachinePayload: Phase"))
            #expect(text.contains("fileprivate let record: _StateMachineEngine.Snapshot"))
            #expect(text.contains("fileprivate let claim: StateMachine::RuntimeDeliveryClaim?"))
            #expect(text.contains("fileprivate typealias _StateMachineEngine ="))
            #expect(!text.contains("as Phase"), "Observed.value must not fall back to generic dynamic cast")
            #expect(!text.contains("UnsafeRawPointer"), "Observed.value must stay memory-safe")
            #expect(!text.contains("@inlinable"), "Observed.value must not leak into module interfaces")
            #expect(!text.contains("@usableFromInline"), "Observed.value must not expose internal helpers")
        }

        // Exported schemas with zero-argument verbs named `_stateMachinePayload` and
        // `_stateMachinePayload_` (plus `_stateMachineProject`) must remain valid via fallback.
        let collidingExported = #"""
            @StateMachine(mode: .isolated, owners: [.local])
            public nonisolated enum CollidingExportedFlow {
                public struct First { public let n: Int }
                public struct Second { public let n: Int }
                public struct Done { public let n: Int }
                @Initial case first(First)
                case second(Second)
                @Terminal case done(Done)
                public enum Input { case step, decide, project }
                @Transition(on: Input.step)
                static func _stateMachinePayload(_ source: First) -> Second { fatalError() }
                @Transition(on: Input.project)
                static func _stateMachineProject(_ source: First) -> Second { fatalError() }
                @Transition(on: Input.decide)
                static func left(_ source: Second) -> Done { fatalError() }
                @Transition(on: Input.decide)
                static func right(_ source: Second) -> First { fatalError() }
                @Route(on: Input.decide)
                static func _stateMachinePayload_(_ source: Second) -> Route._stateMachinePayload_ { fatalError() }
            }
            """#
        #expect(Self.diagnostics(collidingExported) == nil)
        let exportedText = try Self.expansion(collidingExported)
        #expect(exportedText.contains("fileprivate let _stateMachinePayload__: Phase"))
        #expect(exportedText.contains("_stateMachinePayload__: payload"))
        #expect(exportedText.contains("public func _stateMachinePayload() -> Prepared where Phase == First"))
        #expect(exportedText.contains("public func _stateMachineProject() -> Prepared where Phase == First"))
        #expect(exportedText.contains("public func _stateMachinePayload_() -> Prepared where Phase == Second"))

        // Non-exported schemas with zero-argument verbs named `_stateMachineProject` and
        // `_stateMachineProject_` must remain valid via underscored extractor fallback.
        let collidingInternal = #"""
            @StateMachine(mode: .isolated, owners: [.local])
            nonisolated enum CollidingInternalFlow {
                struct First { let n: Int }
                struct Second { let n: Int }
                struct Done { let n: Int }
                @Initial case first(First)
                case second(Second)
                @Terminal case done(Done)
                enum Input { case step, decide }
                @Transition(on: Input.step)
                static func _stateMachineProject(_ source: First) -> Second { fatalError() }
                @Transition(on: Input.decide)
                static func left(_ source: Second) -> Done { fatalError() }
                @Transition(on: Input.decide)
                static func right(_ source: Second) -> First { fatalError() }
                @Route(on: Input.decide)
                static func _stateMachineProject_(_ source: Second) -> Route._stateMachineProject_ { fatalError() }
            }
            """#
        #expect(Self.diagnostics(collidingInternal) == nil)
        let internalText = try Self.expansion(collidingInternal)
        #expect(
            internalText.contains(
                "fileprivate let _stateMachineProject__: (borrowing _StateMachineEngine.Snapshot) -> Phase"
            )
        )
        #expect(internalText.contains("_stateMachineProject__(record)"))
        #expect(internalText.contains("_stateMachineProject__: { record in"))
        #expect(internalText.contains("internal func _stateMachineProject() -> Prepared where Phase == First"))
        #expect(internalText.contains("internal func _stateMachineProject_() -> Prepared where Phase == Second"))
    }
}
