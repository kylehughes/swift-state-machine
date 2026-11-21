import SwiftDiagnostics
import Testing

@testable import StateMachineMacros

/// The declaration grammar: restoration lists, omitted operation aliases, pinned router failures,
/// edges that share a name across phases, and transitions from several phases.
struct DeclarationGrammarTests {
    private static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }
    private static func diagnostics(_ text: String) -> [String]? { DeclarationHygieneTests.diagnostics(text) }

    // MARK: Restoration

    static let archive = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            struct Draft {}
            struct Saving {}
            struct Published {}
            @Initial case draft(Draft)
            case saving(Saving)
            @Terminal case published(Published)
            enum Input { case save }
            @Operation(activeIn: [Saving.self])
            enum Save { typealias Input = Int }
            @Restoration
            static func restore(_ saved: Int) -> Restoration { fatalError() }
            @Transition(on: Input.save, starts: [Save.self])
            static func save(_ source: Draft) -> Change<Saving, Effect.Save> { fatalError() }
            @Transition(onSuccess: Save.self)
            static func saved(_ source: Saving) -> Published { fatalError() }
        }
        """#

    @Test func restorationListsExactlyItsOnlyPhases() throws {
        func restoring(_ arguments: String) -> String {
            Self.archive.replacingOccurrences(of: "@Restoration\n", with: "@Restoration\(arguments)\n")
        }
        #expect(try Self.parse(Self.archive).restorablePhases.map(\.caseName) == ["draft", "published"])
        #expect(
            try Self.parse(restoring("(allows: [Saving.self])")).restorablePhases.map(\.caseName) == [
                "draft", "saving", "published",
            ]
        )
        let only = try Self.parse(restoring("(only: [Published.self, Saving.self])"))
        #expect(only.restoration?.only == ["published", "saving"])
        // Declaration order, and a resting phase that is not listed is excluded.
        #expect(only.restorablePhases.map(\.caseName) == ["saving", "published"])
        #expect(
            Self.diagnostics(restoring("(only: [])")) == ["List at least one restorable phase in only:."]
        )
        #expect(
            Self.diagnostics(restoring("(only: [Draft.self], allows: [Saving.self])")) == [
                "Use only: to list every restorable phase, or allows: to add phases to the resting ones, not both."
            ]
        )
        #expect(
            Self.diagnostics(restoring("(only: [Save.self])")) == [
                "'Save' is not a phase payload type declared in this schema."
            ]
        )
    }

    // MARK: Operation aliases

    @Test func aSuccessWithoutOutputTakesNoOutputParameter() throws {
        // `Save` has an input, so its request, labeled `request:`, may follow the source.
        let request = Self.archive.replacingOccurrences(
            of: "static func saved(_ source: Saving)",
            with: "static func saved(_ source: Saving, request: SaveRequest)"
        )
        let edge = try #require(try Self.parse(request).transitions.last)
        #expect(edge.payloadType == nil)
        #expect(edge.requestType == "SaveRequest")
        let message =
            "Operation 'Save' succeeds without output, so its success edge takes no output parameter; remove this parameter, and take the operation's request, if any, labeled request:."
        // Every unlabeled parameter after the source is an output, whatever it spells: the request's own
        // type, and a bare `Void` that a declaration could hide, included.
        for output in [
            "()", "Swift::Void", "Void", "Save.Output", "Self.Save.Output", "Flow.Save.Output", "SaveRequest",
        ] {
            let spelled = Self.archive.replacingOccurrences(
                of: "static func saved(_ source: Saving)",
                with: "static func saved(_ source: Saving, _ output: \(output))"
            )
            #expect(Self.diagnostics(spelled) == [message], "\(output)")
            let both = Self.archive.replacingOccurrences(
                of: "static func saved(_ source: Saving)",
                with: "static func saved(_ source: Saving, _ output: \(output), request: SaveRequest)"
            )
            #expect(Self.diagnostics(both) == [message], "\(output)")
        }
        // The request directly follows the source.
        let reversed = Self.archive.replacingOccurrences(
            of: "static func saved(_ source: Saving)",
            with: "static func saved(_ source: Saving, request: SaveRequest, _ output: Void)"
        )
        #expect(
            Self.diagnostics(reversed) == [
                "Take the request last, labeled request:; this success takes no output, so the request directly follows the source."
            ]
        )
        // Without a key or an input there is no request either.
        let bare = Self.archive.replacingOccurrences(of: "enum Save { typealias Input = Int }", with: "enum Save {}")
            .replacingOccurrences(
                of: "static func saved(_ source: Saving)",
                with: "static func saved(_ source: Saving, request: SaveRequest)"
            )
        #expect(
            Self.diagnostics(bare) == [
                "Operation 'Save' has no Key and takes no input, so its completion carries no request; remove this parameter."
            ]
        )
    }

    @Test func omittedOperationAliasesAreVoid() throws {
        let source = Self.archive.replacingOccurrences(of: "enum Save { typealias Input = Int }", with: "enum Save {}")
        let operation = try #require(try Self.parse(source).operations.first)
        #expect(!operation.declaresInput && !operation.declaresOutput && !operation.declaresFailure)
        #expect(
            operation.input == "Swift::Void" && operation.output == "Swift::Void" && operation.failure == "Swift::Never"
        )
        #expect(!operation.takesInput && operation.producesVoid && operation.isInfallible)
        let declared = try #require(try Self.parse(Self.archive).operations.first)
        #expect(declared.input == "Save.Input" && declared.output == "Swift::Void" && declared.takesInput)
        // An empty tuple is recognized with any comments, spacing, or enclosing parentheses.
        let spellings = ["Void", "()", "Swift.Void", "( /*done*/ )", "(\n)", "(Void)", "((  ))", "Swift . Void"]
        for spelling in spellings {
            let explicit = Self.archive.replacingOccurrences(
                of: "typealias Input = Int",
                with: "typealias Input = \(spelling)"
            )
            #expect(try #require(try Self.parse(explicit).operations.first).takesInput == false, "\(spelling)")
            #expect(LexicalScopes().resolve(spelling).isVoid, "\(spelling)")
        }
        for spelling in ["(Int)", "(Void, Void)", "(value: Void)", "Void?", "Swift.Void.Type", "Never"] {
            #expect(!LexicalScopes().resolve(spelling).isVoid, "\(spelling)")
        }
        for spelling in ["Never", "Swift.Never", "( Never /*none*/ )", "Swift/**/.Never", "Swift::Never"] {
            #expect(LexicalScopes().resolve(spelling).isNever, "\(spelling)")
        }
        #expect(!LexicalScopes().resolve("Never?").isNever && !LexicalScopes().resolve("Problem").isNever)
    }

    // MARK: Pinned router failures

    static let routed = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            struct Start {}
            struct Done {}
            @Initial case start(Start)
            case done(Done)
            enum Input { case pick(Int) }
            @Operation(activeIn: [Done.self])
            enum Fetch { typealias Output = Int }
            @Transition(on: Input.pick)
            static func left(_ source: Start, _ value: Int) throws(Alias) -> Done { fatalError() }
            @Transition(on: Input.pick)
            static func right(_ source: Start, _ value: Int) -> Start { fatalError() }
            @Route(on: Input.pick, failure: Problem.self)
            static func pick(_ source: Start, _ value: Int) throws(Problem) -> Route.Pick { fatalError() }
            @Transition(on: Input.pick, starts: [Fetch.self])
            static func again(_ source: Done, _ value: Int) -> Change<Done, Effect.Again> { fatalError() }
            @Transition(onSuccess: Fetch.self)
            static func fetched(_ source: Done, _ output: Int) -> Done { fatalError() }
        }
        """#

    @Test func anInputRouterPinsItsFailure() throws {
        let schema = try Self.parse(Self.routed)
        let route = try #require(schema.routes.first)
        #expect(route.pinnedFailure == "Problem")
        #expect(route.failureType == "Problem")
        #expect(schema.routerFailure(route) == "Problem")
        let qualified = try Self.parse(Self.routed.replacingOccurrences(of: "Problem.self", with: "Self.Problem.self"))
        #expect(qualified.routes.first?.pinnedFailure == "Flow.Problem")
        #expect(
            Self.diagnostics(Self.routed.replacingOccurrences(of: "failure: Problem.self", with: "failure: Problem"))
                == ["Name the pinned failure type as <Failure>.self."]
        )
        let completion = Self.routed.replacingOccurrences(
            of: "@Transition(onSuccess: Fetch.self)",
            with:
                "@Route(onSuccess: Fetch.self, failure: Problem.self)\n    static func screen(_ source: Done, _ output: Int) throws(Problem) -> Never { fatalError() }\n    @Transition(onSuccess: Fetch.self)"
        )
        #expect(
            Self.diagnostics(completion) == [
                "Only an input router pins its failure with failure:; delivery reports a completion router's failure."
            ]
        )
    }

    // MARK: One name in several phases

    static let overloaded = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            struct Draft {}
            struct Failed {}
            struct Saving {}
            @Initial case draft(Draft)
            case failed(Failed)
            case saving(Saving)
            enum Input { case edit(String), retry }
            @Operation(activeIn: [Saving.self])
            enum Save { typealias Input = String }
            @Operation(activeIn: [Saving.self])
            enum Audit { typealias Input = String }
            @Transition(on: Input.edit)
            static func edit(_ source: Draft, _ text: String) throws(DraftError) -> Draft { fatalError() }
            @Transition(on: Input.edit)
            static func edit(_ source: Saving, _ text: String) throws(SavingError) -> Failed { fatalError() }
            @Transition(on: Input.edit)
            static func edit(_ source: Failed, _ text: String) throws(DraftError) -> Draft { fatalError() }
            @Transition(on: Input.retry, starts: [Save.self])
            static func retry(_ source: Draft) -> Change<Saving, Effect.Draft.Retry> { fatalError() }
            @Transition(on: Input.retry, starts: [Save.self, Audit.self])
            static func retry(_ source: Failed) -> Change<Saving, Effect.Failed.Retry> { fatalError() }
            @Transition(onSuccess: Save.self)
            static func saved(_ source: Saving) -> Draft { fatalError() }
            @Transition(onSuccess: Audit.self)
            static func audited(_ source: Saving) -> Saving { fatalError() }
        }
        """#

    @Test func edgesFromDifferentPhasesMayShareAName() throws {
        let schema = try Self.parse(Self.overloaded)
        #expect(schema.transitions.filter { $0.name == "edit" }.map(\.from) == ["draft", "saving", "failed"])
        // Different failure types give each phase its own rejection case; one type shares a case.
        #expect(
            Schema.rejectionCase("edit", from: "draft", distinguished: schema.namesThrowingDifferentFailures)
                == "draftEdit"
        )
        #expect(
            Schema.rejectionCase("edit", from: "saving", distinguished: schema.namesThrowingDifferentFailures)
                == "savingEdit"
        )
        // Different start lists have only the phase-qualified effect types.
        let retries = schema.transitions.filter { $0.name == "retry" }
        #expect(retries.map { schema.effectType($0) } == ["Effect.Draft.Retry", "Effect.Failed.Retry"])
        #expect(schema.effectPhases.map(\.typeName) == ["Draft", "Failed"])
        let shared = try Self.parse(
            Self.overloaded.replacingOccurrences(of: "SavingError", with: "DraftError")
                .replacingOccurrences(of: "starts: [Save.self])", with: "starts: [Save.self, Audit.self])")
                .replacingOccurrences(of: "Effect.Draft.Retry", with: "Effect.Retry")
                .replacingOccurrences(of: "Effect.Failed.Retry", with: "Effect.Retry")
        )
        #expect(
            Schema.rejectionCase("edit", from: "saving", distinguished: shared.namesThrowingDifferentFailures) == "edit"
        )
        #expect(
            shared.transitions.filter { $0.name == "retry" }.map { shared.effectType($0) } == [
                "Effect.Retry", "Effect.Retry",
            ]
        )
    }

    @Test func diagnosesNamesThatOnlyOnePhaseMayUse() throws {
        let failures: [(String, String)] = [
            (
                Self.overloaded.replacingOccurrences(
                    of: "static func edit(_ source: Failed,",
                    with: "static func edit(_ source: Draft,"
                ),
                "'Draft' already has an edge or router named 'edit'; give each edge from one phase a distinct name."
            ),
            (
                Self.overloaded.replacingOccurrences(
                    of: "struct Draft {}",
                    with: "struct Draft {}\n    static func edit() {}"
                ),
                "'edit' names a transition or router; a function that is neither cannot share its name."
            ),
            (
                Self.overloaded.replacingOccurrences(of: "Effect.Failed.Retry", with: "Effect.Retry"),
                "This transition starts Save, Audit; name its effects Effect.Failed.Retry."
            ),
            (
                // An edge named for a phase would generate a type that the phase's effect namespace uses.
                Self.overloaded
                    .replacingOccurrences(of: "func retry(_ source: Failed)", with: "func failed(_ source: Failed)")
                    .replacingOccurrences(of: "Effect.Failed.Retry", with: "Effect.Failed.Failed"),
                "Transition 'failed' would generate Effect.Failed, which is the namespace of phase 'Failed'; rename the transition."
            ),
            (
                // A prefixed rejection case collides with an authored function's own case.
                Self.overloaded.replacingOccurrences(
                    of: "@Transition(onSuccess: Save.self)",
                    with:
                        "@Transition(on: Input.retry)\n    static func draftEdit(_ source: Saving) throws(DraftError) -> Saving { fatalError() }\n    @Transition(onSuccess: Save.self)"
                ),
                "Transition 'draftEdit' would generate PreparationRejection.draftEdit, which transition 'edit' also generates; rename one."
            ),
        ]
        for (source, message) in failures {
            #expect(Self.diagnostics(source) == [message])
        }
    }

    @Test func routersFromDifferentPhasesMayShareAName() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                struct Busy {}
                @Initial case idle(Idle)
                case busy(Busy)
                enum Input { case go }
                @Transition(on: Input.go)
                static func stay(_ source: Idle) -> Idle { fatalError() }
                @Transition(on: Input.go)
                static func move(_ source: Idle) -> Busy { fatalError() }
                @Route(on: Input.go)
                static func pick(_ source: Idle) -> Route.Pick { fatalError() }
                @Transition(on: Input.go)
                static func stay(_ source: Busy) -> Busy { fatalError() }
                @Transition(on: Input.go)
                static func move(_ source: Busy) -> Idle { fatalError() }
                @Route(on: Input.go)
                static func pick(_ source: Busy) -> Route.Pick { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.routes.map(\.from) == ["idle", "busy"])
        #expect(schema.routes.map { schema.choiceType($0) } == ["Route.Pick", "Route.Pick"])
        #expect(schema.routes.map { schema.resultType($0) } == ["Route.Idle.PickResult", "Route.Busy.PickResult"])
        #expect(schema.routes.allSatisfy(schema.needsOwnedResult))
        // Different candidates leave only the phase-qualified choice types.
        let different = source.replacingOccurrences(
            of: "static func move(_ source: Busy) -> Idle",
            with: "static func leave(_ source: Busy) -> Idle"
        )
        #expect(
            Self.diagnostics(different) == ["A router returns its choice among stay, move: Route.Idle.Pick."]
        )
        let qualified = try Self.parse(
            different.replacingOccurrences(
                of: "func pick(_ source: Busy) -> Route.Pick",
                with: "func pick(_ source: Busy) -> Route.Busy.Pick"
            )
            .replacingOccurrences(
                of: "func pick(_ source: Idle) -> Route.Pick",
                with: "func pick(_ source: Idle) -> Route.Idle.Pick"
            )
        )
        #expect(qualified.routes.map { qualified.choiceType($0) } == ["Route.Idle.Pick", "Route.Busy.Pick"])
    }

    // MARK: Transitions from several phases

    static let signOut = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            struct Idle {}
            struct Loading {}
            struct Loaded {}
            @Initial case idle(Idle)
            case loading(Loading)
            case loaded(Loaded)
            enum Input { case signOut, note(String), load }
            @Operation(activeIn: [Idle.self])
            enum Log { typealias Input = String }
            @Transition(on: Input.load)
            static func load(_ source: Loading) -> Loaded { fatalError() }
            @Transition(from: [Loading.self, Loaded.self], on: Input.signOut, starts: [Log.self])
            static func signOut() -> Change<Idle, Effect.SignOut> { fatalError() }
            @Transition(from: [Idle.self, Loaded.self], on: Input.note)
            static func note(_ text: String) -> Loading { fatalError() }
            @Transition(onSuccess: Log.self)
            static func logged(_ source: Idle) -> Idle { fatalError() }
        }
        """#

    @Test func aTransitionMayLeaveEveryListedPhase() throws {
        let schema = try Self.parse(Self.signOut)
        let signOut = schema.transitions.filter { $0.name == "signOut" }
        #expect(signOut.map(\.from) == ["loading", "loaded"])
        #expect(signOut.allSatisfy { !$0.takesSource && $0.sources == ["loading", "loaded"] })
        #expect(signOut.map { schema.effectType($0) } == ["Effect.SignOut", "Effect.SignOut"])
        let note = schema.transitions.filter { $0.name == "note" }
        #expect(note.map(\.from) == ["idle", "loaded"])
        #expect(note.map(\.payloadType) == ["String", "String"])
        // Any listed phase's qualified name spells the same effect type.
        _ = try Self.parse(Self.signOut.replacingOccurrences(of: "Effect.SignOut", with: "Effect.Loaded.SignOut"))
    }

    @Test func diagnosesMalformedSourceLists() throws {
        let failures: [(String, String)] = [
            (
                Self.signOut.replacingOccurrences(of: "func signOut()", with: "func signOut(_ source: Loading)"),
                "A transition that lists its source phases in from: takes no parameters."
            ),
            (
                Self.signOut.replacingOccurrences(of: "func note(_ text: String)", with: "func note()"),
                "A transition that lists its source phases in from: takes only the trigger payload parameter."
            ),
            (
                Self.signOut.replacingOccurrences(of: "from: [Idle.self, Loaded.self]", with: "from: []"),
                "List at least one source phase in from:."
            ),
            (
                Self.signOut.replacingOccurrences(of: "from: [Idle.self, Loaded.self]", with: "from: [Log.self]"),
                "'Log' is not a phase payload type declared in this schema."
            ),
            (
                Self.signOut.replacingOccurrences(
                    of: "@Transition(onSuccess: Log.self)",
                    with: "@Transition(from: [Idle.self], onSuccess: Log.self)"
                ),
                "Only an input transition lists its source phases in from:; a completion edge names its source in its first parameter."
            ),
            (
                Self.signOut.replacingOccurrences(
                    of: "from: [Idle.self, Loaded.self]",
                    with: "from: [Loaded.self, Loaded.self]"
                ),
                "Remove duplicate references from this metadata list."
            ),
            (
                // A listed phase that already has an edge of that name.
                Self.signOut.replacingOccurrences(
                    of: "@Transition(onSuccess: Log.self)",
                    with:
                        "@Transition(on: Input.note)\n    static func note(_ source: Loaded, _ text: String) -> Loaded { fatalError() }\n    @Transition(onSuccess: Log.self)"
                ),
                "'Loaded' already has an edge or router named 'note'; give each edge from one phase a distinct name."
            ),
        ]
        for (source, message) in failures {
            #expect(Self.diagnostics(source) == [message])
        }
        let owned = #"""
            @StateMachine(mode: .ownedOnly)
            enum Flow: ~Copyable {
                struct Idle: ~Copyable {}
                struct Done: ~Copyable {}
                @Initial case idle(Idle)
                case done(Done)
                enum Input { case finish }
                enum Problem: Error { case declined }
                @Transition(from: [Idle.self, Done.self], on: Input.finish)
                static func finish() -> Advance<Idle, Done, Never, Problem> { fatalError() }
            }
            """#
        #expect(
            Self.diagnostics(owned) == [
                "A transition that lists its source phases in from: has no one source to give back; return its destination or a Change."
            ]
        )
        let plain = try Self.parse(owned.replacingOccurrences(of: "Advance<Idle, Done, Never, Problem>", with: "Done"))
        #expect(plain.transitions.map(\.from) == ["idle", "done"])
    }

    // MARK: Value conformances

    @Test func valueConformancesFollowTheSchemaInheritanceClause() throws {
        #expect(try Self.parse(Self.archive).valueConformances.isEmpty)
        let equatable = Self.archive.replacingOccurrences(of: "enum Flow {", with: "enum Flow: Sendable, Equatable {")
        #expect(try Self.parse(equatable).valueConformances == ["Equatable"])
        let hashable = Self.archive.replacingOccurrences(of: "enum Flow {", with: "enum Flow: Swift.Hashable {")
        #expect(try Self.parse(hashable).valueConformances == ["Hashable"])
    }

    // MARK: Ownership

    static let attaching = #"""
        @StateMachine(mode: .ownedOnly)
        enum Flow: ~Copyable {
            struct Handle: ~Copyable {}
            struct Idle {}
            struct Attached: ~Copyable { var handle: Handle }
            @Initial case idle(Idle)
            @Terminal case attached(Attached)
            enum Input: ~Copyable { case attach(Handle) }
            @Transition(on: Input.attach)
            static func attach(_ source: consuming Idle, _ handle: OWNERSHIP Handle) -> Attached { fatalError() }
        }
        """#

    /// An `Owned` verb passes its payload on once, so it repeats the ownership the authored parameter
    /// declares as spelled, which a noncopyable payload needs, and the payload's witness only borrows the
    /// input it matches. `__owned` and `__shared` stay as spelled: they are legal where `consuming` and
    /// `borrowing` are not, on a nonescaping closure and with `sending`.
    @Test func anOwnedVerbRepeatsThePayloadsOwnership() throws {
        for (written, repeated) in [
            ("consuming", "consuming "), ("borrowing", "borrowing "), ("__owned", "__owned "),
            ("__shared", "__shared "),
        ] {
            let source = Self.attaching.replacingOccurrences(of: "OWNERSHIP", with: written)
            let schema = try Self.parse(source)
            #expect(schema.transitions.first?.payloadOwnership == repeated)
            let text = try Generator(schema: schema).members().map(\.description).joined(separator: "\n")
            #expect(text.contains("consuming func attach(_ input: \(repeated)Handle)"), "\(written)")
            #expect(text.contains("func witness(_ input: consuming Input)"))
            #expect(text.contains("_stateMachineInputPayload<Value: ~Swift::Copyable>(_ value: borrowing Value)"))
        }
    }

    /// Only `Owned` passes a noncopyable value on without copying it, so a noncopyable `Input` or schema
    /// with another owner is diagnosed where it is declared.
    @Test func aNoncopyableInputOrSchemaNeedsOwnedAlone() {
        let input = Self.attaching.replacingOccurrences(of: "OWNERSHIP", with: "consuming")
            .replacingOccurrences(of: "enum Flow: ~Copyable", with: "enum Flow")
            .replacingOccurrences(of: "struct Attached: ~Copyable { var handle: Handle }", with: "struct Attached {}")
            .replacingOccurrences(of: "mode: .ownedOnly", with: "mode: .isolated, owners: [.owned, .local]")
            .replacingOccurrences(of: "_ source: consuming Idle", with: "_ source: Idle")
        #expect(
            Self.diagnostics(input) == [
                "Input is noncopyable, which only Owned supports: '.local' keeps each input it routes until a transition accepts it; list only .owned in owners:, or make Input copyable."
            ]
        )
        #expect(
            Self.diagnostics(input.replacingOccurrences(of: "owners: [.owned, .local]", with: "owners: [.owned]"))
                == nil
        )
        let schema = Self.attaching.replacingOccurrences(of: "OWNERSHIP", with: "consuming")
            .replacingOccurrences(
                of: "enum Input: ~Copyable { case attach(Handle) }",
                with: "enum Input { case attach }"
            )
            .replacingOccurrences(of: ", _ handle: consuming Handle) -> Attached", with: ") -> Attached")
            .replacingOccurrences(of: "mode: .ownedOnly", with: "mode: .isolated, owners: [.owned, .mainActorHost]")
            .replacingOccurrences(of: "_ source: consuming Idle", with: "_ source: Idle")
        #expect(
            Self.diagnostics(schema) == [
                "The schema is noncopyable, which only Owned supports: '.mainActorHost' publishes snapshots that copy its phases; list only .owned in owners:, or make the schema and its phases copyable."
            ]
        )
    }
}
