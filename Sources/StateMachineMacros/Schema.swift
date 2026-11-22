import SwiftDiagnostics
import SwiftParser
import SwiftSyntax

/// The lexical schema consumed by generation; semantic type relationships are compiler witnesses.
struct Schema {
    struct Phase {
        let caseName: String
        /// The name of the payload type the schema declares, however the case spells it.
        let typeName: String
        /// The payload's spelling as the graph shows it: the case's own text, which means what it means
        /// inside the schema.
        let payloadSpelling: String
        /// Whether the phase is marked `@Terminal`.
        let isTerminal: Bool
    }

    struct Case {
        let caseName: String
        /// The payload's spelling as the graph shows it (``Schema/displaySpelling(_:)``), which means what
        /// it means inside the enum that declares the case: the schema for a phase, `Input` for an input.
        let payloadType: String?
        /// The payload's authored syntax, which every reading of its meaning uses.
        let payload: TypeSyntax?
        /// The declared default construction, spelled through the schema's alias so it resolves in every
        /// generated owner.
        var defaultValue: String?
    }

    enum Mode: String {
        case shared
        case isolated
        case ownedOnly
    }

    /// An owner the schema generates.
    enum Owner: String, CaseIterable {
        case owned
        case local
        case shared
        case actorHost
        case mainActorHost
        case isolatedHost

        /// The owners a mode generates when the schema does not list them.
        static func supported(by mode: Mode) -> [Owner] {
            switch mode {
            case .shared: allCases
            case .isolated: [.owned, .local, .mainActorHost, .isolatedHost]
            case .ownedOnly: [.owned]
            }
        }
    }

    enum Access: String {
        case `public`
        case package
        case `internal`
        case `fileprivate`
        case `private`
    }

    struct Trigger: Hashable {
        enum Kind: String, Hashable {
            case input
            case success
            case failure
            /// A direct call on an owned phase, in an `.ownedOnly` schema; the name is the function's.
            case direct
        }

        let kind: Kind
        let name: String
    }

    enum Admission: Equatable {
        case latest
        case rejectWhenActive
        case parallel(limit: Int)

        /// The most starts of one operation that a single plan may contain.
        var maxNewIntents: Int {
            switch self {
            case .latest, .rejectWhenActive: 1
            case .parallel(let limit): limit
            }
        }
    }

    struct Operation {
        let name: String
        let effect: String
        /// The named primary scope, or `nil` for the private scope of an operation that names none.
        let scope: String?
        let requires: [String]
        /// The phases in which the operation may run, in declaration order: those of its primary scope
        /// that are also phases of every required scope.
        let activeIn: [String]
        /// The phases the operation's `activeIn:` lists for its private scope, or `nil` when it names a scope.
        let privatePhases: [String]?
        let admission: Admission
        /// The declared input spelling, `Swift::Void` when the namespace declares no `Input` alias.
        let inputType: String
        /// The declared output spelling, `Swift::Void` when the namespace declares no `Output` alias.
        let outputType: String
        /// The declared failure spelling as the author wrote it, `Swift::Never` when the namespace
        /// declares no `Failure` alias; ``isInfallible`` says whether it names the standard library's `Never`.
        let failureType: String
        /// Whether the namespace declares an `Input` alias.
        let declaresInput: Bool
        /// Whether the namespace declares an `Output` alias.
        let declaresOutput: Bool
        /// Whether the namespace declares a `Failure` alias.
        let declaresFailure: Bool
        /// The declared key spelling of a keyed operation, or `nil` when the namespace declares no `Key` alias.
        let keyType: String?
        /// Whether the operation takes an input, so its effect case, work, and driver carry one.
        ///
        /// The parser decides it from the type the `Input` alias names where it is declared, reading
        /// through the aliases the schema and the namespace declare, so a schema that declares its own
        /// `Void` type keeps an input of that type.
        let takesInput: Bool
        /// Whether the operation produces no value, so its work seals success without an argument.
        let producesVoid: Bool
        /// Whether the operation cannot fail, so its driver returns the output itself: its `Failure` is
        /// omitted or names the standard library's `Never`.
        let isInfallible: Bool
        /// Whether the operation's `Output` names the standard library's `Never`, so it never succeeds
        /// and has no success edge or router.
        let neverSucceeds: Bool
        /// Whether the macro confirms that the `Input` is a function type, so a driver receives it
        /// `@escaping` and can keep it; otherwise a driver receives it as it is.
        var inputEscapes = false

        /// The primary scope's key: the named case, or a private key that no authored reference can spell.
        var scopeKey: String { scope ?? "\(name).self" }
        /// The input type as generated code spells it; an undeclared alias is never referenced.
        var input: String { declaresInput ? "\(name).Input" : "Swift::Void" }
        /// The output type as generated code spells it; an undeclared alias is never referenced.
        var output: String { declaresOutput ? "\(name).Output" : "Swift::Void" }
        /// The failure type as generated code spells it; an undeclared alias is never referenced.
        var failure: String { declaresFailure ? "\(name).Failure" : "Swift::Never" }
        /// Whether the operation declares a `Key`, so admission applies its policy to each key.
        var isKeyed: Bool { keyType != nil }
        /// The key type as generated code spells it, for a keyed operation.
        var key: String { "\(name).Key" }
        /// Whether the operation has a request: a key, an input, or both.
        var hasRequest: Bool { isKeyed || takesInput }
        /// The generated request type: `Download` to `DownloadRequest`.
        var request: String { "\(name)Request" }
        /// The work type of `Local`: `Download` to `DownloadWork`.
        var work: String { "\(name)Work" }
        /// The generic struct the work of an operation that can succeed specializes: `_DownloadWork`.
        var workStorage: String { "_\(name)Work" }
        /// The effect case that cancels one key's work: `Download` to `cancelDownload`.
        var cancelEffect: String { "cancel\(name)" }
        /// The effect case that cancels every key's work: `Download` to `cancelAllDownload`.
        var cancelAllEffect: String { "cancelAll\(name)" }
    }

    struct Event {
        let name: String
        let effect: String
        /// The declared payload spelling, `Swift::Void` when the namespace declares no `Payload` alias.
        let payloadType: String
        /// Whether the namespace declares a `Payload` alias.
        let declaresPayload: Bool
        /// Whether the event carries a payload, so its effect case, command, and handler take one; a
        /// schema that declares its own `Void` type keeps a payload of that type.
        let takesPayload: Bool

        /// The payload type as generated code spells it inside the schema.
        var payload: String { declaresPayload ? "\(name).Payload" : "Swift::Void" }
        /// The label of a managed owner's handler for it: `Tracked` to `onTracked`.
        var handler: String { "on\(name)" }
    }

    struct Transition {
        /// How the authored function spells its result.
        enum Shape {
            /// The destination payload itself; the edge starts nothing.
            case destination
            /// `Change<Destination, Effect.Edge>`.
            case change
            /// `Advance<Source, Destination, Effect, Failure>`, the owned-only fallible form.
            case advance
        }

        let name: String
        let from: String
        let to: String
        let trigger: Trigger
        let invalidates: [String]
        let starts: [String]
        /// The effect cases of the keyed operations whose work the edge may cancel, in the order `cancels:` lists them.
        let cancels: [String]
        /// The effect cases of the events the edge may emit, in the order `emits:` lists them.
        let emits: [String]
        /// The trigger payload's type, without the passing convention of the authored parameter.
        var payloadType: String?
        /// The passing convention generated parameters repeat for the payload, such as `@escaping `, or empty.
        var payloadConvention = ""
        /// The ownership the authored parameter declares for the payload as spelled, `borrowing `,
        /// `consuming `, `__shared `, or `__owned `, or empty; generated parameters that pass the payload on
        /// once repeat it.
        var payloadOwnership = ""
        /// The authored source parameter type, or `nil` for a transition that lists its sources in `from:`.
        let sourceType: String?
        let returnType: String
        var failureType: String?
        let shape: Shape
        /// The generated companion name of this edge's effect type, when it starts operations: `begin` to `Begin`.
        let effectNamespace: String?
        /// The position of the authored function among the schema's members.
        let declaration: Int
        /// The source phases of the authored function in declaration order: its source parameter's phase, or
        /// every phase it lists in `from:`, each of which has an edge of its own.
        let sources: [String]
        /// The authored spelling of a completion edge's `request:` parameter, its operation's request.
        let requestType: String?
        /// The passing convention generated parameters repeat for the request, such as `sending `, or empty.
        var requestConvention = ""

        /// Whether a completion edge takes its operation's request.
        var takesRequest: Bool { requestType != nil }
        /// Whether the authored function takes the source payload.
        var takesSource: Bool { sourceType != nil }
        /// The authored function's deprecation.
        var deprecation: Deprecation?
    }

    /// The deprecation of an authored edge, router, or restoration function, which each generated public
    /// member named for the function repeats.
    ///
    /// Generated code that is not itself deprecated calls the function through a requirement of a protocol
    /// the expansion declares, which a deprecated member of a type it declares witnesses, so the call draws
    /// no deprecation warning.
    struct Deprecation {
        /// The authored attribute, `@available(*, deprecated)` with any `message:` and `renamed:`, as written.
        let attribute: String
        /// The function's declaration with numbered parameters and `Self` spelled as the schema, as the
        /// requirement and its witness declare it.
        let declaration: String
        /// Whether the function declares `throws`.
        let declaresThrows: Bool
        /// The witness's call of the authored function with its parameters.
        let call: String
        /// The contents of the `renamed:` string, with the literal a refusal of it stands at.
        let renamed: (name: String, literal: Syntax)?
    }

    struct Route {
        let name: String
        let from: String
        let trigger: Trigger
        let sourceType: String
        /// The trigger payload's type, without the passing convention of the authored parameter.
        var payloadType: String?
        /// The passing convention generated parameters repeat for the payload, such as `@escaping `, or empty.
        var payloadConvention = ""
        /// The ownership the authored parameter declares for the payload as spelled, `borrowing `,
        /// `consuming `, `__shared `, or `__owned `, or empty.
        var payloadOwnership = ""
        var failureType: String?
        /// The failure type the author pinned with `failure:`, spelled so it resolves inside the schema.
        var pinnedFailure: String?
        /// The generated `Route.<Namespace>` this router returns, when it has edges to choose.
        let namespace: String?
        /// The candidate edge names in declaration order.
        let choices: [String]
        /// The position of the authored function among the schema's members.
        let declaration: Int
        /// The authored spelling of a completion router's `request:` parameter, its operation's request.
        let requestType: String?
        /// The passing convention generated parameters repeat for the request, such as `sending `, or empty.
        var requestConvention = ""

        /// Whether a completion router takes its operation's request.
        var takesRequest: Bool { requestType != nil }
        /// The authored function's deprecation.
        var deprecation: Deprecation?
    }

    /// The authored function that validates saved data into a restorable phase.
    struct Restoration {
        let name: String
        /// The saved data type, spelled so it resolves outside the schema.
        var archiveType: String
        /// The passing convention generated parameters repeat for the saved data, such as `sending `, or empty.
        var archiveConvention = ""
        /// The typed failure, spelled so it resolves outside the schema.
        var failureType: String?
        /// The phase cases listed in `allows:`, restorable in addition to the resting phases.
        let allows: [String]
        /// The phase cases listed in `only:`, which are exactly the restorable phases.
        let only: [String]?
        /// The authored function's deprecation.
        var deprecation: Deprecation?

        /// The saved data as a generated parameter declares it: its passing convention, then its type.
        ///
        /// Saved data is copyable, as `LocalStateMachine`'s `RestorationArchive` is, so its ownership gives
        /// way to a plain parameter.
        var archiveParameter: String { archiveConvention + archiveType }
    }

    let name: String
    let access: Access
    let mode: Mode
    let initial: String
    /// The declared default construction of the initial payload, spelled through the schema's alias so it
    /// resolves in every generated owner.
    let initialDefault: String?
    let scopes: [String]
    /// The phases each `Scope` case marked `@Active(in:)` lists; an unmarked case spans every phase.
    let scopeActiveIn: [String: [String]]
    let phases: [Phase]
    let inputs: [Case]
    let operations: [Operation]
    let events: [Event]
    var transitions: [Transition] { didSet { tablesMemo = TablesMemo() } }
    var routes: [Route] { didSet { tablesMemo = TablesMemo() } }
    var restoration: Restoration?
    /// The value conformances the schema's inheritance clause lists, `Equatable` and `Hashable`, which
    /// its generated effects and restoration repeat.
    let valueConformances: [String]
    /// The types declared directly inside the schema, which generated namespaces may shadow.
    let typeNames: Set<String>
    /// The owners the schema generates.
    let owners: Set<Owner>
    /// The schema-level aliases generated code spells authored types through, set by
    /// ``shieldingAuthoredSpellings()``.
    var spellingAliases: [(alias: String, spelling: String)] = []
    /// The spelling each of ``spellingAliases`` stands for, by the alias, the first where two coincide.
    var spellingAliasTargets: [String: String] = [:]
    /// The declarations the macro reads authored spellings through.
    var typeScopes = LexicalScopes()
    /// The syntax of each stored spelling, parsed at most once.
    var spellings = SpellingSyntax()
    /// Every identifier the schema's source spells, which no generated alias may take.
    var authoredIdentifiers: Set<String> = []
    /// The checks the expansion makes of the conclusions the macro drew from readings it cannot
    /// confirm, in declaration order.
    var typeChecks: [TypeCheck] = []
    /// The ``tables`` of the schema, computed once when first read; replacing the transitions or the routes
    /// replaces the memo, so a copy that changes them never reads another's.
    var tablesMemo = TablesMemo()
    /// Where the parser's drafts of the schema, the schema, and every copy of it count their ``work``.
    var workCounter = WorkCounter()

    /// A check the expansion makes, at the schema's scope, of one conclusion the macro drew from a
    /// reading it cannot confirm, or that only the compiler can decide.
    struct TypeCheck: Hashable {
        enum Kind: Hashable {
            /// The type is the standard library's type of this name, which the macro read it as: `Void`
            /// or `Never`. A message, when present, replaces the one that says so.
            case isStandard(String, message: String? = nil)
            /// The type is not `Never`, which the macro read as a type with values. A message, when
            /// present, replaces the one that says so.
            case isNotNever(message: String? = nil)
            /// The `Input` case of this name carries a payload other than `Never`.
            case casePayloadIsNotNever(message: String)
            /// The operation of this name can finish: its `Output` and `Failure` are not both `Never`.
            case finishes(message: String)
            /// The schema conforms to the standard library's protocol of this name, `Equatable` or
            /// `Hashable`, which its inheritance clause names and generated types repeat.
            case conformsToStandard(String)
            /// The type is `Sendable`, because generated code passes a value of it to a `sending`
            /// parameter while it keeps the value or passes it on again.
            case isSendable
            /// The type is `Sendable`, because an `Owned` router's method gives a value of it away while
            /// it still passes the value on, for the reason named.
            case sharedAfterRouter(RoutedShare)
            /// The type, or the type named here, is `Sendable`, because an `Owned` router reads a value
            /// of the type with the other, which joins the two, and then passes the value to an edge
            /// that takes it as `sending` while the other is still in use: the router's source phase, or
            /// another value the router reads.
            case transfersAfterRouter(other: String, joined: RoutedJoin)
        }

        /// Why an `Owned` router's method would give a value away while it still passes it on.
        enum RoutedShare: Hashable, CaseIterable {
            /// The router takes the value as `sending`, and an edge it selects takes it after.
            case routerSends
            /// One edge the router may select takes the value as `sending`, and another without.
            case edgesDiffer
        }

        /// What an `Owned` router joins a value with before an edge it selects takes the value as `sending`.
        enum RoutedJoin: Hashable, CaseIterable {
            /// The router's source phase.
            case source
            /// Another value the router reads, its payload or its operation's request.
            case value
        }

        let kind: Kind
        /// What the check names at the schema's scope: an operation's or event's alias, such as
        /// `Load.Output`, a type as authored, `Self` for the schema, an `Input` case's name for its
        /// payload, or an operation's name.
        let reference: String
    }

    /// Whether the schema generates `owner`.
    func generates(_ owner: Owner) -> Bool { owners.contains(owner) }
    /// Whether the schema generates an owner other than `Owned`, which observes snapshots and admits candidates.
    var generatesObservingOwner: Bool { owners.contains { $0 != .owned } }
    /// Whether the schema generates a managed owner, which executes work and processes batches itself.
    var generatesManagedOwner: Bool {
        owners.contains { [.shared, .actorHost, .mainActorHost, .isolatedHost].contains($0) }
    }

    /// The phases in which the scope with this key stays active, in declaration order: a named
    /// scope's `@Active(in:)` phases or every phase, or the `activeIn:` phases of a private scope.
    func scopePhases(_ key: String) -> [String] {
        workCounter.work.scopeLookups += 1
        return tables.scopePhases[key] ?? []
    }

    /// The identifier of the scope with this key: its position in ``scopeKeys``.
    func scopeIndex(_ key: String) -> Int? {
        workCounter.work.scopeLookups += 1
        return tables.scopeIndices[key]
    }

