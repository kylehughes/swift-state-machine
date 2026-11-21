import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

/// Runs the whole expansion over a matrix of type spellings, one of every kind of type syntax, in each
/// position an authored type can take, and checks that each either expands or is diagnosed, never
/// trapped on, with the classification its reading implies.
struct TypeSpellingMatrixTests {
    /// What the macro reads a spelling as, in a schema that declares the matrix's types.
    enum Reading: Equatable, Sendable {
        case void, never, visible, opaque
    }

    /// One spelling of the matrix: its text, its reading, and whether Swift accepts it as a type alias's
    /// target, which decides whether the positions that need a real type can accept it.
    struct Spelling: CustomStringConvertible, Sendable {
        let text: String
        let reading: Reading
        let isType: Bool
        var description: String { text }
        init(_ text: String, _ reading: Reading, isType: Bool = true) {
            self.text = text
            self.reading = reading
            self.isType = isType
        }
    }

    /// Every kind of `TypeSyntax`, and the spellings within each kind whose readings differ.
    static let spellings: [Spelling] = [
        // Identifiers, escaped identifiers, and generic specializations.
        Spelling("Item", .visible), Spelling("`Item`", .visible), Spelling("Int", .opaque),
        Spelling("Outside", .opaque), Spelling("Any", .visible), Spelling("Void", .void), Spelling("Never", .never),
        Spelling("Unit", .void), Spelling("`Unit`", .void), Spelling("Nothing", .never),
        Spelling("Identity<Item>", .visible), Spelling("Identity<Swift::Void>", .void),
        Spelling("Identity<Swift::Never>", .never), Spelling("Identity<Nothing>", .never),
        Spelling("Box<Item>", .visible), Spelling("Array<Item>", .visible), Spelling("Optional<Never>", .visible),
        Spelling("Identity", .opaque, isType: false), Spelling("Unit<Int>", .opaque, isType: false),
        Spelling("Many<Never>", .opaque), Spelling("_", .opaque, isType: false),
        // Module selectors.
        Spelling("Swift::Int", .visible), Spelling("Swift::Void", .void), Spelling("Swift::Never", .never),
        Spelling("Swift::Array<Item>", .visible), Spelling("Foundation::Data", .opaque, isType: false),
        // Members.
        // `Self` names the schema here, and an operation or event namespace inside one.
        Spelling("Flow.Item", .visible), Spelling("Self.Item", .visible, isType: false),
        Spelling("Swift.Int", .visible),
        Spelling("Swift.Void", .void), Spelling("Swift.Never", .never), Spelling("Values.Value", .visible),
        Spelling("(Values).Value", .visible), Spelling("NS.Value", .visible), Spelling("NS.Unit", .void),
        Spelling("[Int].Element", .opaque), Spelling("Item?.Wrapped", .opaque), Spelling("Outside.Member", .opaque),
        Spelling("Box<Item>.Member", .opaque, isType: false), Spelling("Values.Missing", .opaque, isType: false),
        // Collections, optionals, and inline arrays.
        Spelling("[Item]", .visible), Spelling("[Item: Item]", .visible), Spelling("Item?", .visible),
        Spelling("Item!", .visible, isType: false), Spelling("[2 of Item]", .visible), Spelling("[Never]", .visible),
        // Tuples.
        Spelling("()", .void), Spelling("(())", .void), Spelling("(Never)", .never), Spelling("(Item)", .visible),
        Spelling("(Item, Item)", .visible), Spelling("(first: Item, second: Item)", .visible),
        Spelling("(x: Item)", .visible, isType: false), Spelling("(Never, Item)", .visible),
        // Functions and attributed types.
        Spelling("() -> Item", .visible), Spelling("@Sendable () -> Item", .visible),
        Spelling("(Item) async throws(Problem) -> Item", .visible), Spelling("@MainActor () -> Void", .visible),
        Spelling("@escaping @Sendable () -> Item", .visible, isType: false),
        Spelling("inout Item", .visible, isType: false),
        Spelling("sending Item", .visible, isType: false), Spelling("borrowing Item", .visible, isType: false),
        Spelling("consuming Item", .visible, isType: false), Spelling("@convention(c) () -> Void", .visible),
        // Existentials, opaque types, compositions, metatypes, packs, and suppressed conformances.
        Spelling("any Error", .visible), Spelling("some Sendable", .visible, isType: false),
        Spelling("any Error & Sendable", .visible), Spelling("Item.Type", .visible),
        Spelling("any Error.Type", .visible),
        Spelling("repeat each T", .visible, isType: false), Spelling("each T", .visible, isType: false),
        Spelling("~Copyable", .visible, isType: false), Spelling("P.Type", .visible),
        Spelling("(() -> Item).Type", .visible), Spelling("() -> Item.Type", .visible),
        // An escaped `Type` declares the name a bare `Type` looks up where no period precedes it.
        Spelling("Type", .never), Spelling("Kinds.`Type`", .void),
        // A spelling that does not parse as a type.
        Spelling("", .opaque, isType: false),
    ]