    /// Whether `type` names the standard-library protocol `name`: through `Swift.` or `Swift::`,
    /// bare, or parenthesized.
    static func names(_ type: TypeSyntax, _ name: String) -> Bool {
        let type = type.unparenthesized
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            guard identifier.name.unescaped == name, identifier.genericArgumentClause == nil else { return false }
            guard let selector = identifier.moduleSelector else { return true }
            return selector.moduleName.unescaped == "Swift"
        }
        guard let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil,
            member.moduleSelector == nil, member.name.unescaped == name,
            let module = member.baseType.as(IdentifierTypeSyntax.self)
        else { return false }
        return module.name.unescaped == "Swift" && module.genericArgumentClause == nil && module.moduleSelector == nil
    }

    /// The tokens of a type spelling without their trivia or redundant backticks, so two spellings that
    /// differ only in comments, spacing, or escaping compare equal.
    static func spellingKey(_ type: some SyntaxProtocol) -> String {
        // An integer literal, a value generic argument, is keyed by its value, so `Problem<10>` and
        // `Problem<1_0>` share one key.
        type.tokens(viewMode: .sourceAccurate).map { $0.integerLiteralMagnitude.map(String.init) ?? $0.unescaped }
            .joined(separator: " ")
    }

    /// The key of a spelling of a type the expansion declares inside the schema, such as
    /// `Route.Choose`, with a leading `Self.` or schema-name component removed: `Self.Route.Choose`,
    /// `Flow.Route.Choose`, `(Route).Choose`, and `Route /* choice */ .Choose` share one key.
    static func relativeKey(_ type: TypeSyntax, schema: String) -> String {
        var components: [String] = []
        var node = type
        while let member = node.as(MemberTypeSyntax.self) {
            // A member named through a module selector, as in `Int.Review::Stride`, keeps it.
            let module = member.moduleSelector.map { $0.moduleName.unescaped + "::" } ?? ""
            components.insert(
                module + member.name.unescaped + (member.genericArgumentClause.map(spellingKey) ?? ""),
                at: 0
            )
            node = member.baseType.unparenthesized
        }
        guard let base = node.as(IdentifierTypeSyntax.self), base.moduleSelector == nil else {
            return spellingKey(type)
        }
        let first = base.name.unescaped + (base.genericArgumentClause.map(spellingKey) ?? "")
        if !components.isEmpty, base.genericArgumentClause == nil,
            base.name.tokenKind == .keyword(.Self) || base.name.unescaped == schema
        {
            return components.joined(separator: ".")
        }
        return ([first] + components).joined(separator: ".")
    }

    /// Whether an attribute names the macro `name`, bare or through its module: `Transition`,
    /// `StateMachine.Transition`, or `StateMachine::Transition`, with any spacing or comments.
    static func namesMacro(_ attribute: AttributeSyntax, _ name: String) -> Bool {
        let type = attribute.attributeName
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil {
            guard identifier.name.unescaped == name else { return false }
            return identifier.moduleSelector.map { $0.moduleName.unescaped == "StateMachine" } ?? true
        }
        guard let member = type.as(MemberTypeSyntax.self), member.name.unescaped == name,
            member.genericArgumentClause == nil, member.moduleSelector == nil,
            let module = member.baseType.as(IdentifierTypeSyntax.self)
        else { return false }
        return module.name.unescaped == "StateMachine" && module.moduleSelector == nil
            && module.genericArgumentClause == nil
    }

    /// The names a type spelling resolves by unqualified lookup, without backticks: each
    /// type reference that is not a member of another and names no module, and each custom attribute's name.
    static func freeNames(_ spelling: TypeSyntax) -> Set<String> {
        var result = Set<String>()
        for reference in TypeQualifier.lookupReferences(in: spelling) {
            guard case .identifier = reference.name.tokenKind else { continue }
            result.insert(reference.name.lookupName)
        }
        return result
    }

    /// A type spelling as graph metadata shows it: the author's tokens in order, exactly as written,
    /// with one space between two tokens wherever whitespace, a line break, or a comment separated them,
    /// and nothing else.
    ///
    /// It is read from the author's syntax, so a spelling the graph shows is never parsed again: parsing
    /// nested brackets takes time that doubles with each level.
    static func displaySpelling(_ type: some SyntaxProtocol) -> String {
        var result = ""
        var separated = false
        for token in type.tokens(viewMode: .sourceAccurate) {
            if !result.isEmpty, separated || token.leadingTriviaLength.utf8Length > 0 { result += " " }
            result += token.text
            separated = token.trailingTriviaLength.utf8Length > 0
        }
        return result
    }

    /// The phases in which no operation is active, in declaration order.
    var restingPhases: [Phase] {
        phases.filter { phase in !operations.contains { $0.activeIn.contains(phase.caseName) } }
    }

    /// The phases saved data can restore, in declaration order: those listed in `@Restoration(only:)`,
    /// or else every resting phase and each phase listed in `@Restoration(allows:)`.
    var restorablePhases: [Phase] {
        if let only = restoration?.only { return phases.filter { only.contains($0.caseName) } }
        let allowed = Set(restoration?.allows ?? [])
        return phases.filter { phase in
            allowed.contains(phase.caseName) || !operations.contains { $0.activeIn.contains(phase.caseName) }
        }
    }

    /// Every scope in identifier order: the declared `Scope` cases, then one private scope for each
    /// operation that names no scope.
    var scopeKeys: [String] { tables.scopeKeys }

    static func parse(
        _ declaration: EnumDeclSyntax,
        attribute: AttributeSyntax
    ) throws -> Schema {
        // Every name the parser compares comes from the declaration, so this makes every comparison exact.
        try Normalization.requireComposedNames(in: declaration)
        // The parser that runs the macro stops at its nesting limit and leaves the rest of the declaration
        // unread, and a declaration with a syntax error is not what its author wrote either, so a member after
        // that point, such as the `@Initial` case, would seem missing: the macro reads nothing from it.
        if declaration.hasError {
            let reason =
                declaration.hasMaximumNestingLevelOverflow
                ? "it nests deeper than the Swift parser that runs the macro reads: a debug build of SwiftSyntax, which a package builds when one of its test targets depends on SwiftSyntax, reads 20 levels of nested declarations, types, and expressions, and a release build reads 256. Nest less deeply, for example by moving nested types out of the schema."
                : "it does not parse as Swift. Fix the syntax errors the compiler reports."
            throw DiagnosticsError(diagnostics: [
                Diagnostic(
                    node: declaration.name,
                    message: SchemaMessage(message: "The macro cannot read this schema in full: \(reason)")
                )
            ])
        }
        let parser = SchemaParser()
        return try parser.parse(declaration, attribute: attribute)
    }
}

extension Schema {
    /// The work reading, validating, and generating the schema have done, which the regression tests
    /// bound by the size of the schema rather than by time.
    ///
    /// Each count is an integer that the work it counts adds to as it goes, so counting is cheap and
    /// changes nothing the expansion generates. A count of lookups charges one for each lookup in a
    /// table, where finding the same entry by a search would charge every entry it compared.
    struct Work: Equatable {
        /// The triggers functions found by name, an `Input` case or an operation, each looked up in a table.
        var triggersFound = 0
        /// The inputs and operations searches compared to find one by name or effect; only diagnostics search.
        var triggersScanned = 0
        /// The ``Tables`` built, and the phases, scopes, operations, events, edges, and routers they read.
        var tablesBuilt = 0
        var tabledEntries = 0
        /// The routers found for an edge, and the candidates, choice types, and shared names looked up for
        /// a router, each in the ``Tables``.
        var routerLookups = 0
        /// The source phase and trigger pairs the preparation dispatches, and the edges those dispatches read.
        var dispatchedPairs = 0
        var dispatchedEdges = 0
        /// The decisions of which names throw different failures, the failures read to identify them, and
        /// the `PreparationRejection` cases the generator names.
        var failureAnalyses = 0
        var failuresRead = 0
        var rejectionCases = 0
        /// The check plans built, the checks they were built from, and the witness functions they found by
        /// what each checks and its message.
        var plansBuilt = 0
        var plannedChecks = 0
        var planLookups = 0
        /// The setup the joint analysis charged to its budget, and the cells of the masks it then built.
        var jointSetupCharged = 0
        var jointSetupBuilt = 0
        /// The scope identifiers and active phases looked up in the ``Tables``.
        var scopeLookups = 0
    }

    /// Holds the ``Work`` that one schema's drafts, the schema, and its copies count together.
    final class WorkCounter {
        var work = Work()
    }

    /// The work counted so far.
    var work: Work { workCounter.work }
}

/// The checks the parser collects of the conclusions it draws from readings it cannot confirm, each
/// once, in the order it reads their types.
///
/// A conclusion is checked on the type it is about, named where the compiler resolves it as the
/// author's declaration does, so the check holds however the spelling's names resolve: a reading of
/// `Never` or `Void` that decides the generated shape must name the standard library's type, and a
/// reading of a type with values must not name `Never`.
///
/// Each check belongs to the declaration whose conclusion needs it, so one declaration that revises
/// its own conclusion removes only its own check, and a check another declaration needs stays.
struct TypeChecks {
    /// A check the declaration at `owner` needs.
    private struct Entry: Hashable {
        let check: Schema.TypeCheck
        let owner: Int?
    }

    /// Every check needed, in the order first needed, with `nil` where one was removed, and where each is,
    /// so noting and removing one takes constant time however many there are.
    private var entries: [Entry?] = []
    private var positions: [Entry: Int] = [:]

    /// Every check some declaration still needs, each once, in the order they were first needed.
    var ordered: [Schema.TypeCheck] {
        var seen: Set<Schema.TypeCheck> = []
        return entries.compactMap { $0?.check }.filter { seen.insert($0).inserted }
    }

    /// Notes the check that `reading` of the type spelled `reference` at the schema's scope needs, if
    /// any, for the declaration at `owner`.
    ///
    /// `distinguishesVoid` says whether reading the type as `Void` changes what the expansion
    /// generates, as it does for an operation's input and an event's payload.
    mutating func note(_ reading: ResolvedType, at reference: String, distinguishesVoid: Bool, owner: Int? = nil) {
        let kind: Schema.TypeCheck.Kind
        guard !reading.confirmsShape else { return }
        switch reading.reading {
        case .never: kind = .isStandard("Never")
        case .void where distinguishesVoid: kind = .isStandard("Void")
        default: kind = .isNotNever()
        }
        require(kind, at: reference, owner: owner)
    }

    /// Notes that the schema conforms to the standard library's protocol `name`, `Equatable` or
    /// `Hashable`, which its inheritance clause spells by a name that could name another protocol.
    mutating func noteConformance(_ name: String, spelled spelling: TypeSyntax) {
        if let identifier = spelling.as(IdentifierTypeSyntax.self), identifier.moduleSelector != nil { return }
        require(.conformsToStandard(name), at: "Self")
    }

    mutating func require(_ kind: Schema.TypeCheck.Kind, at reference: String, owner: Int? = nil) {
        let entry = Entry(check: Schema.TypeCheck(kind: kind, reference: reference), owner: owner)
        guard positions[entry] == nil else { return }
        positions[entry] = entries.count
        entries.append(entry)
    }

    /// Removes the check the declaration at `owner` needed, which a later conclusion of its own replaces.
    mutating func remove(_ kind: Schema.TypeCheck.Kind, at reference: String, owner: Int?) {
        let entry = Entry(check: Schema.TypeCheck(kind: kind, reference: reference), owner: owner)
        guard let position = positions.removeValue(forKey: entry) else { return }
        entries[position] = nil
    }
}

/// A source phase and a trigger, which the edges and the router of a dispatch share.
private struct SourceTrigger: Hashable {
    let from: String
    let trigger: Schema.Trigger
}

/// Rewrites a type so it resolves outside the declaration that spelled it: `Self` becomes `owner`, and
/// each unqualified reference to one of `names` becomes a member of `owner`.
///
/// It rewrites references that name lookup resolves, so a tuple label, a dictionary's key type, a
/// member after a period, a reference through a module selector such as `Swift::Int`, and a built-in
/// attribute such as `@Sendable` keep their meaning, while a custom attribute such as a global actor
/// declared in `owner` is qualified as a type is.
enum TypeQualifier {
    /// The attributes the compiler defines in type position, which name lookup never resolves.
    static let builtInAttributes: Set<String> = [
        "autoclosure", "concurrent", "convention", "differentiable", "escaping", "isolated", "noDerivative",
        "noescape", "nonisolated", "retroactive", "Sendable", "unchecked", "unsafe", "preconcurrency",
    ]

    /// The spelling of `type` with its references to `Self` and `names` qualified with `owner`.
    static func qualify(_ type: TypeSyntax, owner: String, names: Set<String>) -> String {
        let references = Set(lookupReferences(in: type).map(\.name.id))
        var result = ""
        for token in type.tokens(viewMode: .sourceAccurate) {
            guard references.contains(token.id) else {
                result += token.description
                continue
            }
            let spelled: String
            if token.tokenKind == .keyword(.Self) {
                spelled = owner
            } else if case .identifier = token.tokenKind, names.contains(token.lookupName) {
                spelled = owner + "." + token.lookupName.spelledAsName
            } else {
                result += token.description
                continue
            }
            result += token.leadingTrivia.description + spelled + token.trailingTrivia.description
        }
        return result
    }

    /// The references in `type` that unqualified name lookup resolves, in source order.
    ///
    /// They are each type named without a module selector outside an attribute, and the name of each
    /// custom attribute, such as a global actor. A built-in attribute's name such as `Sendable` in
    /// `@Sendable`, an attribute's arguments, a label, a specifier, a member after a period, and a name
    /// after a module selector are not among them.
    ///
    /// Every reader that asks which declarations a spelling's names may bind takes them from here.
    static func lookupReferences(in type: some SyntaxProtocol) -> [IdentifierTypeSyntax] {
        type.tokens(viewMode: .sourceAccurate)
            .compactMap { token in
                guard let reference = token.parent?.as(IdentifierTypeSyntax.self), reference.name.id == token.id,
                    reference.moduleSelector == nil, resolvesByLookup(reference)
                else { return nil }
                return reference
            }
    }

    /// Whether name lookup resolves the reference: a type anywhere outside an attribute, or the name
    /// of a custom attribute; an attribute's arguments and a built-in attribute's name are not.
    private static func resolvesByLookup(_ reference: IdentifierTypeSyntax) -> Bool {
        var node = reference.parent
        var child = Syntax(reference)
        while let current = node {
            if let attribute = current.as(AttributeSyntax.self) {
                return attribute.attributeName.id == child.id && !builtInAttributes.contains(reference.name.unescaped)
            }
            child = current
            node = current.parent
        }
        return true
    }
}

/// How an authored transition spells its effect type, checked once every edge is known.
private enum EffectForm {
    /// The effect argument of `Advance`.
    case advance(String)
    /// The effect argument of `Change`.
    case change(String)
    /// A bare destination returned by an edge that starts operations.
    case destination(String)
}

private struct SchemaMessage: DiagnosticMessage {
    let message: String
    var diagnosticID: MessageID { MessageID(domain: "StateMachine", id: "invalidSchema") }
    var severity: DiagnosticSeverity { .error }
}

private struct SchemaParser {
    /// The syntax of each spelling the parser stores, kept or parsed once, which the schema keeps.
    let spellings = SpellingSyntax()
    /// Where reading the schema counts its work, which the schema it reads keeps counting.
    let workCounter = Schema.WorkCounter()
    private func reject(_ node: some SyntaxProtocol, _ message: String) throws -> Never {
        throw DiagnosticsError(diagnostics: [Diagnostic(node: node, message: SchemaMessage(message: message))])
    }

    /// Whether `text`, a name read without redundant backticks, is an identifier that generated code can
    /// spell bare: not a keyword, a raw identifier, or a name such as `Type` that only backticks allow.
    private func identifier(_ text: String) -> Bool {
        guard !text.isEmpty, text != "_", text.utf8.first != UInt8(ascii: "`") else { return false }
        let parsed = Parser.parse(source: "enum _SchemaIdentifier { case \(text) }")
        guard !parsed.hasError, parsed.statements.count == 1,
            let declaration = parsed.statements.first?.item.as(EnumDeclSyntax.self),
            declaration.memberBlock.members.count == 1,
            let cases = declaration.memberBlock.members.first?.decl.as(EnumCaseDeclSyntax.self),
            cases.elements.count == 1, let name = cases.elements.first?.name, name.presence == .present
        else { return false }
        return name.text == text
    }

    /// Reads `<Enum>.<case>`, the only accepted spelling of a declared case reference.
    private func caseReference(_ expression: ExprSyntax, in enumeration: String) throws -> String {
        guard let member = expression.as(MemberAccessExprSyntax.self),
            let base = member.base?.as(DeclReferenceExprSyntax.self), base.argumentNames == nil,
            base.baseName.unescaped == enumeration, member.declName.argumentNames == nil,
            case .identifier = member.declName.baseName.tokenKind, identifier(member.declName.baseName.unescaped)
        else { try reject(expression, "Reference a declared case as \(enumeration).<case>.") }
        return member.declName.baseName.unescaped
    }

    private func caseReferences(_ expression: ExprSyntax, in enumeration: String) throws -> [String] {
        guard let array = expression.as(ArrayExprSyntax.self) else {
            try reject(expression, "Use an array literal of \(enumeration).<case> references.")
        }
        let values = try array.elements.map { try caseReference($0.expression, in: enumeration) }
        guard Set(values).count == values.count else {
            try reject(expression, "Remove duplicate references from this metadata list.")
        }
        return values
    }

    /// Reads `<Type>.self`, the only accepted spelling of a declared phase payload or operation reference.
    private func typeReference(_ expression: ExprSyntax) throws -> String {
        guard let member = expression.as(MemberAccessExprSyntax.self),
            let base = member.base?.as(DeclReferenceExprSyntax.self), base.argumentNames == nil,
            member.declName.baseName.tokenKind == .keyword(.self), identifier(base.baseName.unescaped)
        else { try reject(expression, "Reference a type declared directly inside the schema as <Type>.self.") }
        return base.baseName.unescaped
    }

    /// Reads a phase payload spelling from a signature, allowing `Self.` or schema-name qualification, in
    /// parentheses or not, and redundant backticks.
    private func payloadName(_ type: TypeSyntax, schema: String) -> String {
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil,
            identifier.moduleSelector == nil
        {
            return identifier.name.unescaped
        }
        if let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil,
            member.moduleSelector == nil, let base = member.baseType.unparenthesized.as(IdentifierTypeSyntax.self),
            base.genericArgumentClause == nil, base.moduleSelector == nil,
            base.name.tokenKind == .keyword(.Self) || base.name.unescaped == schema
        {
            return member.name.unescaped
        }
        return type.trimmedDescription
    }

    private func typeReferences(_ expression: ExprSyntax) throws -> [(name: String, node: ExprSyntax)] {
        guard let array = expression.as(ArrayExprSyntax.self) else {
            try reject(expression, "Use an array literal of <Type>.self references.")
        }
        let values = try array.elements.map { (name: try typeReference($0.expression), node: $0.expression) }
        guard Set(values.map(\.name)).count == values.count else {
            try reject(expression, "Remove duplicate references from this metadata list.")
        }
        return values
    }

    private func arguments(
        _ attribute: AttributeSyntax,
        required: Set<String>,
        optional: Set<String> = []
    ) throws
        -> [String: ExprSyntax]
    {
        guard case .argumentList(let arguments) = attribute.arguments else {
            guard required.isEmpty, attribute.arguments == nil else {
                try reject(
                    attribute.arguments.map(Syntax.init) ?? Syntax(attribute),
                    "Provide labeled metadata arguments."
                )
            }
            return [:]
        }
        var result: [String: ExprSyntax] = [:]
        for argument in arguments {
            guard let label = argument.label?.lookupName, required.union(optional).contains(label) else {
                try reject(
                    argument,
                    "Unexpected metadata argument; supported labels are \(required.union(optional).sorted().joined(separator: ", "))."
                )
            }
            guard result.updateValue(argument.expression, forKey: label) == nil else {
                try reject(argument, "Specify '\(label)' only once.")
            }
        }
        guard required.isSubset(of: Set(result.keys)) else {
            try reject(
                attribute,
                "Missing required metadata: \(required.subtracting(result.keys).sorted().joined(separator: ", "))."
            )
        }
        return result
    }

    private func member(_ expression: ExprSyntax) throws -> String {
        guard let member = expression.as(MemberAccessExprSyntax.self), member.base == nil else {
            try reject(expression, "Use an unqualified literal enum member such as .shared.")
        }
        return member.declName.baseName.unescaped
    }

    /// Reads the one trigger label of an edge or router: `on`, `onSuccess`, or `onFailure`.
    ///
    /// An edge of an `.ownedOnly` schema may omit it to be taken directly through the owned method
    /// named `direct`. A trigger that can never happen is rejected here, before any analysis of the
    /// graph credits the edge or router: the success of an operation whose output is `Never`, and the
    /// failure of an operation that cannot fail. An `Input` case that carries `Never` is rejected where
    /// it is declared. `role` names the declaration in those diagnostics.
    private func trigger(
        _ metadata: [String: ExprSyntax],
        attribute: AttributeSyntax,
        inputs: [String: Schema.Case],
        operations: [String: Schema.Operation],
        direct: String?,
        role: String
    ) throws -> (trigger: Schema.Trigger, input: Schema.Case?, operation: Schema.Operation?) {
        let labels = ["on", "onSuccess", "onFailure"].filter { metadata[$0] != nil }
        if labels.isEmpty, let direct { return (Schema.Trigger(kind: .direct, name: direct), nil, nil) }
        guard labels.count == 1, let label = labels.first, let expression = metadata[label] else {
            // The later of two triggers, or the attribute that names none.
            let named = labels.compactMap { metadata[$0]?.parent?.as(LabeledExprSyntax.self) }
                .sorted { $0.position < $1.position }
            try reject(
                named.dropFirst().first.map(Syntax.init) ?? Syntax(attribute),
                "Name exactly one trigger: on: Input.<case>, onSuccess: <Operation>.self, or onFailure: <Operation>.self."
            )
        }
        guard label != "on" else {
            let name = try caseReference(expression, in: "Input")
            workCounter.work.triggersFound += 1
            guard let input = inputs[name] else {
                try reject(expression, "'\(name)' is not a declared Input case.")
            }
            return (Schema.Trigger(kind: .input, name: name), input, nil)
        }
        let name = try typeReference(expression)
        workCounter.work.triggersFound += 1
        guard let operation = operations[name] else {
            try reject(expression, "'\(name)' is not a declared @Operation namespace.")
        }
        if label == "onFailure", operation.isInfallible {
            let reason =
                operation.declaresFailure ? "its Failure is Never" : "it declares no Failure, which means Never"
            try reject(
                expression,
                "Operation '\(name)' cannot fail: \(reason), so this onFailure: \(role) can never run; remove it, or declare the Failure the operation reports."
            )
        }
        if label == "onSuccess", operation.neverSucceeds {
            try reject(
                expression,
                "Operation '\(name)' never succeeds: its Output is Never, so this onSuccess: \(role) can never run; remove it, or declare the Output the operation produces."
            )
        }
        return (
            Schema.Trigger(kind: label == "onSuccess" ? .success : .failure, name: operation.effect), nil, operation
        )
    }