    /// The spellings whose readings the macro confirms when an operation or event namespace, or
    /// `Input`, spells them: those that name no type through a name the namespace does not declare, the
    /// schema's own name included, so no member an extension, a superclass, or a protocol extension
    /// gives the namespace could hide one.
    static let confirmedInNamespace: Set<String> = [
        "Any", "Swift::Int", "Swift::Void", "Swift::Never", "Foundation::Data", "Self.Item", "()", "(())", "_", "",
    ]

    /// The message of the check the expansion makes of `reference` in place of a diagnostic the macro
    /// gives only for a reading it confirms.
    static func checkMessage(_ schema: Schema?, at reference: String) -> String? {
        for check in schema?.typeChecks ?? [] where check.reference == reference {
            switch check.kind {
            case .isNotNever(let message?), .isStandard(_, let message?), .casePayloadIsNotNever(let message),
                .finishes(let message):
                return message
            default: continue
            }
        }
        return nil
    }

    /// The spellings whose readings the macro cannot confirm at the schema's scope: each reads a bare
    /// standard-library name or a free `Swift` as the standard library's.
    static let unconfirmedInSchema: Set<String> = [
        "Void", "Never", "Unit", "`Unit`", "Array<Item>", "Optional<Never>", "Many<Never>", "Swift.Int", "Swift.Void",
        "Swift.Never", "[Never]", "(Never)", "(Never, Item)", "@MainActor () -> Void", "@convention(c) () -> Void",
        "any Error", "any Error & Sendable", "any Error.Type",
    ]

    /// The spellings whose structure decides what kind of type they are, whatever the types inside them
    /// name: a tuple of several elements, a function, sugar, a composition, a metatype, and a standard
    /// library type named through its module are neither `Void` nor `Never` and are function types
    /// exactly when they are spelled as one.
    static let structural: Set<String> = [
        "[Item]", "[Item: Item]", "Item?", "[2 of Item]", "[Never]", "(Item, Item)", "(first: Item, second: Item)",
        "(Never, Item)", "() -> Item", "@Sendable () -> Item", "(Item) async throws(Problem) -> Item",
        "@MainActor () -> Void", "@convention(c) () -> Void", "any Error & Sendable", "Item.Type", "any Error.Type",
        "P.Type", "(() -> Item).Type", "() -> Item.Type", "Swift::Array<Item>",
    ]

    /// Whether the macro confirms what kind of type `text` is when a namespace or `Input` spells it,
    /// which every conclusion about the generated shape rests on.
    static func confirmsKindInNamespace(_ text: String) -> Bool {
        confirmedInNamespace.contains(text) || structural.contains(text)
    }

    /// Whether the macro confirms what kind of type `text` is at the schema's scope.
    static func confirmsKindInSchema(_ text: String) -> Bool {
        !unconfirmedInSchema.contains(text) || structural.contains(text)
    }

    /// Whether the expansion checks that an operation's or event's alias of `spelling` is not `Never`:
    /// it names a type the macro cannot see into, or one with values whose kind it cannot confirm.
    static func probesInNamespace(_ spelling: Spelling) -> Bool {
        spelling.reading == .opaque || spelling.reading == .visible && !confirmsKindInNamespace(spelling.text)
    }

    /// The schema the matrix fills in: `DECLARATIONS` names the types the spellings use.
    static let declarations = """
        struct Item {}
        struct Box<T> {}
        enum Problem: Error { case bad }
        typealias Unit = Void
        typealias Nothing = Swift::Never
        typealias Identity<T> = T
        typealias Many<each T> = (repeat each T)
        enum Values { typealias Value = Swift::Int; typealias Unit = () }
        typealias NS = (Values)
        protocol P {}
        typealias `Type` = Swift::Never
        enum Kinds { typealias `Type` = () }
        """

    static func schema(
        aliases: String = "",
        inputs: String = "",
        events: String = "",
        edges: String = "",
        success: String = "static func done(_ source: Running) -> Idle { fatalError() }",
        phases: String = ""
    ) -> String {
        """
        @StateMachine(mode: .shared)
        enum Flow {
            \(declarations)
            struct Idle {}
            struct Running {}
            @Initial case idle(Idle)
            case running(Running)
            \(phases)
            enum Input { case go, back, refuse\(inputs) }
            @Operation(activeIn: [Running.self])
            enum Load { \(aliases) }
            \(events)
            @Transition(on: Input.go, starts: [Load.self])
            static func go(_ source: Idle) -> Change<Running, Effect.Go> { fatalError() }
            @Transition(onSuccess: Load.self)
            \(success)
            @Transition(on: Input.back)
            static func back(_ source: Running) -> Idle { fatalError() }
            \(edges)
        }
        """
    }

    /// The result of one expansion: its schema and text, or the macro's diagnostics.
    enum Outcome {
        case expanded(Schema, String)
        case diagnosed([String])

        var schema: Schema? { if case .expanded(let schema, _) = self { schema } else { nil } }
        var text: String? { if case .expanded(_, let text) = self { text } else { nil } }
        var messages: [String] { if case .diagnosed(let messages) = self { messages } else { [] } }
    }

    /// Parses and generates `source`; any error other than the macro's diagnostics fails the test.
    static func expand(_ source: String) -> Outcome {
        do {
            let schema = try DeclarationHygieneTests.parse(source)
            let text = try Generator(schema: schema).members().map(\.description).joined(separator: "\n")
            return .expanded(schema, text)
        } catch let error as DiagnosticsError {
            return .diagnosed(error.diagnostics.map(\.message))
        } catch {
            Issue.record("Unexpected error \(error)")
            return .diagnosed([])
        }
    }

    // MARK: The resolver

    @Test(arguments: spellings)
    func everySpellingHasTheReadingItsKindGives(_ spelling: Spelling) throws {
        let scopes = try DeclarationHygieneTests.parse(Self.schema()).typeScopes
        let resolved = scopes.resolve(spelling.text)
        let reading: Reading =
            switch resolved.reading {
            case .void: .void
            case .never: .never
            case .visible: .visible
            case .opaque: .opaque
            }
        #expect(reading == spelling.reading)
        #expect(resolved.isConfirmed == !Self.unconfirmedInSchema.contains(spelling.text))
        #expect(resolved.confirmsShape == (spelling.reading != .opaque && Self.confirmsKindInSchema(spelling.text)))
    }

    // MARK: Operation aliases