    private func describe(_ trigger: Schema.Trigger, operations: [Schema.Operation]) -> String {
        guard trigger.kind != .input else { return "on: Input.\(trigger.name)" }
        guard trigger.kind != .direct else { return "a direct call" }
        let name =
            operations.first {
                workCounter.work.triggersScanned += 1
                return $0.effect == trigger.name
            }?
            .name ?? trigger.name
        return "\(trigger.kind == .success ? "onSuccess" : "onFailure"): \(name).self"
    }

    /// Lower-cases the leading capital run: `Fetch` to `fetch`, `URLLoad` to `urlLoad`.
    private func lowerCamel(_ name: String) -> String {
        let characters = Array(name)
        var run = 0
        while run < characters.count, characters[run].isUppercase { run += 1 }
        guard run > 0 else { return name }
        let lowered = run > 1 && run < characters.count ? run - 1 : run
        return (String(characters[..<lowered]).lowercased() + String(characters[lowered...])).composed
    }

    private func phaseType(_ caseName: String, in phases: [Schema.Phase]) -> String {
        phases.first { $0.caseName == caseName }?.typeName ?? caseName
    }

    /// Finds the authored declaration to blame for a name, falling back to the schema.
    private func anchor(for name: String, in declaration: EnumDeclSyntax) -> Syntax {
        func matches(_ token: TokenSyntax) -> Bool { token.lookupName == name }
        for member in declaration.memberBlock.members {
            if let cases = member.decl.as(EnumCaseDeclSyntax.self),
                let element = cases.elements.first(where: { matches($0.name) })
            {
                return Syntax(element.name)
            }
            if let named = member.decl.asProtocol(NamedDeclSyntax.self), matches(named.name) {
                return Syntax(named.name)
            }
            if let variable = member.decl.as(VariableDeclSyntax.self),
                let binding = variable.bindings.first(where: { boundNames($0.pattern).contains(name) })
            {
                // The identifier the pattern binds.
                return binding.pattern.tokens(viewMode: .sourceAccurate).first(where: matches).map(Syntax.init)
                    ?? Syntax(binding.pattern)
            }
        }
        return Syntax(declaration.name)
    }

    /// The generic arguments of a runtime type spelled `Name<…>` or, module-qualified, `StateMachine.Name<…>`.
    private func runtimeGenericArguments(_ type: TypeSyntax, named name: String) -> GenericArgumentListSyntax? {
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.name.unescaped == name {
            return identifier.genericArgumentClause?.arguments
        }
        if let member = type.as(MemberTypeSyntax.self), member.name.unescaped == name,
            member.baseType.as(IdentifierTypeSyntax.self)?.name.unescaped == "StateMachine",
            member.baseType.as(IdentifierTypeSyntax.self)?.genericArgumentClause == nil
        {
            return member.genericArgumentClause?.arguments
        }
        return nil
    }

    private func marker(_ attributes: AttributeListSyntax, named name: String) throws -> AttributeSyntax? {
        // The module-qualified spellings name the same macro.
        let matches = attributes.compactMap { $0.as(AttributeSyntax.self) }.filter { Schema.namesMacro($0, name) }
        guard matches.count <= 1 else {
            try reject(matches[1], "Apply @\(name) only once to a declaration.")
        }
        return matches.first
    }

    /// Reads the default value of the `@Initial` case: a no-argument construction of its payload, or a call to
    /// a no-argument static function of the schema, spelled so it resolves outside the schema.
    private func initialDefault(
        _ expression: ExprSyntax,
        payload: String,
        schema: String,
        functions: Set<String>
    ) throws -> String {
        func path(_ expression: ExprSyntax) -> [String]? {
            if let reference = expression.as(DeclReferenceExprSyntax.self), reference.argumentNames == nil {
                return [reference.baseName.unescaped]
            }
            if let member = expression.as(MemberAccessExprSyntax.self), member.declName.argumentNames == nil {
                guard let base = member.base else { return [".", member.declName.baseName.unescaped] }
                return path(base).map { $0 + [member.declName.baseName.unescaped] }
            }
            return nil
        }
        if let call = expression.as(FunctionCallExprSyntax.self), call.arguments.isEmpty,
            call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty,
            var names = path(call.calledExpression)
        {
            if names.count > 1, names.first == schema || names.first == "Self" { names.removeFirst() }
            // The construction names the schema through its alias, which names the type in expression
            // position too, where a static property of the schema's name, which an extension may
            // declare, would otherwise take it.
            if names == [".", "init"] || names == [payload] || names == [payload, "init"] {
                return "_StateMachineSchema.\(payload)()"
            }
            if names.count == 1, let name = names.first, functions.contains(name) {
                return "_StateMachineSchema.\(name)()"
            }
        }
        try reject(
            expression,
            "Put this construction in a static function that returns \(payload) and name that function here."
        )
    }

    /// What the authored completion edges and routers of one operation say about its outcomes, read
    /// from their metadata and signatures before the operation itself is read.
    struct AuthoredCompletions {
        /// Whether some `onSuccess:` edge or router exists, so the author says the operation succeeds.
        var succeeds = false
        /// Whether some `onFailure:` edge or router exists, so the author says the operation fails.
        var fails = false
        /// Whether some `onSuccess:` edge or router takes an output parameter after its source.
        var takesOutput = false
        /// Whether some completion edge or router takes the operation's request.
        var takesRequest = false
    }

    /// The completions each operation's edges and routers declare, by the operation's name.
    ///
    /// A completion function takes its source, then its output or failure, unlabeled, then its request,
    /// labeled `request:`. The label alone says which parameter is the request, so what the author
    /// wrote decides each role without reading a type.
    private func authoredCompletions(_ members: MemberBlockItemListSyntax) -> [String: AuthoredCompletions] {
        var result: [String: AuthoredCompletions] = [:]
        for member in members {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            for element in function.attributes {
                guard let attribute = element.as(AttributeSyntax.self),
                    Schema.namesMacro(attribute, "Transition") || Schema.namesMacro(attribute, "Route"),
                    case .argumentList(let arguments) = attribute.arguments
                else { continue }
                for argument in arguments {
                    guard let label = argument.label?.lookupName, ["onSuccess", "onFailure"].contains(label),
                        let reference = argument.expression.as(MemberAccessExprSyntax.self),
                        let base = reference.base?.as(DeclReferenceExprSyntax.self)
                    else { continue }
                    let name = base.baseName.unescaped
                    let extra = function.signature.parameterClause.parameters.dropFirst()
                    var completions = result[name] ?? AuthoredCompletions()
                    if extra.contains(where: Self.takesRequest) { completions.takesRequest = true }
                    if label == "onSuccess" {
                        completions.succeeds = true
                        if extra.contains(where: { !Self.takesRequest($0) }) { completions.takesOutput = true }
                    } else {
                        completions.fails = true
                    }
                    result[name] = completions
                }
            }
        }
        return result
    }

    /// Whether an authored parameter is a completion's request: its argument label is `request`.
    static func takesRequest(_ parameter: FunctionParameterSyntax) -> Bool {
        parameter.firstName.unescaped == "request"
    }

    /// Reads an authored spelling where `scope` resolves it, rejecting one a reading budget cut short:
    /// nothing the macro concludes may rest on a reading it did not finish.
    private func read(
        _ type: TypeSyntax,
        in scope: Int = LexicalScopes.schema,
        _ typeScopes: LexicalScopes
    ) throws
        -> ResolvedType
    {
        let reading = typeScopes.resolve(type, in: scope)
        guard !reading.isCut else {
            try reject(
                type,
                "This type nests too deeply, or reaches its type through too many aliases, for the macro to read it; spell it directly or through fewer aliases."
            )
        }
        return reading
    }

    /// Whether an enum's inheritance clause suppresses `Copyable`, as `~Copyable` or `~Swift::Copyable` does.
    private func suppressesCopyable(_ declaration: EnumDeclSyntax) -> Bool {
        declaration.inheritanceClause?.inheritedTypes
            .contains { inherited in
                guard let suppressed = inherited.type.as(SuppressedTypeSyntax.self) else { return false }
                return Schema.names(suppressed.type, "Copyable")
            } ?? false
    }

    /// Whether a declaration's modifiers make it a member of the type rather than of its values.
    private func isStatic(_ modifiers: DeclModifierListSyntax) -> Bool {
        modifiers.contains { ["static", "class"].contains($0.name.text) }
    }

    /// The identifiers a pattern binds, as in `let (graph, other) = (1, 2)`.
    private func boundNames(_ pattern: PatternSyntax) -> [String] {
        if let identifier = pattern.as(IdentifierPatternSyntax.self) { return [identifier.identifier.lookupName] }
        if let tuple = pattern.as(TuplePatternSyntax.self) { return tuple.elements.flatMap { boundNames($0.pattern) } }
        if let binding = pattern.as(ValueBindingPatternSyntax.self) { return boundNames(binding.pattern) }
        return []
    }

    /// The name of a type declaration, a struct, enum, class, actor, protocol, or type alias, without
    /// backticks, as lookups compare it.
    private func nestedTypeName(_ declaration: DeclSyntax) -> String? {
        if let alias = declaration.as(TypeAliasDeclSyntax.self) { return alias.name.lookupName }
        if let type = declaration.as(StructDeclSyntax.self) { return type.name.lookupName }
        if let type = declaration.as(EnumDeclSyntax.self) { return type.name.lookupName }
        if let type = declaration.as(ClassDeclSyntax.self) { return type.name.lookupName }
        if let type = declaration.as(ActorDeclSyntax.self) { return type.name.lookupName }
        if let type = declaration.as(ProtocolDeclSyntax.self) { return type.name.lookupName }
        return nil
    }

    private func cases(
        _ declaration: EnumDeclSyntax,
        payloads: ClosedRange<Int>,
        initial: String? = nil
    ) throws -> [Schema.Case] {
        if let generic = declaration.genericParameterClause.map(Syntax.init)
            ?? declaration.genericWhereClause.map(Syntax.init)
        {
            try reject(generic, "Input and Scope must be nongeneric closed enums.")
        }
        var result: [Schema.Case] = []
        var names: [TokenSyntax] = []
        let staticFunctions = Set(
            declaration.memberBlock.members.compactMap { member -> String? in
                guard let function = member.decl.as(FunctionDeclSyntax.self),
                    function.modifiers.contains(where: { $0.name.unescaped == "static" })
                else { return nil }
                return function.name.unescaped
            }
        )
        for member in declaration.memberBlock.members {
            guard let cases = member.decl.as(EnumCaseDeclSyntax.self) else { continue }
            for element in cases.elements {
                names.append(element.name)
                guard identifier(element.name.unescaped) else {
                    try reject(
                        element.name,
                        "Name the case with a Swift identifier that needs no backticks, such as one that is not a keyword."
                    )
                }
                let parameters = element.parameterClause?.parameters
                let count = parameters?.count ?? 0
                guard element.rawValue == nil, payloads.contains(count) else {
                    // A raw value, a payload clause with too many payloads, or the name of a case that lacks one.
                    try reject(
                        element.rawValue.map(Syntax.init) ?? element.parameterClause.map(Syntax.init)
                            ?? Syntax(element.name),
                        payloads == 1 ... 1
                            ? "Each phase case requires exactly one unlabeled payload."
                            : payloads == 0 ... 0
                                ? "Each Scope case is a plain name without a payload or raw value."
                                : "Each Input case accepts zero or one unlabeled payload."
                    )
                }
                var defaultValue: String?
                if let parameter = parameters?.first {
                    let defaultable = element.name.unescaped == initial
                    // A payload is a value of its type; Swift gives a case's payload no passing convention.
                    if let modifier = parameter.modifiers.first {
                        try reject(modifier, "Declare the payload as its type alone, without modifiers.")
                    }
                    if let label = parameter.firstName, label.tokenKind != .wildcard {
                        try reject(
                            label,
                            defaultable
                                ? "Use an unlabeled payload."
                                : "Use an unlabeled payload without a default value."
                        )
                    }
                    if !defaultable, let defaultValue = parameter.defaultValue {
                        try reject(defaultValue, "Use an unlabeled payload without a default value.")
                    }
                    if defaultable, let value = parameter.defaultValue?.value {
                        // The phase payload is a type the schema declares, however the case qualifies it,
                        // so its construction names it once, through the schema's alias.
                        defaultValue = try initialDefault(
                            value,
                            payload: payloadName(parameter.type.unparenthesized, schema: declaration.name.unescaped),
                            schema: declaration.name.unescaped,
                            functions: staticFunctions
                        )
                    }
                }
                result.append(
                    Schema.Case(
                        caseName: element.name.unescaped,
                        // The spelling is the author's, and means what it means inside this enum, where
                        // Swift resolves it, members of the enum's extensions included; generated code
                        // never repeats it elsewhere.
                        payloadType: parameters?.first.map { Schema.displaySpelling($0.type) },
                        payload: parameters?.first?.type,
                        defaultValue: defaultValue
                    )
                )
            }
        }
        // A repeated name is refused at its second declaration.
        var seen: Set<String> = []
        if let repeated = names.first(where: { !seen.insert($0.unescaped).inserted }) {
            try reject(repeated, "Case names must be unique; overloaded enum cases are unsupported.")
        }
        return result
    }

    /// The first alias of a namespace that its grammar refuses: the name of one it does not declare or
    /// of one it declares again, or the generic parameters of one it declares.
    private func misplacedAlias(in aliases: [TypeAliasDeclSyntax], named names: Set<String>) -> Syntax? {
        var declared: Set<String> = []
        for alias in aliases {
            guard names.contains(alias.name.unescaped), declared.insert(alias.name.unescaped).inserted else {
                return Syntax(alias.name)
            }
            if let generic = alias.genericParameterClause { return Syntax(generic) }
        }
        return nil
    }

    private func admission(_ expression: ExprSyntax) throws -> Schema.Admission {
        if let call = expression.as(FunctionCallExprSyntax.self) {
            guard try member(call.calledExpression) == "parallel", call.arguments.count == 1,
                let argument = call.arguments.first, argument.label?.lookupName == "limit",
                let limit = argument.expression.integerLiteralValue, limit > 0,
                call.trailingClosure == nil, call.additionalTrailingClosures.isEmpty
            else {
                try reject(expression, "Use .parallel(limit: N) with a positive integer literal representable as Int.")
            }
            return .parallel(limit: limit)
        }
        switch try member(expression) {
        case "latest": return .latest
        case "rejectWhenActive": return .rejectWhenActive
        default: try reject(expression, "Admission must be .latest, .rejectWhenActive, or .parallel(limit: N).")
        }
    }

    /// Checks the shape shared by authored functions, and returns the function's deprecation, if any.
    ///
    /// `role` names the functions in the throws diagnostic.
    ///
    /// Every parameter is unlabeled, except that a transition or router may label one `request:`, which
    /// its trigger then decides it may take.
    private func validateFunction(
        _ function: FunctionDeclSyntax,
        role: String,
        allowsRequest: Bool = false,
        schema: String
    ) throws -> Schema.Deprecation? {
        // The refusal stands at the first offending token in source order: the `func` keyword of a function
        // that is not static, its generic parameters, a parameter's label, ellipsis, or default, `async`, or
        // its `where` clause.
        let offending: Syntax? = {
            if !function.modifiers.contains(where: { $0.name.unescaped == "static" }) {
                return Syntax(function.funcKeyword)
            }
            if let generic = function.genericParameterClause { return Syntax(generic) }
            for parameter in function.signature.parameterClause.parameters {
                if parameter.firstName.tokenKind != .wildcard, !(allowsRequest && Self.takesRequest(parameter)) {
                    return Syntax(parameter.firstName)
                }
                if let ellipsis = parameter.ellipsis { return Syntax(ellipsis) }
                if let defaultValue = parameter.defaultValue { return Syntax(defaultValue) }
            }
            if let asyncSpecifier = function.signature.effectSpecifiers?.asyncSpecifier {
                return Syntax(asyncSpecifier)
            }
            return function.genericWhereClause.map(Syntax.init)
        }()
        if let offending {
            try reject(
                offending,
                allowsRequest
                    ? "Use a synchronous nongeneric static function with nonvariadic parameters and no defaults, each unlabeled except a completion's request, labeled request:."
                    : "Use a synchronous nongeneric static function with unlabeled, nonvariadic parameters and no defaults."
            )
        }
        if let throwsClause = function.signature.effectSpecifiers?.throwsClause {
            guard throwsClause.type != nil, throwsClause.throwsSpecifier.text == "throws" else {
                try reject(
                    throwsClause,
                    "\(role) must use typed throws(Failure), or omit throws."
                )
            }
        }
        guard function.body != nil else {
            try reject(function.name, "Provide the authored function body in the schema.")
        }
        // Generated code calls the function from nonisolated code, from every owner's isolation, and from members
        // that have only the schema's availability. An attribute could isolate the function to a global actor,
        // narrow its availability, or change how a call is checked, so only this macro's markers, Swift's
        // attributes that change none of that, and one deprecation for every platform are allowed, whatever an
        // attribute's capitalization.
        // An attribute inside `#if` was refused with the schema's members.
        var deprecation: AttributeSyntax?
        for case .attribute(let attribute) in function.attributes {
            if ["Transition", "Route", "Restoration"].contains(where: { Schema.namesMacro(attribute, $0) }) {
                continue
            }
            let name =
                attribute.attributeName.as(MemberTypeSyntax.self)?.name.unescaped
                ?? attribute.attributeName.as(IdentifierTypeSyntax.self)?.name.unescaped ?? ""
            if let builtIn = attribute.builtInName, Self.permittedFunctionAttributes.contains(builtIn) { continue }
            if deprecation == nil, Self.deprecates(attribute) {
                // A restoration's generated entry points are `init(restoring:)` and `reset(restoring:)`,
                // which keep their names, so no rename of the function applies to them.
                if !allowsRequest, case .availability(let arguments)? = attribute.arguments,
                    let renamed = arguments.first(where: {
                        $0.argument.as(AvailabilityLabeledArgumentSyntax.self)?.label.text == "renamed"
                    })
                {
                    try reject(
                        renamed,
                        "Remove 'renamed:': the restoring initializers and resets this deprecation marks keep their names; describe the replacement with 'message:'."
                    )
                }
                deprecation = attribute
                continue
            }
            if ["available", "backDeployed"].contains(name) {
                try reject(
                    attribute,
                    "Remove '@\(name)' and give the schema this availability instead: generated members call this function, and they have only the schema's availability."
                )
            }
            try reject(
                attribute,
                "Remove '@\(name)': generated code calls this function from nonisolated code and from every owner, so it takes only Swift's @discardableResult, @inlinable, @inline, @usableFromInline, and @available(*, deprecated), and no attribute that may isolate it to a global actor such as MainActor."
            )
        }
        // A modifier other than its access, `static`, and `nonisolated` would change how generated code
        // may call the function, or is one Swift refuses on a static function of an enum.
        for modifier in function.modifiers
        where Schema.Access(rawValue: modifier.name.text) == nil
            && !(["static", "nonisolated"].contains(modifier.name.text) && modifier.detail == nil)
        {
            try reject(
                modifier,
                "Remove '\(modifier.trimmedDescription)': an authored function is static, with an access modifier and nonisolated as its only other modifiers."
            )
        }
        return deprecation.map { Self.deprecation($0, of: function, schema: schema) }
    }