    @Test(arguments: spellings)
    func anOutputIsClassifiedByItsReading(_ spelling: Spelling) {
        let parameter = spelling.reading == .void ? "" : ", _ value: Load.Output"
        let outcome = Self.expand(
            Self.schema(
                aliases: "typealias Output = \(spelling.text); typealias Failure = Problem",
                edges:
                    "@Transition(onFailure: Load.self)\nstatic func broke(_ source: Running, _ failure: Problem) -> Idle { fatalError() }",
                success: "static func done(_ source: Running\(parameter)) -> Idle { fatalError() }"
            )
        )
        switch spelling.reading {
        case .never where Self.confirmsKindInNamespace(spelling.text):
            #expect(outcome.messages.first?.hasPrefix("Operation 'Load' never succeeds") == true)
        case .never:
            // The success edge says the operation succeeds, so an unconfirmed `Never` is checked instead.
            #expect(outcome.schema?.operations.first?.neverSucceeds == false)
            #expect(
                Self.checkMessage(outcome.schema, at: "Load.Output")?.hasPrefix("Operation 'Load' never succeeds")
                    == true
            )
        case .void:
            #expect(outcome.schema?.operations.first?.producesVoid == true)
            let checked = outcome.schema?.standardNameChecks.contains { $0.reference == "Load.Output" }
            #expect(checked == !Self.confirmsKindInNamespace(spelling.text))
        case .visible, .opaque:
            guard spelling.isType else { return }
            let operation = outcome.schema?.operations.first
            #expect(operation?.producesVoid == false && operation?.neverSucceeds == false)
            #expect(outcome.schema?.neverProbes.contains("Load.Output") == Self.probesInNamespace(spelling))
        }
    }

    @Test(arguments: spellings)
    func aFailureIsClassifiedByItsReading(_ spelling: Spelling) {
        let outcome = Self.expand(
            Self.schema(
                aliases: "typealias Failure = \(spelling.text)",
                edges:
                    "@Transition(onFailure: Load.self)\nstatic func broke(_ source: Running, _ failure: Load.Failure) -> Idle { fatalError() }"
            )
        )
        switch spelling.reading {
        case .never where Self.confirmsKindInNamespace(spelling.text):
            #expect(outcome.messages.first?.hasPrefix("Operation 'Load' cannot fail") == true)
        case .never:
            // The failure edge says the operation fails, so an unconfirmed `Never` is checked instead.
            #expect(outcome.schema?.operations.first?.isInfallible == false)
            #expect(
                Self.checkMessage(outcome.schema, at: "Load.Failure")?.hasPrefix("Operation 'Load' cannot fail") == true
            )
        default:
            guard spelling.isType else { return }
            #expect(outcome.schema?.operations.first?.isInfallible == false)
            #expect(outcome.text?.contains("canFail: true") == true)
            let probed =
                Self.probesInNamespace(spelling)
                || spelling.reading == .void && !Self.confirmsKindInNamespace(spelling.text)
            #expect(outcome.schema?.neverProbes.contains("Load.Failure") == probed)
        }
    }

    @Test(arguments: spellings)
    func anInputOrKeyIsClassifiedByItsReading(_ spelling: Spelling) {
        for alias in ["Input", "Key"] {
            let outcome = Self.expand(Self.schema(aliases: "typealias \(alias) = \(spelling.text)"))
            if spelling.reading == .never {
                let message = "Operation 'Load' takes Never as its"
                if Self.confirmsKindInNamespace(spelling.text) {
                    #expect(outcome.messages.first?.hasPrefix(message) == true, "\(alias)")
                } else {
                    #expect(
                        Self.checkMessage(outcome.schema, at: "Load.\(alias)")?.hasPrefix(message) == true,
                        "\(alias)"
                    )
                }
                continue
            }
            guard spelling.isType else { continue }
            let operation = outcome.schema?.operations.first
            if alias == "Input" {
                #expect(operation?.takesInput == (spelling.reading != .void))
            } else {
                #expect(operation?.isKeyed == true)
            }
            // An input read as `Void` without confirming it is checked to be `Void`; every other reading the
            // macro cannot confirm, a key's `Void` included, is checked not to be `Never`.
            let unconfirmedVoid = spelling.reading == .void && !Self.confirmsKindInNamespace(spelling.text)
            let probed = outcome.schema?.neverProbes.contains("Load.\(alias)")
            #expect(
                probed == (Self.probesInNamespace(spelling) || alias == "Key" && unconfirmedVoid),
                "\(alias)"
            )
            let checksVoid = outcome.schema?.standardNameChecks.contains { $0.reference == "Load.\(alias)" }
            #expect(checksVoid == (alias == "Input" && unconfirmedVoid), "\(alias)")
        }
    }

    // MARK: Events and inputs

    @Test(arguments: spellings)
    func anEventPayloadIsClassifiedByItsReading(_ spelling: Spelling) {
        let outcome = Self.expand(
            Self.schema(
                events: "@Event enum Tracked { typealias Payload = \(spelling.text) }",
                edges:
                    "@Transition(on: Input.refuse, emits: [Tracked.self])\nstatic func refuse(_ source: Idle) -> Change<Idle, Effect.Refuse> { fatalError() }"
            )
        )
        if spelling.reading == .never {
            let message = "Event 'Tracked' carries Never"
            if Self.confirmsKindInNamespace(spelling.text) {
                #expect(outcome.messages.first?.hasPrefix(message) == true)
            } else {
                #expect(Self.checkMessage(outcome.schema, at: "Tracked.Payload")?.hasPrefix(message) == true)
            }
            return
        }
        guard spelling.isType else { return }
        #expect(outcome.schema?.events.first?.takesPayload == (spelling.reading != .void))
        #expect(outcome.schema?.neverProbes.contains("Tracked.Payload") == Self.probesInNamespace(spelling))
    }

    @Test(arguments: spellings)
    func anInputCasePayloadAndTheParameterThatTakesItExpandOrAreDiagnosed(_ spelling: Spelling) {
        let outcome = Self.expand(
            Self.schema(
                inputs: ", send(\(spelling.text))",
                edges:
                    "@Transition(on: Input.send)\nstatic func send(_ source: Idle, _ value: \(spelling.text)) -> Idle { fatalError() }"
            )
        )
        if spelling.reading == .never {
            let message = "Input case 'send' carries Never"
            if Self.confirmsKindInNamespace(spelling.text) {
                #expect(outcome.messages.first?.hasPrefix(message) == true)
            } else {
                // `Input` resolves the payload, so the check reads it from a pattern of its case.
                #expect(Self.checkMessage(outcome.schema, at: "send")?.hasPrefix(message) == true)
                #expect(outcome.text?.contains("case .send(let bound):") == true)
                #expect(outcome.text?.contains("_stateMachineCasePayload(bound)") == true)
            }
            return
        }
        guard spelling.isType else { return }
        // The witness infers the case's payload from a pattern of its case alone, where `Input` resolves
        // it, and compares the parameter with it in a statement of its own.
        let text = outcome.text?.replacingOccurrences(of: "\n", with: " ")
        #expect(text?.contains("case .send(let bound):") == true)
        #expect(text?.contains("let payload = _stateMachineInputPayload(bound)") == true)
        #expect(text?.contains("let _: _TriggerPayloadMatchesDeclaration<") == true)
    }

    // MARK: Signatures

    @Test(arguments: spellings)
    func aReducerParameterKeepsItsConventionOnlyOnGeneratedParameters(_ spelling: Spelling) {
        let outcome = Self.expand(
            Self.schema(
                inputs: ", send(@Sendable () -> Item)",
                edges:
                    "@Transition(on: Input.send)\nstatic func send(_ source: Idle, _ value: \(spelling.text)) -> Idle { fatalError() }"
            )
        )
        guard let text = outcome.text else { return }
        // A witness or alias never repeats a parameter-only attribute or specifier.
        for convention in ["<@escaping", "<inout", "<borrowing", "<consuming", "<sending", "= @escaping", "= sending"] {
            #expect(!text.contains(convention), "\(convention)")
        }
    }

    @Test(arguments: spellings)
    func aThrowsClauseIsClassifiedByItsReading(_ spelling: Spelling) {
        let outcome = Self.expand(
            Self.schema(
                edges:
                    "@Transition(on: Input.refuse)\nstatic func refuse(_ source: Idle) throws(\(spelling.text)) -> Idle { fatalError() }"
            )
        )
        guard let schema = outcome.schema else {
            #expect(!spelling.isType || spelling.text.isEmpty, "\(outcome.messages)")
            return
        }
        let edge = schema.transitions.first { $0.name == "refuse" }
        #expect((edge?.failureType == nil) == (spelling.reading == .never))
        // A type thrown at the schema's scope is checked when the macro reads it as one with values
        // without confirming it, and as `Never` when it reads `Never` without confirming it.
        let unconfirmed = !Self.confirmsKindInSchema(spelling.text)
        let probed = spelling.reading == .opaque || spelling.reading != .never && unconfirmed
        // Parentheses change no type, so the check is made of the spelling inside them.
        let checked = TypeSyntax(stringLiteral: spelling.text).unparenthesized.trimmedDescription
        #expect(schema.neverProbes.contains(checked) == probed)
        let never = spelling.reading == .never && !Self.confirmsKindInSchema(spelling.text)
        #expect(schema.standardNameChecks.contains { $0.reference == checked } == never)
    }

    @Test(arguments: spellings)
    func aRouterResultIsAChoiceOrNeverAndNothingElse(_ spelling: Spelling) {
        let outcome = Self.expand(
            Self.schema(
                edges:
                    "@Route(on: Input.refuse)\nstatic func refuse(_ source: Idle) throws(Problem) -> \(spelling.text) { fatalError() }"
            )
        )
        let message = "A router with no edge to choose returns Never and throws a typed rejection."
        if spelling.reading == .never {
            #expect(outcome.schema?.routes.first?.choices == [])
        } else if spelling.reading == .opaque || !Self.confirmsKindInSchema(spelling.text) {
            // A result the macro cannot confirm is no `Never` is checked to be one, with the diagnostic.
            #expect(outcome.schema == nil || Self.checkMessage(outcome.schema, at: spelling.text) == message)
        } else {
            #expect(outcome.messages.contains(message) || outcome.schema == nil)
        }
    }

    @Test(arguments: spellings)
    func anEffectArgumentOtherThanTheEdgesEffectIsDiagnosed(_ spelling: Spelling) {
        let outcome = Self.expand(
            Self.schema()
                .replacingOccurrences(of: "Change<Running, Effect.Go>", with: "Change<Running, \(spelling.text)>")
        )
        #expect(outcome.schema == nil)
    }

    @Test(arguments: spellings)
    func aPhasePayloadIsANominalTypeTheSchemaDeclares(_ spelling: Spelling) {
        let outcome = Self.expand(Self.schema(phases: "case extra(\(spelling.text))"))
        // A nominal payload makes a phase, which no transition reaches; every other type is no phase. A
        // spelling that is no type leaves the compiler to reject the case.
        #expect(outcome.schema == nil)
        let nominal = ["Item", "`Item`", "Flow.Item", "Self.Item", "(Item)"].contains(spelling.text)
        let unreachable = outcome.messages.contains { $0.hasPrefix("Phase 'extra' is unreachable") }
        #expect(unreachable == nominal || !spelling.isType, "\(outcome.messages)")
    }
}