    /// Whether `attribute` deprecates a function on every platform and nothing else: `*`, then one bare
    /// `deprecated` and at most one `message:` and one `renamed:` string, in any order, as Swift reads them.
    private static func deprecates(_ attribute: AttributeSyntax) -> Bool {
        guard attribute.builtInName == "available", case .availability(let arguments)? = attribute.arguments,
            case .token(let platform)? = arguments.first?.argument, platform.text == "*"
        else { return false }
        var options: Set<String> = []
        for element in arguments.dropFirst() {
            let option: String
            switch element.argument {
            case .token(let token) where token.tokenKind == .keyword(.deprecated): option = "deprecated"
            case .availabilityLabeledArgument(let labeled) where ["message", "renamed"].contains(labeled.label.text):
                guard case .string = labeled.value else { return false }
                option = labeled.label.text
            default: return false
            }
            guard options.insert(option).inserted else { return false }
        }
        return options.contains("deprecated")
    }

    /// The deprecation of an authored function, with the declaration that generated code calls it through.
    private static func deprecation(
        _ attribute: AttributeSyntax,
        of function: FunctionDeclSyntax,
        schema: String
    ) -> Schema.Deprecation {
        // `Self` names the schema where the function is written, and the protocol and the type the
        // expansion declares for it are other types, so the declaration spells the schema by its name.
        func spelled(_ type: TypeSyntax) -> String { TypeQualifier.qualify(type.trimmed, owner: schema, names: []) }
        let parameters = function.signature.parameterClause.parameters.enumerated()
        let labels = parameters.map { $0.element.firstName.tokenKind == .wildcard ? nil : $0.element.firstName.text }
        let declared = parameters.map { index, parameter in
            "\(labels[index] ?? "_") argument\(index): \(spelled(parameter.type))"
        }
        let effects = function.signature.effectSpecifiers?.throwsClause?.type.map { " throws(\(spelled($0)))" } ?? ""
        let result = function.signature.returnClause.map { " -> \(spelled($0.type))" } ?? ""
        let renamed = attribute.arguments?.as(AvailabilityArgumentListSyntax.self)?
            .lazy.compactMap { $0.argument.as(AvailabilityLabeledArgumentSyntax.self) }
            .first { $0.label.text == "renamed" }
            .flatMap { $0.value.as(SimpleStringLiteralExprSyntax.self) }
        return Schema.Deprecation(
            attribute: attribute.trimmedDescription,
            declaration: "static func \(function.name.text)(\(declared.joined(separator: ", ")))\(effects)\(result)",
            declaresThrows: !effects.isEmpty,
            call: "\(function.name.text)("
                + labels.enumerated().map { index, label in (label.map { "\($0): " } ?? "") + "argument\(index)" }
                .joined(separator: ", ") + ")",
            renamed: renamed.map { literal in
                (literal.segments.map(\.content.text).joined(), Syntax(literal))
            }
        )
    }

    /// The attributes of Swift that an authored function may carry: none changes its isolation, its
    /// availability, or how a call to it is checked.
    static let permittedFunctionAttributes: Set<String> = [
        "discardableResult", "inlinable", "inline", "usableFromInline",
    ]

    /// Reads the schema, reporting first an alias found while reading it to name itself, since every
    /// other conclusion drawn through that alias would rest on a type it does not have.
    func parse(_ declaration: EnumDeclSyntax, attribute: AttributeSyntax) throws -> Schema {
        // Authored spellings are read through the declarations the schema makes visible.
        let typeScopes = LexicalScopes(declaration)
        func rejectCircularAlias() throws {
            guard let circular = typeScopes.circularAliases.first else { return }
            try reject(
                circular.name,
                "Type alias '\(circular.name.unescaped)' names itself, directly or through other aliases; give it a type that does not depend on it."
            )
        }
        do {
            let schema = try parse(declaration, attribute: attribute, typeScopes: typeScopes)
            try rejectCircularAlias()
            return schema
        } catch {
            try rejectCircularAlias()
            throw error
        }
    }

    private func parse(
        _ declaration: EnumDeclSyntax,
        attribute: AttributeSyntax,
        typeScopes: LexicalScopes
    ) throws -> Schema {
        if let generic = declaration.genericParameterClause.map(Syntax.init)
            ?? declaration.genericWhereClause.map(Syntax.init)
        {
            try reject(generic, "Generic schemas are unsupported; declare a concrete schema enum.")
        }
        // A macro cannot tell which clause of `#if` the build takes, so it would read no member inside one, and a
        // phase, input, operation, or edge declared there would be missing from the graph. The macro reads the
        // schema's members and those of `Input`, `Scope`, and each operation and event namespace.
        let enums = declaration.memberBlock.members.compactMap { $0.decl.as(EnumDeclSyntax.self) }
            .filter { namespace in
                ["Input", "Scope"].contains(namespace.name.unescaped)
                    || namespace.attributes.contains {
                        $0.as(AttributeSyntax.self)
                            .map { Schema.namesMacro($0, "Operation") || Schema.namesMacro($0, "Event") }
                            ?? false
                    }
            }
        for member in Array(declaration.memberBlock.members) + enums.flatMap({ Array($0.memberBlock.members) }) {
            // An attribute inside `#if`, such as a marker or an availability, is one the macro cannot tell is there.
            for case .ifConfigDecl(let conditional) in member.decl.asProtocol(WithAttributesSyntax.self)?.attributes
                ?? []
            {
                try reject(
                    conditional,
                    "Move this '#if' out of the declaration's attributes: the macro cannot tell which clause the build takes, so it cannot tell which attributes the declaration has."
                )
            }
            guard let conditional = member.decl.as(IfConfigDeclSyntax.self) else { continue }
            try reject(
                conditional,
                "Move this '#if' outside the schema or into a function body: the macro cannot tell which clause the build takes, so it would read no declaration inside it."
            )
        }
        guard identifier(declaration.name.unescaped) else {
            try reject(
                declaration.name,
                "Name the schema with a Swift identifier that needs no backticks, such as one that is not a keyword."
            )
        }
        let root = try arguments(attribute, required: ["mode"], optional: ["owners"])
        guard let modeExpression = root["mode"] else {
            try reject(attribute, "Mode must be .shared, .isolated, or .ownedOnly.")
        }
        guard let mode = Schema.Mode(rawValue: try member(modeExpression)) else {
            try reject(modeExpression, "Mode must be .shared, .isolated, or .ownedOnly.")
        }
        let owners = try root["owners"].map { try self.owners($0, mode: mode) } ?? Schema.Owner.supported(by: mode)
        let members = declaration.memberBlock.members
        var initialCases: [EnumCaseDeclSyntax] = []
        var terminalCases: Set<String> = []
        for member in members {
            guard let attributed = member.decl.asProtocol(WithAttributesSyntax.self) else { continue }
            for name in ["Transition", "Route", "Operation", "Event", "Initial", "Terminal", "Restoration"] {
                guard let attribute = try marker(attributed.attributes, named: name) else { continue }
                switch name {
                case "Operation", "Event":
                    guard member.decl.is(EnumDeclSyntax.self) else {
                        try reject(attribute, "@\(name) must mark a nested enum namespace.")
                    }
                case "Initial", "Terminal":
                    guard let phase = member.decl.as(EnumCaseDeclSyntax.self), phase.elements.count == 1,
                        let element = phase.elements.first, attribute.arguments == nil
                    else {
                        // The arguments, the second case of the declaration, or a marker on another declaration.
                        let elements = member.decl.as(EnumCaseDeclSyntax.self).map { Array($0.elements) } ?? []
                        try reject(
                            attribute.arguments.map(Syntax.init) ?? elements.dropFirst().first.map { Syntax($0.name) }
                                ?? Syntax(attribute),
                            "@\(name) takes no arguments and must mark a declaration of one phase case directly inside the schema."
                        )
                    }
                    if name == "Initial" {
                        initialCases.append(phase)
                    } else {
                        terminalCases.insert(element.name.unescaped)
                    }
                default:
                    guard member.decl.is(FunctionDeclSyntax.self) else {
                        try reject(
                            attribute,
                            "@\(name) must mark a static function declared directly inside the schema."
                        )
                    }
                }
            }
        }
        guard initialCases.count == 1, let initial = initialCases.first?.elements.first?.name.unescaped else {
            // The second marker, or the schema's name when no case has one.
            let second = try initialCases.dropFirst().first.flatMap { try marker($0.attributes, named: "Initial") }
            try reject(
                second.map(Syntax.init) ?? Syntax(declaration.name),
                "Mark exactly one phase case with @Initial."
            )
        }
        // A name in a body may be written in any normalization form; one that is not composed has the bytes
        // of no name a generated alias takes, so it is left out, and every comparison with the set is exact.
        let authoredIdentifiers = Set(
            declaration.tokens(viewMode: .sourceAccurate)
                .compactMap { token -> String? in
                    guard case .identifier = token.tokenKind, token.isComposed else { return nil }
                    return token.lookupName
                }
        )
        // The checks of what the macro concluded from readings it cannot confirm, in declaration order.
        var checks = TypeChecks()
        var nominalNames: [String] = []
        var nestedEnums: [EnumDeclSyntax] = []
        var declaredNames: [String] = []
        for member in members {
            if let value = member.decl.as(StructDeclSyntax.self) {
                declaredNames.append(value.name.lookupName)
                if value.genericParameterClause == nil { nominalNames.append(value.name.lookupName) }
            } else if let value = member.decl.as(EnumDeclSyntax.self) {
                declaredNames.append(value.name.lookupName)
                nestedEnums.append(value)
                if value.genericParameterClause == nil { nominalNames.append(value.name.lookupName) }
            } else if let name = nestedTypeName(member.decl) {
                declaredNames.append(name)
            } else if let value = member.decl.as(FunctionDeclSyntax.self) {
                // Beside the generated `static let graph`, only a synchronous static method without
                // parameters is the same declaration; an instance method, an `async` one, or one that
                // takes arguments is another, as Swift's redeclaration rules have it.
                let name = value.name.lookupName
                let redeclaresGraph =
                    isStatic(value.modifiers) && value.signature.parameterClause.parameters.isEmpty
                    && value.signature.effectSpecifiers?.asyncSpecifier == nil
                if name != "graph" || redeclaresGraph {
                    declaredNames.append(name)
                }
            } else if let value = member.decl.as(VariableDeclSyntax.self) {
                // An instance property may share the name of the generated `static let graph`.
                declaredNames += value.bindings.flatMap { boundNames($0.pattern) }
                    .filter { $0 != "graph" || isStatic(value.modifiers) }
            }
        }
        let typeNames = Set(members.compactMap { nestedTypeName($0.decl) })
        // The inheritance clause is read where the schema is declared, outside its body, so a type the
        // body declares does not take a name it spells.
        let inherited = declaration.inheritanceClause?.inheritedTypes.map(\.type) ?? []
        let valueConformances = ["Equatable", "Hashable"]
            .filter { name in inherited.contains { Schema.names($0, name) } }
        // Generated types repeat each value conformance through the module, so a bare or dotted
        // spelling, which a declaration outside the schema could take, is checked on the schema itself.
        for name in valueConformances {
            for spelling in inherited where Schema.names(spelling, name) {
                checks.noteConformance(name, spelled: spelling)
            }
        }
        let rootCases = try cases(declaration, payloads: 1 ... 1, initial: initial)
        // Each phase case's payload type, where a refusal of the payload stands.
        var payloadNodes: [String: TypeSyntax] = [:]
        for member in members {
            for element in member.decl.as(EnumCaseDeclSyntax.self)?.elements ?? [] {
                payloadNodes[element.name.unescaped] = element.parameterClause?.parameters.first?.type
            }
        }
        func payloadNode(_ caseName: String) -> Syntax {
            payloadNodes[caseName].map(Syntax.init) ?? Syntax(declaration.name)
        }
        let phases = try rootCases.map { value -> Schema.Phase in
            guard let spelling = value.payloadType, let payload = value.payload,
                case let type = payloadName(payload.unparenthesized, schema: declaration.name.unescaped),
                identifier(type), nominalNames.contains(type), !["Input", "Effect", "Scope"].contains(type)
            else {
                try reject(
                    payloadNode(value.caseName),
                    "Phase '\(value.caseName)' needs a distinct nongeneric struct or enum declared directly inside the schema, named with a Swift identifier that needs no backticks; aliases are unsupported."
                )
            }
            return Schema.Phase(
                caseName: value.caseName,
                typeName: type,
                payloadSpelling: spelling,
                isTerminal: terminalCases.contains(value.caseName)
            )
        }
        guard !phases.isEmpty, Set(phases.map(\.typeName)).count == phases.count else {
            // The schema's name when it declares no phase, or the payload a later phase repeats.
            var seen: Set<String> = []
            let repeated = phases.first { !seen.insert($0.typeName).inserted }
            try reject(
                repeated.map { payloadNode($0.caseName) } ?? Syntax(declaration.name),
                "Declare at least one phase, with a different nested nominal payload type for every phase."
            )
        }
        // Each phase by its payload type, so a reference costs one lookup however many phases there are.
        let phaseCases = Dictionary(phases.map { ($0.typeName, $0.caseName) }, uniquingKeysWith: { first, _ in first })
        func phase(_ reference: (name: String, node: ExprSyntax)) throws -> String {
            guard let phase = phaseCases[reference.name] else {
                try reject(reference.node, "'\(reference.name)' is not a phase payload type declared in this schema.")
            }
            return phase
        }
        if let authored = nestedEnums.first(where: { $0.name.unescaped == "Effect" }) {
            try reject(
                authored.name,
                "Effect is generated from the @Operation namespaces; delete this declaration."
            )
        }
        let inputEnum = nestedEnums.first { $0.name.unescaped == "Input" }
        // An owned-only schema has no routing surface, so its edges can be taken without an input.
        guard inputEnum != nil || mode == .ownedOnly else {
            try reject(
                declaration.name,
                "Declare a closed Input enum directly inside the schema; an empty enum is allowed."
            )
        }
        let inputs = try inputEnum.map { try cases($0, payloads: 0 ... 1) } ?? []
        // A noncopyable model is held only by `Owned`; every other owner publishes snapshots of it, which
        // copy its phases.
        if suppressesCopyable(declaration), let keeper = owners.first(where: { $0 != .owned }) {
            try reject(
                declaration.name,
                "The schema is noncopyable, which only Owned supports: '.\(keeper.rawValue)' publishes snapshots that copy its phases; list only .owned in owners:, or make the schema and its phases copyable."
            )
        }
        // A noncopyable input is passed on once, by an `Owned` verb; every other owner keeps the input it
        // routes until a transition accepts it, which copies it.
        if let inputEnum, suppressesCopyable(inputEnum), let keeper = owners.first(where: { $0 != .owned }) {
            try reject(
                inputEnum.name,
                "Input is noncopyable, which only Owned supports: '.\(keeper.rawValue)' keeps each input it routes until a transition accepts it; list only .owned in owners:, or make Input copyable."
            )
        }
        // No input can carry a value of `Never`, so a case that carries it could never be sent. A case
        // the macro reads as one only through names it cannot confirm is checked where `Input` resolves
        // its payload, through the case's constructor.
        if let inputEnum, let inputScope = typeScopes.memberScope("Input") {
            for member in inputEnum.memberBlock.members {
                for element in member.decl.as(EnumCaseDeclSyntax.self)?.elements ?? [] {
                    guard let payload = element.parameterClause?.parameters.first else { continue }
                    let reading = try read(payload.type, in: inputScope, typeScopes)
                    guard reading.isNever else { continue }
                    let message =
                        "Input case '\(element.name.unescaped)' carries Never, so no input can ever have this case; remove the case, or give it a payload that has values."
                    guard !reading.confirmsShape else { try reject(payload.type, message) }
                    checks.require(.casePayloadIsNotNever(message: message), at: element.name.unescaped)
                }
            }
        }
        let allPhases = phases.map(\.caseName)
        let scopeEnum = nestedEnums.first { $0.name.unescaped == "Scope" }
        let scopes = try scopeEnum.map { try cases($0, payloads: 0 ... 0).map(\.caseName) } ?? []
        var scopeActiveIn: [String: [String]] = [:]
        for member in scopeEnum?.memberBlock.members ?? [] {
            guard let cases = member.decl.as(EnumCaseDeclSyntax.self),
                let active = try marker(cases.attributes, named: "Active")
            else { continue }
            guard cases.elements.count == 1, let scope = cases.elements.first?.name.unescaped else {
                try reject(
                    cases.elements.dropFirst().first.map { Syntax($0.name) } ?? Syntax(active),
                    "@Active(in:) must mark a declaration of one Scope case."
                )
            }
            guard let listed = try arguments(active, required: ["in"])["in"] else {
                try reject(active, "List the phases in which this scope stays active with @Active(in:).")
            }
            let named = try typeReferences(listed).map(phase)
            guard !named.isEmpty else { try reject(listed, "List at least one phase in @Active(in:).") }
            scopeActiveIn[scope] = allPhases.filter(named.contains)
        }
        /// The phases in which a named scope stays active.
        func namedScopePhases(_ scope: String) -> [String] { scopeActiveIn[scope] ?? allPhases }
        var operations: [Schema.Operation] = []
        var operationNodes: [String: EnumDeclSyntax] = [:]
        // The effect cases operations and events generate, each once.
        var effects: Set<String> = []
        // What each operation's edges and routers take, which decides every conclusion about its
        // outcomes that a reading the macro cannot confirm leaves open.
        let completed = authoredCompletions(members)
        for namespace in nestedEnums {
            guard let attribute = try marker(namespace.attributes, named: "Operation") else { continue }
            if let event = try marker(namespace.attributes, named: "Event") {
                // The conflict stands at the later marker.
                try reject(
                    attribute.position < event.position ? event : attribute,
                    "A namespace cannot be both an @Operation and an @Event."
                )
            }
            guard identifier(namespace.name.unescaped) else {
                try reject(
                    namespace.name,
                    "Name the operation with a Swift identifier that needs no backticks, such as one that is not a keyword."
                )
            }
            if let generic = namespace.genericParameterClause.map(Syntax.init)
                ?? namespace.genericWhereClause.map(Syntax.init)
            {
                try reject(generic, "Operation namespaces must be nongeneric enums.")
            }
            let metadata = try arguments(
                attribute,
                required: [],
                optional: ["scope", "requires", "activeIn", "admission"]
            )
            let effect = lowerCamel(namespace.name.unescaped)
            guard effect != namespace.name.unescaped, identifier(effect) else {
                try reject(
                    namespace.name,
                    "Operation '\(namespace.name.unescaped)' would generate the effect case '\(effect)', which is a keyword; rename the namespace with a capitalized, distinct name."
                )
            }
            guard effects.insert(effect).inserted else {
                try reject(
                    namespace.name,
                    "Operation '\(namespace.name.unescaped)' generates the same effect case '\(effect)' as another operation; rename one."
                )
            }
            // Without a named scope, the operation holds a private scope that no edge can invalidate.
            let scope = try metadata["scope"].map { try caseReference($0, in: "Scope") }
            let dependencies = try metadata["requires"].map { try caseReferences($0, in: "Scope") } ?? []
            let operationName = namespace.name.unescaped
            if scope != nil, let listed = metadata["activeIn"] {
                try reject(
                    listed,
                    "Operation '\(operationName)' runs in the phases of its scope's @Active(in:); remove activeIn:, or remove scope: to give the operation a private scope."
                )
            }
            guard scope != nil || metadata["activeIn"] != nil else {
                try reject(
                    attribute,
                    "Name the phases in which operation '\(operationName)' may run with activeIn:, or name the scope it holds with scope:."
                )
            }
            let activeReferences = try metadata["activeIn"].map(typeReferences)
            let privatePhases = try activeReferences.map { try $0.map(phase) }
            // The refusal stands at the scope that is not declared, the required scope that is not declared or
            // is the primary one, or the empty activeIn: list.
            let required = metadata["requires"]?.as(ArrayExprSyntax.self).map { Array($0.elements) } ?? []
            let misplaced: Syntax? =
                if let expression = metadata["scope"], let scope, !scopes.contains(scope) {
                    Syntax(expression)
                } else if let index = dependencies.firstIndex(where: { !scopes.contains($0) || $0 == scope }) {
                    index < required.count ? Syntax(required[index].expression) : metadata["requires"].map(Syntax.init)
                } else if let listed = metadata["activeIn"], privatePhases?.isEmpty == true {
                    Syntax(listed)
                } else {
                    nil
                }
            if let misplaced {
                try reject(
                    misplaced,
                    "Operation metadata must reference declared Scope cases, require no scope twice or as its own primary scope, and name at least one active phase."
                )
            }
            let primaryPhases = scope.map(namedScopePhases) ?? privatePhases ?? []
            let activeIn = allPhases.filter { phase in
                primaryPhases.contains(phase) && dependencies.allSatisfy { namedScopePhases($0).contains(phase) }
            }
            guard !activeIn.isEmpty else {
                try reject(
                    namespace.name,
                    "Operation '\(operationName)' can never run: no phase is active in its primary scope and every scope it requires; widen a scope's @Active(in:), or require fewer scopes."
                )
            }
            if let terminal = activeIn.first(where: terminalCases.contains) {
                let reason =
                    scope.map { scopeActiveIn[$0] == nil ? ", because its scope '\($0)' spans every phase" : "" } ?? ""
                // The activeIn: element that names the terminal phase, or the scope: argument.
                let listed = activeReferences?.first { $0.name == phaseType(terminal, in: phases) }
                try reject(
                    listed.map { Syntax($0.node) } ?? metadata["scope"].map(Syntax.init) ?? Syntax(attribute),
                    "Operation '\(operationName)' cannot be active in terminal phase '\(terminal)'\(reason); remove \(phaseType(terminal, in: phases)).self from the phases where it is active, or remove '@Terminal'."
                )
            }
            let aliases = namespace.memberBlock.members.compactMap { $0.decl.as(TypeAliasDeclSyntax.self) }
            if let misplaced = misplacedAlias(in: aliases, named: ["Input", "Output", "Failure", "Key"]) {
                try reject(
                    misplaced,
                    "An operation declares only nongeneric Input, Output, Failure, and Key typealiases, each at most once; an omitted Input or Output is Void, an omitted Failure is Never, and an omitted Key leaves the operation unkeyed."
                )
            }
            let types = Dictionary(uniqueKeysWithValues: aliases.map { ($0.name.unescaped, $0.initializer.value) })
            // The graph shows each alias's spelling as the author wrote it, on one line, kept once it is read.
            func spelled(_ name: String) -> String? { types[name].map { Schema.displaySpelling($0) } }
            // An alias resolves where it is declared, through the aliases the namespace and the schema
            // declare, so a type of the namespace or the schema named `Void` or `Never` shadows the
            // standard library's, and an alias of the standard library's type keeps its meaning.
            let namespaceScope = typeScopes.memberScope(operationName) ?? LexicalScopes.schema
            var readings: [String: ResolvedType] = [:]
            for alias in aliases {
                readings[alias.name.unescaped] = try read(alias.initializer.value, in: namespaceScope, typeScopes)
            }
            let authored = completed[operationName] ?? AuthoredCompletions()
            // Each conclusion is drawn from a confirmed reading, or else from what the author wrote
            // elsewhere, and the expansion checks an unconfirmed one on the alias itself, which names the
            // type however its spelling resolves. A definite diagnostic rests on a confirmed reading.
            func check(_ kind: Schema.TypeCheck.Kind, _ name: String) {
                checks.require(kind, at: "\(operationName).\(name)")
            }
            // The input is omitted when the macro reads it as `Void`. A completion that takes the request
            // of an operation without a key says it has an input, which then is carried as it is. Carriage
            // is decided first, because what an omitted input must be and what a carried one must be differ.
            let isKeyed = types["Key"] != nil
            var takesInput = false
            if let reading = readings["Input"] {
                takesInput = !reading.isVoid || (!reading.confirmsShape && !isKeyed && authored.takesRequest)
                // An omitted input must be `Void`, which also rules out `Never`.
                if reading.isVoid, !reading.confirmsShape, !takesInput { check(.isStandard("Void"), "Input") }
            }
            // An effect that carries `Never` can never be constructed, so no transition could start the work.
            // A carried input, and every key, must have values, whatever the macro reads them as.
            for alias in aliases where ["Input", "Key"].contains(alias.name.unescaped) {
                let name = alias.name.unescaped
                guard let reading = readings[name], !reading.confirmsValues, name == "Key" || takesInput else {
                    continue
                }
                let message =
                    "Operation '\(operationName)' takes Never as its \(name.lowercased()), so no transition can start it; declare a\(name == "Input" ? "n input" : " key") type that has values, or remove the operation."
                guard !reading.isConfirmedNever else { try reject(alias.initializer.value, message) }
                check(.isNotNever(message: message), name)
            }
            // An outcome happens unless the macro confirms its type is `Never`; with an unconfirmed reading,
            // the author's edges and routers say whether it happens, and the expansion checks the type.
            let output = readings["Output"]
            let failure = readings["Failure"]
            let neverSucceeds: Bool
            if let output, output.isConfirmedNever {
                neverSucceeds = true
            } else if output?.confirmsValues ?? true {
                neverSucceeds = false
            } else {
                neverSucceeds = !authored.succeeds
            }
            let isInfallible: Bool
            if let failure {
                if failure.isConfirmedNever {
                    isInfallible = true
                } else if failure.confirmsValues {
                    isInfallible = false
                } else {
                    isInfallible = !authored.fails
                }
            } else {
                isInfallible = true
            }
            // A success carries no value when the macro confirms the output is `Void`; with an unconfirmed
            // reading, when no success edge or router takes an output parameter.
            let producesVoid: Bool
            if let output, !output.confirmsShape {
                producesVoid = !authored.takesOutput
            } else {
                producesVoid = output?.isVoid ?? true
            }
            if let output, !output.confirmsShape {
                if neverSucceeds {
                    check(
                        .isStandard(
                            "Never",
                            message:
                                "Operation '\(operationName)' has no onSuccess: edge or router, so the macro reads its Output as Never, but it resolves to a type with values; declare an onSuccess: edge or router for it in each phase where it is active, or declare its Output as Never."
                        ),
                        "Output"
                    )
                } else if producesVoid {
                    check(
                        .isStandard(
                            "Void",
                            message:
                                "Operation '\(operationName)' succeeds without output, as its onSuccess: edges and routers take none, but its Output resolves to a type other than Void; take the output after the source, or declare its Output as Void."
                        ),
                        "Output"
                    )
                } else {
                    check(
                        .isNotNever(
                            message:
                                "Operation '\(operationName)' never succeeds: its Output is Never, so its onSuccess: edges and routers can never run; remove them, or declare the Output the operation produces."
                        ),
                        "Output"
                    )
                }
            }
            if let failure, !failure.confirmsShape {
                check(
                    isInfallible
                        ? .isStandard(
                            "Never",
                            message:
                                "Operation '\(operationName)' has no onFailure: edge or router, so the macro reads its Failure as Never, but it resolves to a type with values; declare an onFailure: edge or router for it in each phase where it is active, or declare its Failure as Never."
                        )
                        : .isNotNever(
                            message:
                                "Operation '\(operationName)' cannot fail: its Failure is Never, so its onFailure: edges and routers can never run; remove them, or declare the Failure the operation reports."
                        ),
                    "Failure"
                )
            }
            if neverSucceeds, isInfallible {
                let message =
                    "Operation '\(operationName)' can never finish: its Output and its Failure are both Never, so its driver could never return, even once its work is cancelled; declare the Output it produces, or a Failure it reports when it stops."
                // Each unconfirmed reading is checked to be `Never`, and then the pair is rejected.
                let confirmed = (output?.confirmsShape ?? true) && (failure?.confirmsShape ?? true)
                guard !confirmed else { try reject(namespace.name, message) }
                checks.require(.finishes(message: message), at: operationName)
            }
            let policy = try metadata["admission"].map(admission) ?? .latest
            operations.append(
                Schema.Operation(
                    name: namespace.name.unescaped,
                    effect: effect,
                    scope: scope,
                    requires: dependencies,
                    activeIn: activeIn,
                    privatePhases: privatePhases,
                    admission: policy,
                    // An omitted type is spelled through its module, which no declaration can shadow.
                    inputType: spelled("Input") ?? "Swift::Void",
                    outputType: spelled("Output") ?? "Swift::Void",
                    failureType: spelled("Failure") ?? "Swift::Never",
                    declaresInput: types["Input"] != nil,
                    declaresOutput: types["Output"] != nil,
                    declaresFailure: types["Failure"] != nil,
                    keyType: spelled("Key"),
                    takesInput: takesInput,
                    producesVoid: producesVoid,
                    isInfallible: isInfallible,
                    neverSucceeds: neverSucceeds,
                    inputEscapes: readings["Input"]?.isConfirmedFunction ?? false
                )
            )
            operationNodes[operationName] = namespace
        }
        var events: [Schema.Event] = []
        for namespace in nestedEnums where try marker(namespace.attributes, named: "Event") != nil {
            guard identifier(namespace.name.unescaped) else {
                try reject(
                    namespace.name,
                    "Name the event with a Swift identifier that needs no backticks, such as one that is not a keyword."
                )
            }
            if let generic = namespace.genericParameterClause.map(Syntax.init)
                ?? namespace.genericWhereClause.map(Syntax.init)
            {
                try reject(generic, "Event namespaces must be nongeneric enums.")
            }
            let effect = lowerCamel(namespace.name.unescaped)
            guard effect != namespace.name.unescaped, identifier(effect) else {
                try reject(
                    namespace.name,
                    "Event '\(namespace.name.unescaped)' would generate the effect case '\(effect)', which is a keyword; rename the namespace with a capitalized, distinct name."
                )
            }
            guard effects.insert(effect).inserted else {
                try reject(
                    namespace.name,
                    "Event '\(namespace.name.unescaped)' generates the same effect case '\(effect)' as another operation or event; rename one."
                )
            }
            let aliases = namespace.memberBlock.members.compactMap { $0.decl.as(TypeAliasDeclSyntax.self) }
            if let misplaced = misplacedAlias(in: aliases, named: ["Payload"]) {
                try reject(
                    misplaced,
                    "An event declares only a nongeneric Payload typealias, at most once; an omitted Payload is Void."
                )
            }
            let payload = aliases.first?.initializer.value
            let eventScope = typeScopes.memberScope(namespace.name.unescaped) ?? LexicalScopes.schema
            let reading = try payload.map { try read($0, in: eventScope, typeScopes) }
            // An effect that carries `Never` can never be constructed, so no transition could emit the event.
            // A payload read as `Void` is omitted, which is checked; any other reading the macro cannot
            // confirm is carried, and checked not to be `Never` with the message that rejects one.
            if let alias = aliases.first, let reading, !reading.confirmsValues || reading.isNever {
                let message =
                    "Event '\(namespace.name.unescaped)' carries Never, so no transition can emit it; declare a payload type that has values, or remove the event."
                if reading.isConfirmedNever { try reject(alias.initializer.value, message) }
                checks.require(
                    reading.isVoid ? .isStandard("Void") : .isNotNever(message: message),
                    at: "\(namespace.name.unescaped).Payload"
                )
            }
            events.append(
                Schema.Event(
                    name: namespace.name.unescaped,
                    effect: effect,
                    payloadType: payload.map { Schema.displaySpelling($0) } ?? "Swift::Void",
                    declaresPayload: !aliases.isEmpty,
                    takesPayload: !(reading?.isVoid ?? true)
                )
            )
        }
        // `Local`'s `Command` cancels work through its own `cancel` case, beside a case per operation
        // and event, and it exists only with operations. Enum cases cannot share a name whatever they
        // carry. A case beside a property of its name, as `Completion`'s `authority` case would be,
        // is a different declaration.
        if owners.contains(.local), !operations.isEmpty {
            for (kind, name, effect) in operations.map({ ("Operation", $0.name, $0.effect) })
                + events.map({ ("Event", $0.name, $0.effect) }) where effect == "cancel"
            {
                try reject(
                    nestedEnums.first { $0.name.unescaped == name }.map { Syntax($0.name) } ?? Syntax(declaration.name),
                    "\(kind) '\(name)' would generate the case 'cancel' in Local's Command, which already has a cancel case that cancels work; rename the namespace with a distinct capitalized name."
                )
            }
        }
        // A managed owner's initializers take each operation's driver, `<effect>Driver:`, and each
        // event's handler, `on<Event>:`, as parameters of one list.
        if owners.contains(where: { [.shared, .actorHost, .mainActorHost, .isolatedHost].contains($0) }) {
            let drivers = Dictionary(
                operations.map { ("\($0.effect)Driver", $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for event in events {
                guard let operation = drivers[event.handler] else { continue }
                try reject(
                    nestedEnums.first { $0.name.unescaped == event.name }.map { Syntax($0.name) }
                        ?? Syntax(declaration.name),
                    "Operation '\(operation.name)' and event '\(event.name)' both name the managed initializer parameter '\(event.handler)', the operation's driver and the event's handler; rename one."
                )
            }
        }
        let triggerLabels: Set<String> = ["on", "onSuccess", "onFailure"]
        // The declarations functions name, each by its name, so every reference costs one lookup.
        let inputsByName = Dictionary(inputs.map { ($0.caseName, $0) }, uniquingKeysWith: { first, _ in first })
        let operationsByName = Dictionary(operations.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let eventsByName = Dictionary(events.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var transitions: [Schema.Transition] = []
        var routes: [Schema.Route] = []
        /// The authored spelling of each transition declaration's effect type, checked once every edge is known.
        var effectChecks: [(declaration: Int, node: Syntax, form: EffectForm)] = []
        /// Each router's authored result type, checked once every edge is known.
        var routeResults: [Int: TypeSyntax] = [:]
        /// The authored functions, by position, for diagnostics that need every edge.
        var functions: [Int: FunctionDeclSyntax] = [:]
        // An edge's name is unique among the edges and routers that leave one phase; the same name may
        // leave several phases, as Swift overloads on the source payload.
        var phasesByName: [String: Set<String>] = [:]
        let edgeFunctionNames = Set(
            members.compactMap { member -> String? in
                guard let function = member.decl.as(FunctionDeclSyntax.self),
                    function.attributes.contains(where: { element in
                        guard let attribute = element.as(AttributeSyntax.self) else { return false }
                        return Schema.namesMacro(attribute, "Transition") || Schema.namesMacro(attribute, "Route")
                    })
                else { return nil }
                return function.name.unescaped
            }
        )
        for (position, member) in members.enumerated() {
            guard let function = member.decl.as(FunctionDeclSyntax.self) else { continue }
            let transitionAttribute = try marker(function.attributes, named: "Transition")
            let routeAttribute = try marker(function.attributes, named: "Route")
            // A conflict between markers stands at the later one.
            func later(_ first: AttributeSyntax, _ second: AttributeSyntax) -> AttributeSyntax {
                first.position < second.position ? second : first
            }
            if let transitionAttribute, let routeAttribute {
                try reject(
                    later(transitionAttribute, routeAttribute),
                    "A function cannot be both a transition and a router."
                )
            }
            if let restorationAttribute = try marker(function.attributes, named: "Restoration"),
                let edgeAttribute = transitionAttribute ?? routeAttribute
            {
                try reject(
                    later(restorationAttribute, edgeAttribute),
                    "A @Restoration function cannot also be a transition or a router."
                )
            }
            guard let attribute = transitionAttribute ?? routeAttribute else {
                if edgeFunctionNames.contains(function.name.unescaped) {
                    try reject(
                        function.name,
                        "'\(function.name.unescaped)' names a transition or router; a function that is neither cannot share its name."
                    )
                }
                continue
            }
            functions[position] = function
            guard identifier(function.name.unescaped) else {
                try reject(
                    function.name,
                    "Name the transition or router with a Swift identifier that needs no backticks, such as one that is not a keyword."
                )
            }
            let isRoute = routeAttribute != nil
            if isRoute && mode == .ownedOnly {
                try reject(
                    attribute,
                    "@Route requires hosted observations and is unavailable in .ownedOnly; select consuming edges in the caller."
                )
            }
            let deprecation = try validateFunction(
                function,
                role: isRoute ? "Routers" : "Transitions",
                allowsRequest: true,
                schema: declaration.name.unescaped
            )
            let metadata = try arguments(
                attribute,
                required: [],
                optional: isRoute
                    ? triggerLabels.union(["failure"])
                    : triggerLabels.union(["from", "invalidates", "starts", "cancels", "emits"])
            )
            let (on, input, operation) = try trigger(
                metadata,
                attribute: attribute,
                inputs: inputsByName,
                operations: operationsByName,
                direct: mode == .ownedOnly && !isRoute ? function.name.unescaped : nil,
                role: isRoute ? "router" : "transition"
            )
            let parameters = Array(function.signature.parameterClause.parameters)
            // A success of an operation whose output is `Void` carries nothing, so its edge or router
            // takes no output parameter.
            let omitsOutput = on.kind == .success && operation?.producesVoid == true
            let needsPayload = (operation != nil && !omitsOutput) || input?.payloadType != nil
            let outcome = on.kind == .failure ? "failure" : "output"
            // A completion edge or router takes its operation's request in the parameter labeled
            // `request:`, after every other parameter, and no other function takes one: the label, not
            // the parameter's type, says which parameter is the request.
            let requestPosition = parameters.firstIndex(where: Self.takesRequest)
            if let requestPosition {
                let labeled = parameters[requestPosition]
                guard operation != nil else {
                    try reject(
                        labeled,
                        "Only a completion edge or router takes its operation's request, labeled request:; take this parameter without a label."
                    )
                }
                if let repeated = parameters[(requestPosition + 1)...].first(where: Self.takesRequest) {
                    try reject(repeated, "Take the operation's request once, in the last parameter, labeled request:.")
                }
                guard requestPosition > 0 else {
                    try reject(
                        labeled,
                        "Take the source phase payload first, without a label, and the request last, labeled request:."
                    )
                }
                guard requestPosition == parameters.count - 1 else {
                    try reject(
                        labeled,
                        omitsOutput
                            ? "Take the request last, labeled request:; this success takes no output, so the request directly follows the source."
                            : "Take the request last, labeled request:, after the source and the operation's \(outcome)."
                    )
                }
            }
            // The parameters other than the request: the source, when the function takes one, then the
            // trigger payload, when it carries one.
            let values = parameters.filter { !Self.takesRequest($0) }
            // A transition that lists its sources in `from:` takes no source parameter and has an edge per source.
            let sources: [String]
            /// The `from:` elements that name the sources, when the transition lists them.
            var sourceReferences: [(name: String, node: ExprSyntax)] = []
            let base: TypeSyntax?
            if let list = metadata["from"] {
                guard on.kind == .input || on.kind == .direct else {
                    try reject(
                        list,
                        "Only an input transition lists its source phases in from:; a completion edge names its source in its first parameter."
                    )
                }
                sourceReferences = try typeReferences(list)
                sources = try sourceReferences.map(phase)
                guard !sources.isEmpty else { try reject(list, "List at least one source phase in from:.") }
                guard parameters.count == (needsPayload ? 1 : 0) else {
                    try reject(
                        function.signature.parameterClause,
                        needsPayload
                            ? "A transition that lists its source phases in from: takes only the trigger payload parameter."
                            : "A transition that lists its source phases in from: takes no parameters."
                    )
                }
                base = nil
            } else {
                // A completion edge or router may also take the request its work was started with.
                let required = needsPayload ? 2 : 1
                if let operation, values.count >= 1 {
                    let kind = isRoute ? "router" : "edge"
                    // A success without output carries nothing to take after the source.
                    if omitsOutput, values.count >= 2 {
                        try reject(
                            values[1],
                            "Operation '\(operation.name)' succeeds without output, so its success \(kind) takes no output parameter; remove this parameter, and take the operation's request, if any, labeled request:."
                        )
                    }
                    // An outcome that carries a value is taken after the source, before the request.
                    if needsPayload, values.count == 1 {
                        try reject(
                            requestPosition.map { Syntax(parameters[$0]) }
                                ?? Syntax(function.signature.parameterClause),
                            on.kind == .success
                                ? "Operation '\(operation.name)' succeeds with output, so its success \(kind) takes the output, unlabeled, after the source, then the request, if any, labeled request:."
                                : "A failure \(kind) takes its operation's failure, unlabeled, after the source, then the request, if any, labeled request:."
                        )
                    }
                }
                guard values.count == required else {
                    try reject(
                        function.signature.parameterClause,
                        operation != nil
                            ? (omitsOutput
                                ? "This trigger requires a source parameter, and optionally the operation's request, labeled request:."
                                : "This trigger requires source and trigger payload parameters, and optionally the operation's request, labeled request:.")
                            : "This trigger requires \(needsPayload ? "source and trigger payload parameters" : "only a source parameter")."
                    )
                }
                let sourceNode: TypeSyntax
                let sourceParameter = parameters[0].type.unparenthesized
                if let attributed = sourceParameter.as(AttributedTypeSyntax.self) {
                    // An edge borrows its source, or in `.ownedOnly` takes it as its own, read as a payload's
                    // ownership is: `__shared` lends it as `borrowing` does, and `__owned` takes it as
                    // `consuming` does.
                    let ownership = attributed.specifiers.first?.as(SimpleTypeSpecifierSyntax.self)?.specifier.text
                    guard attributed.attributes.isEmpty, attributed.specifiers.count == 1, let ownership,
                        ["borrowing", "__shared", "consuming", "__owned"].contains(ownership),
                        Schema.ownsPayload(ownership: ownership + " ", convention: "") == (mode == .ownedOnly)
                    else {
                        // The attribute or specifier the source may not have, or the one it has in place of
                        // the ownership it needs.
                        let fits = ownership.map {
                            ["borrowing", "__shared", "consuming", "__owned"].contains($0)
                                && Schema.ownsPayload(ownership: $0 + " ", convention: "") == (mode == .ownedOnly)
                        }
                        let offending =
                            attributed.attributes.first.map(Syntax.init)
                            ?? attributed.specifiers.dropFirst(fits == true ? 1 : 0).first.map(Syntax.init)
                            ?? Syntax(attributed)
                        try reject(
                            offending,
                            mode == .ownedOnly
                                ? "Use an explicitly consuming phase payload as the source parameter."
                                : "Use a plain or borrowing phase payload as the source parameter."
                        )
                    }
                    sourceNode = attributed.baseType.unparenthesized
                } else {
                    guard mode != .ownedOnly else {
                        try reject(
                            sourceParameter,
                            "Use an explicitly consuming phase payload as the source parameter."
                        )
                    }
                    sourceNode = sourceParameter
                }
                let sourceType = payloadName(sourceNode, schema: declaration.name.unescaped)
                guard let from = phaseCases[sourceType] else {
                    try reject(
                        sourceNode,
                        "Source '\(sourceType)' is not a phase payload type declared in this schema."
                    )
                }
                sources = [from]
                base = sourceNode
            }
            guard let primary = sources.first else {
                try reject(function.name, "List at least one source phase in from:.")
            }
            for source in sources {
                guard phasesByName[function.name.unescaped, default: []].insert(source).inserted else {
                    try reject(
                        function.name,
                        "'\(phaseType(source, in: phases))' already has an edge or router named '\(function.name.unescaped)'; give each edge from one phase a distinct name."
                    )
                }
            }
            if let operation, !operation.activeIn.contains(primary) {
                try reject(
                    base.map(Syntax.init) ?? Syntax(attribute),
                    "Completion edges must start in an operation's activeIn phase."
                )
            }
            if let index = sources.firstIndex(where: terminalCases.contains) {
                let terminal = sources[index]
                // The `from:` element that names the terminal phase, or the source parameter.
                try reject(
                    index < sourceReferences.count ? Syntax(sourceReferences[index].node) : Syntax(parameters[0]),
                    "Terminal phase '\(terminal)' cannot have an outgoing \(isRoute ? "router" : "transition") '\(function.name.unescaped)'; remove '@Terminal', or remove the \(isRoute ? "router" : "transition")."
                )
            }
            // Generated methods inside nested types repeat these spellings, where `Self` names another type.
            let schemaName = declaration.name.unescaped
            let payload =
                try needsPayload ? parameter(values[base == nil ? 0 : 1], schema: schemaName, role: "payload") : nil
            let payloadType = payload?.type
            // A payload of an `.isolated` schema need not be `Sendable`, so generated code hands it to a
            // `sending` parameter as it is only from a value it holds alone and uses once. An observing
            // owner keeps an input it receives and each outcome until a transition accepts it, so there
            // the expansion requires the type to be `Sendable`, which a value of it can be shared as; an
            // `Owned` router's reuse is decided once its candidates are known.
            let observing = owners.contains { $0 != .owned }
            if mode == .isolated, let payload, payload.convention.contains("sending"), observing {
                checks.require(.isSendable, at: payload.type)
            }
            let request = try requestPosition.map { position in
                try parameter(parameters[position], schema: schemaName, role: "request")
            }
            let requestType = request?.type
            if let requestPosition, let operation, !operation.hasRequest {
                try reject(
                    parameters[requestPosition],
                    "Operation '\(operation.name)' has no Key and takes no input, so its completion carries no request; remove this parameter."
                )
            }
            // An observing owner keeps each request with its outcome, so a request it passes as `sending`
            // must be `Sendable`, which a request is exactly when its input is.
            if mode == .isolated, request?.convention.contains("sending") == true, observing, let operation,
                operation.takesInput
            {
                checks.require(.isSendable, at: operation.request)
            }
            // A transition becomes a method of each phase wrapper the owners use; a router's methods
            // exist only once it has edges to choose, which is checked after every edge is known.
            if !isRoute {
                let owned = (payloadType == nil ? [] : ["_"]) + (requestType == nil ? [] : ["request"])
                let observed = on.kind == .input ? (payloadType == nil ? [] : ["_"]) : nil
                try checkWrapperMembers(function, owned: owned, observed: observed, owners: owners, role: "transition")
            }
            let thrown = try thrownType(
                function,
                owner: position,
                schema: schemaName,
                scopes: typeScopes,
                checks: &checks
            )
            guard let result = function.signature.returnClause?.type.unparenthesized else {
                try reject(function.signature, "Return the destination phase payload, a Change, or a Route choice.")
            }
            if isRoute {
                let pinned = try metadata["failure"]
                    .map { expression -> String in
                        guard on.kind == .input else {
                            try reject(
                                expression,
                                "Only an input router pins its failure with failure:; delivery reports a completion router's failure."
                            )
                        }
                        guard let member = expression.as(MemberAccessExprSyntax.self), let typeBase = member.base,
                            member.declName.baseName.tokenKind == .keyword(.self), member.declName.argumentNames == nil
                        else { try reject(expression, "Name the pinned failure type as <Failure>.self.") }
                        return outsideSchema(
                            spellings.type(typeBase.trimmedDescription),
                            schema: declaration.name.unescaped
                        )
                    }
                routes.append(
                    Schema.Route(
                        name: function.name.unescaped,
                        from: primary,
                        trigger: on,
                        sourceType: base?.trimmedDescription ?? "",
                        payloadType: payloadType,
                        payloadConvention: payload?.convention ?? "",
                        payloadOwnership: payload?.ownership ?? "",
                        failureType: thrown,
                        pinnedFailure: pinned,
                        namespace: nil,
                        choices: [],
                        declaration: position,
                        requestType: requestType,
                        requestConvention: request?.convention ?? "",
                        deprecation: deprecation
                    )
                )
                routeResults[position] = result
                continue
            }
            var started: [Schema.Operation] = []
            let startReferences = try metadata["starts"].map(typeReferences) ?? []
            for reference in startReferences {
                guard let operation = operationsByName[reference.name] else {
                    try reject(
                        reference.node,
                        eventsByName[reference.name] != nil
                            ? "'\(reference.name)' is an @Event; list it in emits:."
                            : "'\(reference.name)' is not a declared @Operation namespace."
                    )
                }
                started.append(operation)
            }
            var cancelled: [Schema.Operation] = []
            for reference in try metadata["cancels"].map(typeReferences) ?? [] {
                guard let operation = operationsByName[reference.name] else {
                    try reject(
                        reference.node,
                        eventsByName[reference.name] != nil
                            ? "'\(reference.name)' is an @Event, which has no work to cancel."
                            : "'\(reference.name)' is not a declared @Operation namespace."
                    )
                }
                guard operation.isKeyed else {
                    try reject(
                        reference.node,
                        "'\(reference.name)' declares no Key, so it has no work to cancel by key; declare a Key, or revoke its work by invalidating its scope with invalidates:."
                    )
                }
                cancelled.append(operation)
            }
            var emitted: [Schema.Event] = []
            for reference in try metadata["emits"].map(typeReferences) ?? [] {
                guard let event = eventsByName[reference.name] else {
                    try reject(
                        reference.node,
                        operationsByName[reference.name] != nil
                            ? "'\(reference.name)' is an @Operation; list it in starts:."
                            : "'\(reference.name)' is not a declared @Event namespace."
                    )
                }
                emitted.append(event)
            }
            let effectNamespace =
                started.isEmpty && emitted.isEmpty && cancelled.isEmpty
                ? nil : Schema.companion(function.name.unescaped)
            if let effectNamespace, ["Effect", "Type", "Protocol"].contains(effectNamespace) {
                try reject(
                    function.name,
                    "This transition's effect type would be Effect.\(effectNamespace), which is unavailable; rename the transition."
                )
            }
            // Generated code inside `Effect` names the schema's own types through the schema's name.
            if let effectNamespace, effectNamespace == declaration.name.unescaped {
                try reject(
                    function.name,
                    "This transition's effect type would be Effect.\(effectNamespace), which hides the schema '\(declaration.name.unescaped)' inside Effect; rename the transition."
                )
            }
            var failureType = thrown
            let shape: Schema.Transition.Shape
            let destinationNode: TypeSyntax
            if let arguments = runtimeGenericArguments(result, named: "Advance"), arguments.count == 4 {
                let list = Array(arguments)
                guard mode == .ownedOnly, let destination = list[1].type else {
                    try reject(
                        result,
                        "Advance<Source, Destination, Effect, Failure> is the owned-only form; value transitions use typed throws."
                    )
                }
                guard base != nil else {
                    try reject(
                        result,
                        "A transition that lists its source phases in from: has no one source to give back; return its destination or a Change."
                    )
                }
                shape = .advance
                destinationNode = destination
                failureType = outsideSchema(
                    list[3].type?.trimmed ?? spellings.type(list[3].argument.trimmedDescription),
                    schema: schemaName
                )
                effectChecks.append(
                    (
                        position, Syntax(list[2]),
                        .advance(list[2].type?.trimmedDescription ?? list[2].argument.trimmedDescription)
                    )
                )
            } else if let arguments = runtimeGenericArguments(result, named: "Change"), arguments.count == 2 {
                let list = Array(arguments)
                guard let destination = list[0].type else {
                    try reject(result, "Change must name the destination phase payload type.")
                }
                guard effectNamespace != nil else {
                    try reject(
                        result,
                        "This transition starts no operation, cancels no work, and emits no event; return \(destination.trimmedDescription) directly."
                    )
                }
                shape = .change
                destinationNode = destination
                effectChecks.append(
                    (
                        position, Syntax(list[1]),
                        .change(list[1].type?.trimmedDescription ?? list[1].argument.trimmedDescription)
                    )
                )
            } else {
                if effectNamespace != nil {
                    effectChecks.append((position, Syntax(result), .destination(result.trimmedDescription)))
                }
                shape = .destination
                destinationNode = result
            }
            if mode == .ownedOnly, thrown != nil, let throwsClause = function.signature.effectSpecifiers?.throwsClause {
                try reject(
                    throwsClause,
                    "Owned-only transitions cannot throw; return Advance<Source, Destination, Effect, Failure> to give the source back."
                )
            }
            let destinationType = payloadName(destinationNode, schema: declaration.name.unescaped)
            guard let to = phaseCases[destinationType] else {
                try reject(
                    destinationNode,
                    "Destination '\(destinationType)' is not a phase payload type declared in this schema."
                )
            }
            let invalidates = try metadata["invalidates"].map { try caseReferences($0, in: "Scope") } ?? []
            if let listed = metadata["invalidates"], let index = invalidates.firstIndex(where: { !scopes.contains($0) })
            {
                // The element that names an undeclared scope.
                let elements = listed.as(ArrayExprSyntax.self).map { Array($0.elements) } ?? []
                try reject(
                    index < elements.count ? Syntax(elements[index].expression) : Syntax(listed),
                    "invalidates must reference declared Scope cases."
                )
            }
            // An operation runs only where its primary scope and every required scope are active.
            for (operation, reference) in zip(started, startReferences) {
                guard operation.activeIn.contains(to) else {
                    try reject(
                        reference.node,
                        "Started operation '\(operation.name)' and every required scope must be eligible in destination '\(destinationType)'."
                    )
                }
            }
            for source in sources {
                transitions.append(
                    Schema.Transition(
                        name: function.name.unescaped,
                        from: source,
                        to: to,
                        trigger: on,
                        invalidates: invalidates,
                        starts: started.map(\.effect),
                        cancels: cancelled.map(\.effect),
                        emits: emitted.map(\.effect),
                        payloadType: payloadType,
                        payloadConvention: payload?.convention ?? "",
                        payloadOwnership: payload?.ownership ?? "",
                        sourceType: base?.trimmedDescription,
                        returnType: result.trimmedDescription,
                        failureType: failureType,
                        shape: shape,
                        effectNamespace: effectNamespace,
                        declaration: position,
                        sources: sources,
                        requestType: requestType,
                        requestConvention: request?.convention ?? "",
                        deprecation: deprecation
                    )
                )
            }
        }
        // A router chooses among the edges that share its source and trigger, so its result type
        // can only be checked once every edge is known.
        // The edges of each source and trigger, in declaration order, found once for every router.
        let edgesByPair = Dictionary(grouping: transitions) { SourceTrigger(from: $0.from, trigger: $0.trigger) }
        routes = routes.map { route in
            let choices = (edgesByPair[SourceTrigger(from: route.from, trigger: route.trigger)] ?? []).map(\.name)
            return Schema.Route(
                name: route.name,
                from: route.from,
                trigger: route.trigger,
                sourceType: route.sourceType,
                payloadType: route.payloadType,
                payloadConvention: route.payloadConvention,
                payloadOwnership: route.payloadOwnership,
                failureType: route.failureType,
                pinnedFailure: route.pinnedFailure,
                namespace: choices.isEmpty ? nil : Schema.companion(route.name),
                choices: choices,
                declaration: route.declaration,
                requestType: route.requestType,
                requestConvention: route.requestConvention,
                deprecation: route.deprecation
            )
        }
        // A router with no edge to choose can only reject, so it throws: a throws clause the macro reads
        // as `Never` without confirming it names a type with values, which the expansion checks. One
        // spelling names one type at the schema's scope, so every function that throws it throws.
        var throwing: Set<String> = []
        for (index, route) in routes.enumerated() where route.namespace == nil && route.failureType == nil {
            guard
                let type = functions[route.declaration]?.signature.effectSpecifiers?.throwsClause?.type?.unparenthesized
            else {
                continue
            }
            let thrown = try read(type, typeScopes)
            guard thrown.isNever, !thrown.confirmsShape else { continue }
            let spelled = outsideSchema(type, schema: declaration.name.unescaped)
            routes[index].failureType = spelled
            throwing.insert(Schema.spellingKey(type))
        }
        func throwsRevised(_ declaration: Int) -> TypeSyntax? {
            guard let type = functions[declaration]?.signature.effectSpecifiers?.throwsClause?.type?.unparenthesized,
                throwing.contains(Schema.spellingKey(type))
            else { return nil }
            return type
        }
        for index in transitions.indices where transitions[index].failureType == nil {
            guard let type = throwsRevised(transitions[index].declaration) else { continue }
            transitions[index].failureType = outsideSchema(type, schema: declaration.name.unescaped)
        }
        for index in routes.indices where routes[index].failureType == nil {
            guard let type = throwsRevised(routes[index].declaration) else { continue }
            routes[index].failureType = outsideSchema(type, schema: declaration.name.unescaped)
        }
        for position in functions.keys.sorted() {
            guard let type = throwsRevised(position) else { continue }
            let spelled = outsideSchema(type, schema: declaration.name.unescaped)
            checks.remove(.isStandard("Never"), at: spelled, owner: position)
            checks.require(
                .isNotNever(message: "A router with no edge to choose returns Never and throws a typed rejection."),
                at: spelled,
                owner: position
            )
        }
        // An `Owned` router of an `.isolated` schema runs in a method that lends the payload and the request
        // to the router and then passes them to the edge it selects, so what an edge may send there is
        // decided by every value the router joins, measured against Swift's region checker:
        //
        // - a value the router takes as `sending` and an edge then takes must be `Sendable`;
        // - a value one edge takes as `sending` and another takes without must be `Sendable`, because
        //   the method keeps the value it may give away;
        // - a value an edge takes as `sending` that the router reads without it joins the source phase
        //   and every other value the router reads that way, so the value, or each of those, must be
        //   `Sendable`; another value is exempt when the method receives it as `sending`, because some
        //   function of the group sends it, and that edge leaves it out.
        //
        // Each is checked by the expansion with a message, because only the compiler knows which types
        // are `Sendable`.
        if mode == .isolated, !owners.contains(where: { $0 != .owned }) {
            // Each edge by its source and name, the first declared, found once for every router.
            var named: [String: [String: Int]] = [:]
            for (index, edge) in transitions.enumerated() where named[edge.from]?[edge.name] == nil {
                named[edge.from, default: [:]][edge.name] = index
            }
            let byEffect = Dictionary(operations.map { ($0.effect, $0) }, uniquingKeysWith: { first, _ in first })
            let phaseTypes = Dictionary(
                phases.map { ($0.caseName, $0.typeName) },
                uniquingKeysWith: { first, _ in first }
            )
            for route in routes where !route.choices.isEmpty {
                let branches = route.choices.compactMap { choice in named[route.from]?[choice].map { transitions[$0] } }
                let operation = byEffect[route.trigger.name]
                /// How a function takes a value: not at all, without `sending`, or as `sending`.
                enum Taking { case absent, reads, sends }
                struct Value {
                    let reference: String
                    let router: Taking
                    let edges: [Taking]
                }
                func taking(_ type: String?, _ convention: String) -> Taking {
                    type == nil ? .absent : convention.contains("sending") ? .sends : .reads
                }
                var values: [Value] = []
                if let payload = route.payloadType {
                    values.append(
                        Value(
                            reference: payload,
                            router: taking(payload, route.payloadConvention),
                            edges: branches.map { taking($0.payloadType, $0.payloadConvention) }
                        )
                    )
                }
                if let operation, route.takesRequest || branches.contains(where: \.takesRequest) {
                    values.append(
                        Value(
                            reference: operation.request,
                            router: taking(route.requestType, route.requestConvention),
                            edges: branches.map { taking($0.requestType, $0.requestConvention) }
                        )
                    )
                }
                let source = phaseTypes[route.from] ?? route.from
                for (index, value) in values.enumerated() {
                    if value.router == .sends, value.edges.contains(where: { $0 != .absent }) {
                        checks.require(.sharedAfterRouter(.routerSends), at: value.reference)
                    }
                    if value.edges.contains(.sends), value.edges.contains(.reads) {
                        checks.require(.sharedAfterRouter(.edgesDiffer), at: value.reference)
                    }
                    guard value.router == .reads else { continue }
                    for (edge, taken) in value.edges.enumerated() where taken == .sends {
                        checks.require(.transfersAfterRouter(other: source, joined: .source), at: value.reference)
                        for (otherIndex, other) in values.enumerated()
                        where otherIndex != index && other.router == .reads {
                            let received = other.edges.contains(.sends)
                            guard !received || other.edges[edge] != .absent else { continue }
                            checks.require(
                                .transfersAfterRouter(other: other.reference, joined: .value),
                                at: value.reference
                            )
                        }
                    }
                }
            }
        }
        // The names generated types and cases use depend on every edge, so they are checked against a
        // draft of the schema that the generator would read.
        var draft = Schema(
            name: declaration.name.unescaped,
            access: .internal,
            mode: mode,
            initial: initial,
            initialDefault: nil,
            scopes: scopes,
            scopeActiveIn: scopeActiveIn,
            phases: phases,
            inputs: inputs,
            operations: operations,
            events: events,
            transitions: transitions,
            routes: routes,
            restoration: nil,
            valueConformances: [],
            typeNames: typeNames,
            owners: Set(owners),
            typeScopes: typeScopes,
            workCounter: workCounter
        )
        /// Whether an authored spelling names one of the generated types `spellings` lists, however it
        /// is qualified or spaced.
        func spells(_ spelled: String, oneOf spellings: [String]) -> Bool {
            let schema = declaration.name.unescaped
            let key = Schema.relativeKey(self.spellings.type(spelled), schema: schema)
            return spellings.contains { Schema.relativeKey(self.spellings.type($0), schema: schema) == key }
        }
        // Each function's first edge, and the name of each operation and event by its effect, found once for
        // every check, so checking many edges with many effects takes time linear in what they list.
        var edgeIndices: [Int: Int] = [:]
        for (index, edge) in transitions.enumerated() where edgeIndices[edge.declaration] == nil {
            edgeIndices[edge.declaration] = index
        }
        let operationNames = Dictionary(
            operations.map { ($0.effect, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        let eventNames = Dictionary(events.map { ($0.effect, $0.name) }, uniquingKeysWith: { first, _ in first })
        for check in effectChecks {
            guard let edge = edgeIndices[check.declaration].map({ transitions[$0] }) else { continue }
            let spellings = draft.effectSpellings(edge)
            let expected = draft.effectType(edge) ?? "Never"
            let started = edge.starts.compactMap { operationNames[$0] }.joined(separator: ", ")
            let emitted = edge.emits.compactMap { eventNames[$0] }.joined(separator: ", ")
            let cancelled = edge.cancels.compactMap { operationNames[$0] }.joined(separator: ", ")
            let effects = [
                started.isEmpty ? nil : "starts \(started)", cancelled.isEmpty ? nil : "cancels \(cancelled)",
                emitted.isEmpty ? nil : "emits \(emitted)",
            ]
            .compactMap { $0 }.joined(separator: " and ")
            switch check.form {
            case .advance(let spelled):
                let effect = try read(self.spellings.type(spelled), typeScopes)
                let message =
                    spellings.isEmpty
                    ? "This transition starts no operation, cancels no work, and emits no event; use Never as its effect type."
                    : "This transition \(effects); use \(expected) as its effect type."
                if spellings.isEmpty {
                    // An edge without effects names `Never`, which a reading the macro cannot confirm may.
                    if effect.isNever {
                        checks.note(effect, at: spelled, distinguishesVoid: false)
                    } else if !effect.confirmsShape {
                        checks.require(.isStandard("Never", message: message), at: spelled)
                    } else {
                        try reject(check.node, message)
                    }
                } else {
                    guard !effect.isNever, spells(spelled, oneOf: spellings) else { try reject(check.node, message) }
                }
            case .change(let spelled):
                guard spells(spelled, oneOf: spellings) else {
                    try reject(check.node, "This transition \(effects); name its effects \(expected).")
                }
            case .destination(let spelled):
                try reject(check.node, "This transition \(effects); return Change<\(spelled), \(expected)>.")
            }
        }
        for (index, route) in routes.enumerated() {
            guard let function = functions[route.declaration], let result = routeResults[route.declaration] else {
                continue
            }
            if let namespace = route.namespace {
                let request = route.takesRequest || draft.branches(route).contains(where: \.takesRequest)
                try checkWrapperMembers(
                    function,
                    owned: (route.payloadType == nil ? [] : ["_"]) + (request ? ["request"] : []),
                    observed: route.trigger.kind == .input ? (route.payloadType == nil ? [] : ["_"]) : nil,
                    owners: owners,
                    role: "router"
                )
                let spellings = draft.choiceSpellings(route)
                if ["Route", "Type", "Protocol"].contains(namespace) {
                    try reject(
                        function.name,
                        "This router's choice type would be Route.\(namespace); rename the router."
                    )
                }
                // Generated code inside `Route` names the schema's own types through the schema's name.
                if namespace == declaration.name.unescaped {
                    try reject(
                        function.name,
                        "This router's choice type would be Route.\(namespace), which hides the schema '\(declaration.name.unescaped)' inside Route; rename the router."
                    )
                }
                // So does its owned result type, in `Route` and in the namespace of its source phase.
                if owners.contains(.owned), draft.needsOwnedResult(route),
                    namespace + "Result" == declaration.name.unescaped
                {
                    try reject(
                        function.name,
                        "This router's owned result type would be Route.\(namespace)Result, which hides the schema '\(declaration.name.unescaped)' inside Route; rename the router."
                    )
                }
                guard spells(result.trimmedDescription, oneOf: spellings) else {
                    try reject(
                        result,
                        "A router returns its choice among \(route.choices.joined(separator: ", ")): \(draft.choiceType(route) ?? "Route.\(namespace)")."
                    )
                }
                // A throwing router's owned result has a `rejected` case that returns the source.
                if owners.contains(.owned), route.failureType != nil, route.choices.contains("rejected") {
                    try reject(
                        function.name,
                        "A throwing router cannot choose an edge named 'rejected', which its owned result uses; rename the edge."
                    )
                }
            } else {
                // A router with no edge to choose can only reject, so it throws and returns `Never`. A
                // reading the macro cannot confirm gives way to that, and the expansion checks it.
                let message = "A router with no edge to choose returns Never and throws a typed rejection."
                guard routes[index].failureType != nil else { try reject(function.name, message) }
                let never = try read(result, typeScopes)
                let spelled = outsideSchema(result, schema: declaration.name.unescaped)
                if never.isNever {
                    checks.note(never, at: spelled, distinguishesVoid: false)
                } else if !never.confirmsShape {
                    checks.require(.isStandard("Never", message: message), at: spelled)
                } else {
                    try reject(result, message)
                }
            }
        }
        // A keyed operation that some edge lists in `cancels:` has cancellation cases, which share
        // `Effect` with every operation and event case and with each other's.
        var effectCases: [String: [(kind: String, name: String, purpose: String?)]] = [:]
        for operation in operations {
            effectCases[operation.effect, default: []].append(("Operation", operation.name, nil))
        }
        for event in events { effectCases[event.effect, default: []].append(("Event", event.name, nil)) }
        for keyed in draft.cancelledOperations {
            effectCases[keyed.cancelEffect, default: []]
                .append(("Keyed operation", keyed.name, "cancel one key's work"))
            effectCases[keyed.cancelAllEffect, default: []]
                .append(("Keyed operation", keyed.name, "cancel all of its work"))
        }
        var collisions: [Diagnostic] = []
        for (name, sources) in effectCases.sorted(by: { $0.key < $1.key }) where sources.count > 1 {
            for source in sources {
                let node =
                    operationNodes[source.name].map { Syntax($0.name) }
                    ?? nestedEnums.first { $0.name.unescaped == source.name }.map { Syntax($0.name) }
                    ?? Syntax(declaration.name)
                let others = sources.filter { $0.name != source.name || $0.purpose != source.purpose }
                let message: String
                if let purpose = source.purpose {
                    let other = others.map { other in
                        other.purpose.map { "keyed operation '\(other.name)' also generates to \($0)" }
                            ?? "\(other.kind.lowercased()) '\(other.name)' also generates"
                    }
                    message =
                        "Keyed operation '\(source.name)' generates the effect case '\(name)' to \(purpose), which \(other.joined(separator: " and ")); rename one."
                } else {
                    // An operation or event case is diagnosed against the cancellation that claims its name.
                    guard let keyed = others.first(where: { $0.purpose != nil }) else { continue }
                    message =
                        "\(source.kind) '\(source.name)' generates the effect case '\(name)', which keyed operation '\(keyed.name)' uses to cancel its work; rename one."
                }
                collisions.append(Diagnostic(node: node, message: SchemaMessage(message: message)))
            }
        }
        if !collisions.isEmpty { throw DiagnosticsError(diagnostics: collisions) }
        // A router with no edge to choose may throw a type the macro read as `Never` without confirming it.
        draft.routes = routes
        try validateGeneratedNames(draft, functions: functions, declaration: declaration)
        let restoration = try restoration(
            members,
            mode: mode,
            owners: owners,
            schema: declaration.name.unescaped,
            phases: phases,
            scopes: typeScopes,
            checks: &checks,
            throwing: throwing
        )
        let reservedSchema = Schema(
            name: draft.name,
            access: draft.access,
            mode: mode,
            initial: initial,
            initialDefault: nil,
            scopes: scopes,
            scopeActiveIn: scopeActiveIn,
            phases: phases,
            inputs: inputs,
            operations: operations,
            events: events,
            transitions: transitions,
            routes: routes,
            restoration: restoration,
            valueConformances: [],
            typeNames: typeNames,
            owners: Set(owners),
            typeScopes: typeScopes,
            authoredIdentifiers: authoredIdentifiers,
            typeChecks: checks.ordered,
            workCounter: workCounter
        )
        let reserved = Set(reservedSchema.reservedNames)
        // An operation's own types are named for it, so one can take a name the expansion already uses.
        let fixed = Set(reservedSchema.fixedGeneratedNames)
        if let taken = reservedSchema.operationTypeNames.first(where: { fixed.contains($0.name) }) {
            try reject(
                operationNodes[taken.operation].map { Syntax($0.name) } ?? Syntax(declaration.name),
                "Operation '\(taken.operation)' would generate the type '\(taken.name)', which the expansion already declares for this schema's owners; rename the operation."
            )
        }
        // Generated code names the schema's types through the schema's name, which a direct member type or
        // alias of that name would capture; a value of that name is not looked up where a type is.
        guard
            !Set(reservedSchema.schemaNameReservations)
                .contains(declaration.name.unescaped),
            !typeNames.contains(declaration.name.unescaped)
        else {
            // The member that shadows the name, or the schema's name when the expansion reserves it.
            let shadowing =
                typeNames.contains(declaration.name.unescaped)
                ? anchor(for: declaration.name.unescaped, in: declaration) : Syntax(declaration.name)
            try reject(
                shadowing,
                "The schema name is reserved or shadowed by a direct member; choose a distinct domain name."
            )
        }
        // Every phase case carries a payload, so it is a constructor beside the generated
        // `static let graph`, not a redeclaration of it.
        for name in declaredNames + phases.map(\.caseName).filter({ $0 != "graph" })
        where reserved.contains(name) {
            try reject(
                anchor(for: name, in: declaration),
                "'\(name)' is reserved for generated members; rename the authored declaration."
            )
        }
        // The expansion declares its implementation names inside the schema, where they would capture
        // a spelling that means a declaration of that name outside it.
        if let token = declaration.memberBlock.tokens(viewMode: .sourceAccurate)
            .first(where: { token in
                // A name not composed, which only a body may hold, has the bytes of no implementation name.
                guard case .identifier = token.tokenKind, token.isComposed else { return false }
                return token.unescaped.hasPrefix("_") && fixed.contains(token.unescaped)
            })
        {
            try reject(
                token,
                "'\(token.unescaped)' names a declaration the expansion makes inside the schema for its own use, which would hide any declaration of that name this spelling means; rename that declaration."
            )
        }
        // The edges and routers of each source and trigger, counted in one pass, in the order each pair
        // first appears, so a schema with many triggers is checked in time linear in its functions.
        var counted: [SourceTrigger: (edges: Int, routers: Int)] = [:]
        var pairs: [SourceTrigger] = []
        for pair in transitions.map({ SourceTrigger(from: $0.from, trigger: $0.trigger) }) {
            if counted[pair] == nil { pairs.append(pair) }
            counted[pair, default: (0, 0)].edges += 1
        }
        for pair in routes.map({ SourceTrigger(from: $0.from, trigger: $0.trigger) }) {
            if counted[pair] == nil { pairs.append(pair) }
            counted[pair, default: (0, 0)].routers += 1
        }
        let phaseNames = Dictionary(phases.map { ($0.caseName, $0.typeName) }, uniquingKeysWith: { first, _ in first })
        for pair in pairs {
            guard let count = counted[pair], count.routers > 1 || (count.edges > 1 && count.routers != 1) else {
                continue
            }
            // The second router of the pair, or its second edge when it has no router.
            let declarations =
                count.routers > 1
                ? routes.filter { SourceTrigger(from: $0.from, trigger: $0.trigger) == pair }.map(\.declaration)
                : transitions.filter { SourceTrigger(from: $0.from, trigger: $0.trigger) == pair }.map(\.declaration)
            try reject(
                declarations.dropFirst().first.flatMap { functions[$0] }.map { Syntax($0.name) }
                    ?? Syntax(declaration.name),
                "Ambiguous routing from '\(phaseNames[pair.from] ?? pair.from)' for \(describe(pair.trigger, operations: operations)); declare exactly one @Route when multiple edges match."
            )
        }
        for operation in operations {
            for phase in operation.activeIn {
                for kind in [Schema.Trigger.Kind.success, .failure]
                where kind == .success ? !operation.neverSucceeds : !operation.isInfallible {
                    let on = Schema.Trigger(kind: kind, name: operation.effect)
                    guard counted[SourceTrigger(from: phase, trigger: on)] != nil else {
                        try reject(
                            operationNodes[operation.name].map { Syntax($0.name) } ?? Syntax(declaration.name),
                            "Operation '\(operation.name)' needs a \(kind.rawValue) edge or router in active phase case '\(phase)'."
                        )
                    }
                }
            }
        }
        let access =
            declaration.modifiers.lazy.compactMap { Schema.Access(rawValue: $0.name.unescaped) }.first ?? .internal
        // A public or package schema generates members of its own access that name its phase payloads, `Input`, its
        // operation and event namespaces with their aliases, and the types its payloads, outputs, keys, requests,
        // saved data, and failures spell. Each declaration of the schema that one of those spellings names, as
        // Swift resolves it where it is written, needs that access; a helper that none of them names may keep less,
        // whatever it is called.
        if access == .public || access == .package {
            let sufficient: Set<String> = access == .public ? ["public", "open"] : ["public", "open", "package"]
            // Each spelling with the scope it is written in; a namespace's alias is read from its declaration.
            var spellings: [(TypeSyntax, Int)] = []
            var authored = phases.map(\.typeName) + ["Input"] + operations.map(\.name) + events.map(\.name)
            for (name, aliases) in operations.map({ ($0.name, ["Input", "Output", "Failure", "Key"]) })
                + events.map({ ($0.name, ["Payload"]) })
            {
                let scope = typeScopes.memberScope(name) ?? LexicalScopes.schema
                for alias in aliases {
                    guard let target = typeScopes.declaredAlias(alias, in: scope) else { continue }
                    authored.append("\(name).\(alias)")
                    spellings.append((target, scope))
                }
            }
            var signatures = transitions.flatMap { [$0.payloadType, $0.failureType, $0.requestType] }
            signatures += routes.flatMap { [$0.payloadType, $0.failureType, $0.pinnedFailure] }
            signatures += [restoration?.archiveType, restoration?.failureType]
            authored += signatures.compactMap { $0 }
            spellings += authored.map { (self.spellings.type($0), LexicalScopes.schema) }
            var named: Set<SyntaxIdentifier> = []
            for (spelling, scope) in spellings {
                named.formUnion(typeScopes.namedDeclarations(spelling, in: scope))
            }
            func requireAccess(_ members: MemberBlockItemListSyntax) throws {
                for member in members {
                    let name: TokenSyntax
                    let modifiers: DeclModifierListSyntax
                    var nested: MemberBlockSyntax?
                    if let type = member.decl.as(StructDeclSyntax.self) {
                        (name, modifiers, nested) = (type.name, type.modifiers, type.memberBlock)
                    } else if let type = member.decl.as(EnumDeclSyntax.self) {
                        (name, modifiers, nested) = (type.name, type.modifiers, type.memberBlock)
                    } else if let type = member.decl.as(ClassDeclSyntax.self) {
                        (name, modifiers, nested) = (type.name, type.modifiers, type.memberBlock)
                    } else if let type = member.decl.as(ActorDeclSyntax.self) {
                        (name, modifiers, nested) = (type.name, type.modifiers, type.memberBlock)
                    } else if let type = member.decl.as(ProtocolDeclSyntax.self) {
                        (name, modifiers) = (type.name, type.modifiers)
                    } else if let alias = member.decl.as(TypeAliasDeclSyntax.self) {
                        (name, modifiers) = (alias.name, alias.modifiers)
                    } else {
                        continue
                    }
                    guard
                        !named.contains(member.decl.id)
                            || modifiers.contains(where: { sufficient.contains($0.name.text) })
                    else {
                        try reject(
                            name,
                            "Declare '\(name.unescaped)' \(access.rawValue): the \(access.rawValue) schema '\(declaration.name.unescaped)' generates \(access.rawValue) members that name it."
                        )
                    }
                    if let nested { try requireAccess(nested.members) }
                }
            }
            try requireAccess(declaration.memberBlock.members)
        }
        let schema = Schema(
            name: declaration.name.unescaped,
            access: access,
            mode: mode,
            initial: initial,
            initialDefault: rootCases.first { $0.caseName == initial }?.defaultValue,
            scopes: scopes,
            scopeActiveIn: scopeActiveIn,
            phases: phases,
            inputs: inputs,
            operations: operations,
            events: events,
            transitions: transitions,
            routes: routes,
            restoration: restoration,
            valueConformances: valueConformances,
            typeNames: typeNames,
            owners: Set(owners),
            typeScopes: typeScopes,
            spellings: spellings,
            authoredIdentifiers: authoredIdentifiers,
            typeChecks: checks.ordered,
            workCounter: workCounter
        )
        try checkRenames(in: schema)
        let findings = schema.graphFindings()
        guard findings.isEmpty else {
            throw DiagnosticsError(
                diagnostics: findings.map { finding in
                    let (node, message) = graphDiagnostic(
                        finding,
                        in: schema,
                        declaration: declaration,
                        operations: operationNodes,
                        functions: functions
                    )
                    return Diagnostic(node: node, message: SchemaMessage(message: message))
                }
            )
        }
        return schema
    }

    /// Refuses a `renamed:` that is anything but the bare name of another edge, or of another router, whose
    /// generated public methods include one on each wrapper where the deprecated function's method repeats
    /// the attribute, so that Swift's fix-it at a call of a generated method names a method the caller has.
    private func checkRenames(in schema: Schema) throws {
        // The wrappers, `Owned` as false and `Observed` as true, on which each function has its own public
        // method, by role and name, where overloads pool them, and by deprecated declaration.
        let wrappers = [false, true].filter { $0 ? schema.generatesObservingOwner : schema.generates(.owned) }
        let edges = schema.transitions.map { edge in
            (
                "edge", edge.name, edge.declaration, edge.deprecation,
                wrappers.filter { schema.hasOwnMethod(edge, observed: $0) }
            )
        }
        let routers = schema.routes.map { route in
            (
                "router", route.name, route.declaration, route.deprecation,
                wrappers.filter { schema.hasMethod(route, observed: $0) }
            )
        }
        let functions = (edges + routers).sorted { $0.2 < $1.2 }
        var methods: [String: Set<Bool>] = [:]
        var marked: [Int: Set<Bool>] = [:]
        for (role, name, declaration, deprecation, own) in functions {
            methods["\(role) \(name)", default: []].formUnion(own)
            if deprecation != nil { marked[declaration, default: []].formUnion(own) }
        }
        for (role, name, declaration, deprecation, _) in functions {
            guard let renamed = deprecation?.renamed else { continue }
            // Names compare by their bytes, as Swift's do, rather than as equivalent text.
            let key = "\(role) \(renamed.name)"
            if renamed.name != name, let index = methods.index(forKey: key),
                methods[index].key.utf8.elementsEqual(key.utf8),
                marked[declaration, default: []].isSubset(of: methods[index].value)
            {
                continue
            }
            try reject(
                renamed.literal,
                "Write the bare name of the replacement \(role) in 'renamed:': the generated methods repeat this deprecation as written, so it must name another \(role) that has a generated public method wherever this one has."
            )
        }
    }

    /// The declaration to blame for a graph finding, and what to tell its author.
    private func graphDiagnostic(
        _ finding: Schema.GraphFinding,
        in schema: Schema,
        declaration: EnumDeclSyntax,
        operations: [String: EnumDeclSyntax],
        functions: [Int: FunctionDeclSyntax]
    ) -> (Syntax, String) {
        func type(_ phase: String) -> String { schema.phaseType(phase) }
        func operation(_ effect: String) -> String {
            schema.operations.first {
                workCounter.work.triggersScanned += 1
                return $0.effect == effect
            }?
            .name ?? effect
        }
        switch finding {
        case .unreachablePhase(let phase):
            let entrances = schema.restorationEntrances.isEmpty ? "" : " or a phase @Restoration can restore"
            return (
                anchor(for: phase, in: declaration),
                "Phase '\(phase)' is unreachable from the initial phase '\(schema.initial)'\(entrances); declare a transition into it, or remove it."
            )
        case .missingExit(let phase):
            return (
                anchor(for: phase, in: declaration),
                "Phase '\(phase)' has no outgoing transitions; mark it '@Terminal' or declare a transition from it."
            )
        case .unstartedOperation(let name):
            return (
                operations[name].map { Syntax($0.name) } ?? Syntax(declaration.name),
                "Operation '\(name)' is never started: no transition lists it in starts:; start it from a transition, or remove it."
            )
        case .unreachableStart(let name):
            return (
                operations[name].map { Syntax($0.name) } ?? Syntax(declaration.name),
                "Operation '\(name)' is never started: every transition that lists it in starts: leaves a phase the graph never reaches or completes an operation that is never active there; start it from a reachable transition, or remove it."
            )
        case .unacceptedOperation(let name):
            return (
                operations[name].map { Syntax($0.name) } ?? Syntax(declaration.name),
                "Operation '\(name)' can start but never complete: no phase in which it can be active has a completion edge for it; declare one, or give its completion router an edge to choose."
            )
        case .unacceptedOutcome(let name, let kind):
            let outcome = kind == .success ? "success" : "failure"
            let label = kind == .success ? "onSuccess" : "onFailure"
            return (
                operations[name].map { Syntax($0.name) } ?? Syntax(declaration.name),
                "Operation '\(name)' can start but its \(outcome) is never accepted: no phase in which it can be active has an \(label): edge for it, so every \(outcome) stays pending until it is discarded; declare one, or give its \(outcome) router an edge to choose."
            )
        case .unfiredCompletion(let index):
            let edge = schema.transitions[index]
            let name = operation(edge.trigger.name)
            return (
                functions[edge.declaration].map { Syntax($0.name) } ?? Syntax(declaration.name),
                "Completion edge '\(edge.name)' can never fire: no path from a transition that starts '\(name)' reaches phase '\(edge.from)' while '\(name)' stays active; start '\(name)' on a transition into '\(edge.from)', or remove \(type(edge.from)).self from the phases where '\(name)' is active."
            )
        case .unrunCompletionRouter(let index):
            let route = schema.routes[index]
            let name = operation(route.trigger.name)
            return (
                functions[route.declaration].map { Syntax($0.name) } ?? Syntax(declaration.name),
                "Completion router '\(route.name)' can never run: no path from a transition that starts '\(name)' reaches phase '\(route.from)' while '\(name)' stays active; start '\(name)' on a transition into '\(route.from)', or remove \(type(route.from)).self from the phases where '\(name)' is active."
            )
        }
    }

    /// Rejects an edge or router whose generated method would redeclare a member of a phase wrapper.
    ///
    /// `owned` and `observed` are the argument labels of its `Owned` and `Observed` methods, or `nil`
    /// for a wrapper that has no method for it. A method redeclares a property of its name when it
    /// takes no arguments, and a method of the same full name; a method that takes arguments beside a
    /// property, or other arguments than a method, is a different declaration.
    private func checkWrapperMembers(
        _ function: FunctionDeclSyntax,
        owned: [String]?,
        observed: [String]?,
        owners: [Schema.Owner],
        role: String
    ) throws {
        let name = function.name.unescaped
        func spelled(_ labels: [String]) -> String { name + "(" + labels.map { "\($0):" }.joined() + ")" }
        // A method redeclares a property; one with the full name of an `Owned` verb overloads it, and
        // the edge's method would take a call meant for the verb.
        var collision: (method: String, effect: String)?
        if let owned, owners.contains(.owned) {
            switch (name, owned) {
            case ("phase", []): collision = ("Owned method \(spelled(owned))", "redeclares Owned's phase property")
            case ("takeValue", []):
                collision = ("Owned method \(spelled(owned))", "shadows Owned's own takeValue() verb")
            case ("withValue", ["_"]):
                collision = ("Owned method \(spelled(owned))", "shadows Owned's own withValue(_:) verb")
            default: break
            }
        }
        if collision == nil, let observed, observed.isEmpty, owners.contains(where: { $0 != .owned }),
            ["payload", "record", "claim", "value", "revision", "description"].contains(name)
        {
            collision = ("Observed method \(spelled(observed))", "redeclares Observed's \(name) property")
        }
        guard let collision else { return }
        try reject(
            function.name,
            "\(role.prefix(1).uppercased() + role.dropFirst()) '\(name)' would generate the \(collision.method), which \(collision.effect); rename the \(role)."
        )
    }

    /// Reads the `owners:` list: unqualified `StateMachineOwner` members, each once, that `mode` supports.
    private func owners(_ expression: ExprSyntax, mode: Schema.Mode) throws -> [Schema.Owner] {
        guard let array = expression.as(ArrayExprSyntax.self) else {
            try reject(expression, "Use an array literal of owners such as [.local, .mainActorHost].")
        }
        let supported = Schema.Owner.supported(by: mode)
        let spelled = supported.map { ".\($0.rawValue)" }.joined(separator: ", ")
        var result: [Schema.Owner] = []
        for element in array.elements {
            let name = try member(element.expression)
            guard let owner = Schema.Owner(rawValue: name) else {
                try reject(
                    element.expression,
                    "'.\(name)' is not an owner; use .owned, .local, .shared, .actorHost, .mainActorHost, or .isolatedHost."
                )
            }
            guard !result.contains(owner) else {
                try reject(element.expression, "List each owner once; '.\(name)' appears twice.")
            }
            guard supported.contains(owner) else {
                try reject(
                    element.expression,
                    "Owner '.\(name)' is unavailable in .\(mode.rawValue), which supports \(spelled)."
                )
            }
            result.append(owner)
        }
        guard !result.isEmpty else {
            try reject(
                expression,
                "List at least one owner, or omit owners: to generate every owner .\(mode.rawValue) supports."
            )
        }
        return result
    }

    /// Checks that the companion types and cases the generator emits have distinct names in each namespace.
    private func validateGeneratedNames(
        _ schema: Schema,
        functions: [Int: FunctionDeclSyntax],
        declaration schemaDeclaration: EnumDeclSyntax
    ) throws {
        /// What generates a member: an authored function, identified by name, or a phase's namespace.
        enum Owner {
            case function(kind: String, name: String)
            case phase(String)
        }
        func register(
            _ member: String,
            in path: String,
            kind: String,
            name: String,
            declaration: Int,
            registry: inout [String: Owner]
        ) throws {
            guard let existing = registry[member] else {
                registry[member] = .function(kind: kind, name: name)
                return
            }
            let node = functions[declaration].map { Syntax($0.name) } ?? Syntax(schemaDeclaration.name)
            let owner = kind.prefix(1).uppercased() + kind.dropFirst()
            switch existing {
            // Functions of one name share their generated members.
            case .function(_, let other) where other == name: return
            case .function(let otherKind, let other):
                try reject(
                    node,
                    "\(owner) '\(name)' would generate \(path).\(member), which \(otherKind) '\(other)' also generates; rename one."
                )
            case .phase(let phase):
                try reject(
                    node,
                    "\(owner) '\(name)' would generate \(path).\(member), which is the namespace of phase '\(phase)'; rename the \(kind)."
                )
            }
        }
        var effect: [String: Owner] = [:]
        for phase in schema.effectPhases { effect[phase.typeName] = .phase(phase.typeName) }
        for edge in schema.transitions where schema.sharesEffect(edge.name) {
            guard let namespace = edge.effectNamespace else { continue }
            try register(
                namespace,
                in: "Effect",
                kind: "transition",
                name: edge.name,
                declaration: edge.declaration,
                registry: &effect
            )
        }
        let edgesBySource = Dictionary(grouping: schema.transitions, by: \.from)
        for phase in schema.effectPhases {
            var members: [String: Owner] = [:]
            for edge in edgesBySource[phase.caseName] ?? [] {
                guard let namespace = edge.effectNamespace else { continue }
                try register(
                    namespace,
                    in: "Effect.\(phase.typeName)",
                    kind: "transition",
                    name: edge.name,
                    declaration: edge.declaration,
                    registry: &members
                )
            }
        }
        var route: [String: Owner] = [:]
        for phase in schema.routePhases { route[phase.typeName] = .phase(phase.typeName) }
        for router in schema.choosingRouters {
            guard let namespace = router.namespace else { continue }
            if schema.sharesChoice(router.name) {
                try register(
                    namespace,
                    in: "Route",
                    kind: "router",
                    name: router.name,
                    declaration: router.declaration,
                    registry: &route
                )
            }
            if schema.generates(.owned), schema.needsOwnedResult(router), schema.ownsResultName(router.name) {
                try register(
                    namespace + "Result",
                    in: "Route",
                    kind: "router",
                    name: router.name,
                    declaration: router.declaration,
                    registry: &route
                )
            }
        }
        for phase in schema.routePhases {
            var members: [String: Owner] = [:]
            for router in schema.choosingRouters(from: phase.caseName) {
                guard let namespace = router.namespace else { continue }
                let names =
                    [namespace]
                    + (schema.generates(.owned) && schema.needsOwnedResult(router) ? [namespace + "Result"] : [])
                for member in names {
                    try register(
                        member,
                        in: "Route.\(phase.typeName)",
                        kind: "router",
                        name: router.name,
                        declaration: router.declaration,
                        registry: &members
                    )
                }
            }
        }
        guard schema.generatesObservingOwner else { return }
        // Only an observing owner generates `PreparationRejection`, whose own `invalidPhase` case reports
        // an input or outcome without an edge. A throwing function's case is checked by the name it
        // finally has, after functions of one name that throw different types are told apart by phase.
        var rejections: [String: Owner] = [:]
        let distinguished = schema.namesThrowingDifferentFailures
        let routers = Set(schema.routes.map(\.declaration))
        for function in schema.throwingFunctions {
            let isRoute = routers.contains(function.declaration)
            let rejection = Schema.rejectionCase(function.name, from: function.from, distinguished: distinguished)
            if rejection == "invalidPhase" {
                try reject(
                    functions[function.declaration].map { Syntax($0.name) } ?? Syntax(schemaDeclaration.name),
                    "'invalidPhase' is already a PreparationRejection case; rename this throwing \(isRoute ? "router" : "transition")."
                )
            }
            try register(
                rejection,
                in: "PreparationRejection",
                kind: isRoute ? "router" : "transition",
                name: function.name,
                declaration: function.declaration,
                registry: &rejections
            )
        }
    }

    /// Reads the optional `@Restoration` validator: `static func <name>(_ saved: Archive) -> Restoration`.
    ///
    /// Without arguments, saved data may restore every resting phase. An `only:` list names exactly the
    /// restorable phases, and an `allows:` list adds phases to the resting ones. A restored owner has
    /// no outstanding work in either case.
    private func restoration(
        _ members: MemberBlockItemListSyntax,
        mode: Schema.Mode,
        owners: [Schema.Owner],
        schema: String,
        phases: [Schema.Phase],
        scopes typeScopes: LexicalScopes,
        checks: inout TypeChecks,
        throwing: Set<String>
    ) throws -> Schema.Restoration? {
        let marked = try members.enumerated()
            .compactMap {
                position,
                member -> (function: FunctionDeclSyntax, attribute: AttributeSyntax, position: Int)? in
                guard let function = member.decl.as(FunctionDeclSyntax.self),
                    let attribute = try marker(function.attributes, named: "Restoration")
                else { return nil }
                return (function, attribute, position)
            }
        guard let first = marked.first else { return nil }
        let function = first.function
        let attribute = first.attribute
        guard marked.count == 1 else {
            try reject(marked[1].attribute, "Declare at most one @Restoration function in a schema.")
        }
        guard mode != .ownedOnly else {
            try reject(attribute, "@Restoration is unavailable in .ownedOnly, which generates no owner to restore.")
        }
        guard owners.contains(where: { $0 != .owned }) else {
            try reject(
                attribute,
                "@Restoration needs an owner that a restoring initializer creates; list .local or a managed host in owners:."
            )
        }
        let metadata = try arguments(attribute, required: [], optional: ["allows", "only"])
        let phaseCases = Dictionary(phases.map { ($0.typeName, $0.caseName) }, uniquingKeysWith: { first, _ in first })
        func restorable(_ expression: ExprSyntax) throws -> [String] {
            try typeReferences(expression)
                .map { reference -> String in
                    guard let phase = phaseCases[reference.name] else {
                        try reject(
                            reference.node,
                            "'\(reference.name)' is not a phase payload type declared in this schema."
                        )
                    }
                    return phase
                }
        }
        if let allows = metadata["allows"]?.parent, let only = metadata["only"]?.parent {
            // The later of the two lists.
            try reject(
                allows.position < only.position ? only : allows,
                "Use only: to list every restorable phase, or allows: to add phases to the resting ones, not both."
            )
        }
        let allows = try metadata["allows"].map(restorable) ?? []
        let only = try metadata["only"].map(restorable)
        if let only, only.isEmpty, let listed = metadata["only"] {
            try reject(listed, "List at least one restorable phase in only:.")
        }
        guard identifier(function.name.unescaped) else {
            try reject(
                function.name,
                "Name the restoration function with a Swift identifier that needs no backticks, such as one that is not a keyword."
            )
        }
        guard
            members.compactMap({ $0.decl.as(FunctionDeclSyntax.self) })
                .filter({ $0.name.unescaped == function.name.unescaped }).count == 1
        else { try reject(function.name, "A @Restoration function cannot be overloaded.") }
        let deprecation = try validateFunction(function, role: "Restoration functions", schema: schema)
        let parameters = function.signature.parameterClause.parameters
        guard parameters.count == 1, let parameter = parameters.first else {
            try reject(
                function.signature.parameterClause,
                "A @Restoration function takes exactly one unlabeled parameter: the saved data it validates."
            )
        }
        let saved = try self.parameter(parameter, schema: schema, role: "saved data")
        guard let result = function.signature.returnClause?.type.unparenthesized,
            payloadName(result, schema: schema) == "Restoration"
        else {
            try reject(
                function.signature.returnClause.map(Syntax.init) ?? Syntax(function.signature),
                "A @Restoration function returns Restoration, the phase to restore."
            )
        }
        return Schema.Restoration(
            name: function.name.unescaped,
            archiveType: saved.type,
            archiveConvention: saved.convention,
            failureType: try thrownType(
                function,
                owner: first.position,
                schema: schema,
                scopes: typeScopes,
                checks: &checks,
                throwing: throwing
            ),
            allows: allows,
            only: only,
            deprecation: deprecation
        )
    }

    /// Spells a type written inside the schema so it means the same thing inside a generated owner.
    private func outsideSchema(_ type: TypeSyntax, schema: String) -> String {
        let spelled = TypeQualifier.qualify(type.trimmed, owner: schema, names: [])
        // A spelling kept as written is read again from the author's syntax, never parsed again.
        spellings.remember(type.trimmed, as: spelled)
        return spelled
    }

    /// The type an authored function throws, spelled so it resolves outside the schema, or `nil` when it
    /// throws nothing: when it has no throws clause, or one whose type the schema resolves to `Never`,
    /// which Swift reads as nonthrowing, so generated code calls it without `try`.
    ///
    /// The expansion checks a reading the macro cannot confirm, as it checks every such reading.
    private func thrownType(
        _ function: FunctionDeclSyntax,
        owner: Int,
        schema: String,
        scopes typeScopes: LexicalScopes,
        checks: inout TypeChecks,
        throwing: Set<String> = []
    ) throws -> String? {
        guard let type = function.signature.effectSpecifiers?.throwsClause?.type?.unparenthesized else { return nil }
        let reading = try read(type, typeScopes)
        let spelled = outsideSchema(type, schema: schema)
        // A spelling a router without edges showed to name a type with values throws here too.
        if reading.isNever, !reading.confirmsShape, throwing.contains(Schema.spellingKey(type)) {
            checks.require(
                .isNotNever(message: "A router with no edge to choose returns Never and throws a typed rejection."),
                at: spelled,
                owner: owner
            )
            return spelled
        }
        checks.note(reading, at: spelled, distinguishesVoid: false, owner: owner)
        return reading.isNever ? nil : spelled
    }

    /// A parameter's type, spelled so it resolves outside the schema, the passing convention that
    /// generated parameters of it repeat, and the ownership it declares.
    ///
    /// Generated code passes on a value it received, so `@escaping` and `sending` stay on the parameters
    /// it declares. The ownership, `borrowing`, `consuming`, `__shared`, or `__owned`, stays as spelled on
    /// each generated parameter that passes the value on once, which a noncopyable value needs: the
    /// underscored two are legal where the others are not, on a nonescaping closure and with `sending`,
    /// and let a copyable value be copied implicitly. Every other attribute, such as `@Sendable` or a
    /// global actor, is part of the type that witnesses and aliases name. `inout`, `isolated`, any other
    /// specifier, such as `_const`, and `@autoclosure` cannot receive a value passed on, so `role` names the
    /// parameter in their diagnostic.
    private func parameter(
        _ parameter: FunctionParameterSyntax,
        schema: String,
        role: String
    ) throws -> (convention: String, ownership: String, type: String) {
        // An opaque parameter makes the function generic, which an authored function may not be.
        let type = parameter.type.unparenthesized
        if let opaque = type.tokens(viewMode: .sourceAccurate).first(where: { $0.tokenKind == .keyword(.some) }) {
            try reject(
                opaque,
                "Take this \(role) as a concrete type; an opaque 'some' parameter makes the function generic."
            )
        }
        guard let attributed = type.as(AttributedTypeSyntax.self) else {
            return ("", "", outsideSchema(type, schema: schema))
        }
        var conventions: [String] = []
        var ownership = ""
        var kept: [String] = []
        for specifier in Array(attributed.specifiers) + Array(attributed.lateSpecifiers) {
            guard case .simpleTypeSpecifier(let simple) = specifier else {
                kept.append(specifier.trimmedDescription)
                continue
            }
            switch simple.specifier.text {
            case "inout" where role == "saved data":
                try reject(simple.specifier, "Pass the saved data to a @Restoration function by value, not inout.")
            case "sending": conventions.append("sending")
            case "borrowing", "__shared", "consuming", "__owned": ownership = simple.specifier.text + " "
            // `inout`, `isolated`, and any other, such as `_const`, change what a caller may pass.
            default:
                try reject(
                    simple.specifier,
                    "Take this \(role) without '\(simple.specifier.text)'; generated code passes on the value it receives."
                )
            }
        }
        var attributes: [String] = []
        for element in attributed.attributes {
            guard case .attribute(let attribute) = element else {
                attributes.append(element.trimmedDescription)
                continue
            }
            switch attribute.builtInName {
            case "escaping": conventions.append("@escaping")
            case "noescape": continue
            case "autoclosure":
                try reject(
                    attribute,
                    "Take this \(role) without '@autoclosure'; generated code passes on the value it receives, which an autoclosure would wrap again."
                )
            default: attributes.append(attribute.trimmedDescription)
            }
        }
        let spelled = (kept + attributes + [attributed.baseType.unparenthesized.trimmedDescription])
            .joined(separator: " ")
        let convention = conventions.map { $0 + " " }.joined()
        return (convention, ownership, outsideSchema(spellings.type(spelled), schema: schema))
    }
}
