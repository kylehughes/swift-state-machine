import SwiftSyntax
import SwiftSyntaxBuilder

/// The names of generated companion types, derived from the parsed schema.
///
/// Validation and generation both read these, so a name the parser accepts is the name the
/// generator emits.
extension Schema {
    /// The generated companion type name for an authored function: `begin` to `Begin`.
    static func companion(_ name: String) -> String {
        (name.prefix(1).uppercased() + name.dropFirst()).composed
    }

    func phaseType(_ caseName: String) -> String { tables.phaseTypes[caseName] ?? caseName }

    /// The position of a phase among the phases, or 0 for a name that is none.
    func phaseIndex(_ caseName: String) -> Int { tables.phaseIndices[caseName] ?? 0 }

    // MARK: Effects

    /// Whether every edge named `name` that has effects declares the same ones, so the short
    /// `Effect.<Edge>` names one type that all of them return.
    ///
    /// Edges declare the same effects when they list the same operations in `starts:` and `cancels:`
    /// and the same events in `emits:`, in any order: a list declares what the edge may return, and
    /// the reducer's returned array orders the effects.
    func sharesEffect(_ name: String) -> Bool {
        tables.sharedEffects.contains(name) || !tables.effectNames.contains(name)
    }

    /// The spelling, inside the schema, of the type that declares an edge's effects: the short
    /// `Effect.<Edge>` when it exists, and otherwise the namespace of the authored function's first source.
    func effectType(_ edge: Transition) -> String? {
        guard let companion = edge.effectNamespace else { return nil }
        if sharesEffect(edge.name) { return "Effect.\(companion)" }
        return "Effect.\(phaseType(edge.sources.first ?? edge.from)).\(companion)"
    }

    /// Every spelling of an edge's effect type that names it: the phase-qualified name of each source of the
    /// authored function, and the short name when it exists.
    func effectSpellings(_ edge: Transition) -> [String] {
        guard let companion = edge.effectNamespace else { return [] }
        let qualified = edge.sources.map { "Effect.\(phaseType($0)).\(companion)" }
        return (sharesEffect(edge.name) ? ["Effect.\(companion)"] : []) + qualified
    }

    /// The keyed operations some edge lists in `cancels:`, in declaration order; `Effect` has their
    /// cancellation cases.
    var cancelledOperations: [Operation] {
        let cancelled = Set(transitions.flatMap(\.cancels))
        return operations.filter { cancelled.contains($0.effect) }
    }

    /// The phases with an edge that starts operations; each has an `Effect.<Phase>` namespace.
    var effectPhases: [Phase] {
        let sources = Set(transitions.filter { $0.effectNamespace != nil }.map(\.from))
        return phases.filter { sources.contains($0.caseName) }
    }

    // MARK: Routes

    /// What validation and generation look up by name, found in one pass over the phases, operations,
    /// transitions, and routes, so a schema with many of them spends time in proportion to their number,
    /// not to a product of two.
    struct Tables {
        /// Each phase's payload type and position, by its case name.
        var phaseTypes: [String: String] = [:]
        var phaseIndices: [String: Int] = [:]
        /// The names of the edges with effects, and of those whose namesakes with effects all declare the
        /// same ones.
        var effectNames: Set<String> = []
        var sharedEffects: Set<String> = []
        /// Each operation and event by its effect case, and each operation by its name; the first declared.
        var operations: [String: Operation] = [:]
        var operationsByName: [String: Operation] = [:]
        var events: [String: Event] = [:]
        /// The routers that have edges to choose, in declaration order.
        var choosing: [Route] = []
        /// Each router's candidate edges, by the router's declaration, as indices into the transitions in
        /// the order its choices list them.
        var candidates: [Int: [Int]] = [:]
        /// The names of the routers whose namesakes all choose among the same edges.
        var sharedChoices: Set<String> = []
        /// The names that belong to one router with edges to choose only.
        var ownedResults: Set<String> = []
        /// The choosing routers from each phase, in declaration order.
        var byPhase: [String: [Route]] = [:]
        /// The first choosing router of each source phase and trigger, by the phase and then the trigger.
        var byTrigger: [String: [Trigger: Route]] = [:]
        /// Every scope's key in identifier order, each key's identifier, and the phases each stays active in.
        var scopeKeys: [String] = []
        var scopeIndices: [String: Int] = [:]
        var scopePhases: [String: [String]] = [:]

        init() {}

        init(
            phases: [Phase],
            scopes: [String],
            scopeActiveIn: [String: [String]],
            operations: [Operation],
            events: [Event],
            transitions: [Transition],
            routes: [Route]
        ) {
            for (index, phase) in phases.enumerated() where phaseIndices[phase.caseName] == nil {
                phaseIndices[phase.caseName] = index
                phaseTypes[phase.caseName] = phase.typeName
            }
            // A named scope spans its `@Active(in:)` phases or every phase; an operation that names none has
            // a private scope of its own, keyed by its name, active in its `activeIn:` phases.
            let every = phases.map(\.caseName)
            for scope in scopes where scopePhases[scope] == nil { scopePhases[scope] = scopeActiveIn[scope] ?? every }
            for operation in operations where scopePhases[operation.scopeKey] == nil {
                scopePhases[operation.scopeKey] = operation.privatePhases ?? operation.activeIn
            }
            scopeKeys = scopes + operations.filter { $0.scope == nil }.map(\.scopeKey)
            for (index, key) in scopeKeys.enumerated() where scopeIndices[key] == nil { scopeIndices[key] = index }
            for operation in operations {
                if self.operations[operation.effect] == nil { self.operations[operation.effect] = operation }
                if operationsByName[operation.name] == nil { operationsByName[operation.name] = operation }
            }
            for event in events where self.events[event.effect] == nil { self.events[event.effect] = event }
            var effects: [String: [[Set<String>]]] = [:]
            for edge in transitions where edge.effectNamespace != nil {
                effects[edge.name, default: []].append([Set(edge.starts), Set(edge.cancels), Set(edge.emits)])
            }
            effectNames = Set(effects.keys)
            for (name, lists) in effects where lists.dropFirst().allSatisfy({ $0 == lists.first }) {
                sharedEffects.insert(name)
            }
            var edges: [String: [String: Int]] = [:]
            for (index, edge) in transitions.enumerated() where edges[edge.from]?[edge.name] == nil {
                edges[edge.from, default: [:]][edge.name] = index
            }
            var lists: [String: [Set<String>]] = [:]
            for route in routes where route.namespace != nil {
                choosing.append(route)
                candidates[route.declaration] = route.choices.compactMap { edges[route.from]?[$0] }
                lists[route.name, default: []].append(Set(route.choices))
                byPhase[route.from, default: []].append(route)
                if byTrigger[route.from]?[route.trigger] == nil {
                    byTrigger[route.from, default: [:]][route.trigger] = route
                }
            }
            for (name, sets) in lists {
                if sets.dropFirst().allSatisfy({ $0 == sets.first }) { sharedChoices.insert(name) }
                if sets.count == 1 { ownedResults.insert(name) }
            }
        }
    }

    /// Holds the ``Tables`` of one set of transitions and routes once they are computed.
    final class TablesMemo {
        var tables: Tables?
    }

    /// The tables of the schema's phases, operations, events, and current transitions and routes.
    var tables: Tables {
        if let tables = tablesMemo.tables { return tables }
        let tables = Tables(
            phases: phases,
            scopes: scopes,
            scopeActiveIn: scopeActiveIn,
            operations: operations,
            events: events,
            transitions: transitions,
            routes: routes
        )
        tablesMemo.tables = tables
        return tables
    }

    /// The routers that have edges to choose, and so a choice type.
    var choosingRouters: [Route] { tables.choosing }

    /// Whether every router named `name` chooses among the same edges, in any order, so the short
    /// `Route.<Router>` names one type that all of them return.
    func sharesChoice(_ name: String) -> Bool { tables.sharedChoices.contains(name) }

    /// Whether `name` belongs to one router only, so the short `Route.<Router>Result` names its owned result.
    func ownsResultName(_ name: String) -> Bool { tables.ownedResults.contains(name) }

    /// The spelling, inside the schema, of a router's choice type.
    func choiceType(_ route: Route) -> String? {
        guard let namespace = route.namespace else { return nil }
        if sharesChoice(route.name) { return "Route.\(namespace)" }
        return "Route.\(phaseType(route.from)).\(namespace)"
    }

    /// Every spelling of a router's choice type: its phase-qualified name and, when it exists, its short name.
    func choiceSpellings(_ route: Route) -> [String] {
        guard let namespace = route.namespace else { return [] }
        let qualified = "Route.\(phaseType(route.from)).\(namespace)"
        return sharesChoice(route.name) ? ["Route.\(namespace)", qualified] : [qualified]
    }

    /// The spelling, inside the schema, of a router's owned result type.
    func resultType(_ route: Route) -> String {
        let namespace = route.namespace ?? Schema.companion(route.name)
        if ownsResultName(route.name) { return "Route.\(namespace)Result" }
        return "Route.\(phaseType(route.from)).\(namespace)Result"
    }

    /// The phases with a router that has edges to choose; each has a `Route.<Phase>` namespace.
    var routePhases: [Phase] {
        let tables = tables
        return phases.filter { tables.byPhase[$0.caseName] != nil }
    }

    /// The router that selects an edge: the first with edges to choose from the edge's source on its trigger.
    func router(of edge: Transition) -> Route? { tables.byTrigger[edge.from]?[edge.trigger] }

    /// The routers with edges to choose from `phase`, in declaration order.
    func choosingRouters(from phase: String) -> [Route] { tables.byPhase[phase] ?? [] }

    /// A router's candidate edges in the order its choices list them.
    func branches(_ route: Route) -> [Transition] {
        (tables.candidates[route.declaration] ?? []).map { transitions[$0] }
    }

    /// The failure type of a router's `Owned` result's `rejected` case and of its `Observed` method's
    /// contribution: the pinned failure, or the router's own.
    func routerFailure(_ route: Route) -> String? { route.pinnedFailure ?? route.failureType }

    /// What an edge's `Owned` method returns, with its own source spelled `source`.
    ///
    /// With `qualified`, the schema's own types are spelled from the schema's name, so the result
    /// resolves inside the `Route` namespace, whose phase namespaces shadow the phase payload types.
    func ownedResult(_ edge: Transition, source: String, qualified: Bool = false) -> String {
        let prefix = qualified ? "\(name)." : ""
        let after = "\(prefix)Owned<\(prefix)\(phaseType(edge.to))>"
        let effect = effectType(edge).map { prefix + $0 } ?? "Swift::Never"
        let failure = edge.failureType.map { qualified ? qualify($0) : $0 }
        switch edge.shape {
        case .advance: return "StateMachine::Advance<\(source), \(after), \(effect), \(failure ?? "Swift::Never")>"
        case .change:
            guard let failure else { return "StateMachine::Change<\(after), \(effect)>" }
            return "StateMachine::Advance<\(source), \(after), \(effect), \(failure)>"
        case .destination:
            guard let failure else { return after }
            return "StateMachine::Advance<\(source), \(after), Swift::Never, \(failure)>"
        }
    }

    /// Whether a router's `Owned` method returns `Route.<Router>Result`: it can throw, or its candidate
    /// edges return different types, however each spells the type it throws.
    func needsOwnedResult(_ route: Route) -> Bool {
        guard route.namespace != nil else { return false }
        struct Result: Hashable {
            let shape: String
            let failure: FailureIdentity?
        }
        let results = branches(route)
            .map { edge in
                var normalized = edge
                normalized.failureType = edge.failureType.map { _ in "_StateMachineFailure" }
                return Result(
                    shape: Schema.spellingKey(spellings.type(ownedResult(normalized, source: "Self"))),
                    failure: edge.failureType.map(failureKey)
                )
            }
        return route.failureType != nil || Set(results).count > 1
    }

    // MARK: Preparation rejections

    /// The functions that throw a `PreparationRejection` case, as (name, source phase, failure type)
    /// in declaration order; an authored function with several sources appears once per source.
    var throwingFunctions: [(name: String, from: String, failure: String, declaration: Int)] {
        let edges = transitions.compactMap { edge in
            edge.failureType.map { (edge.name, edge.from, $0, edge.declaration) }
        }
        let routers = routes.compactMap { route in
            route.failureType.map { (route.name, route.from, $0, route.declaration) }
        }
        return (edges + routers).sorted { $0.3 < $1.3 }
            .map { (name: $0.0, from: $0.1, failure: $0.2, declaration: $0.3) }
    }

    /// The names of the throwing functions of which some throw different types, so each one's
    /// `PreparationRejection` case is told apart by its source phase.
    ///
    /// It reads each function's failure once, in one pass, so the expansion computes it once rather than
    /// once for every case it names.
    var namesThrowingDifferentFailures: Set<String> {
        var failures: [String: Set<FailureIdentity>] = [:]
        for function in throwingFunctions {
            failures[function.name, default: []].insert(failureKey(function.failure))
        }
        return Set(failures.filter { $0.value.count > 1 }.keys)
    }

    /// The `PreparationRejection` case of a throwing function: its name, unless functions of that name
    /// throw different types, as `distinguished` lists them, in which case it is prefixed with its source
    /// phase: `draftSave`.
    static func rejectionCase(_ name: String, from: String, distinguished: Set<String>) -> String {
        distinguished.contains(name) ? (from + Schema.companion(name)).composed : name
    }

    // MARK: Reserved names

    /// Whether any completion edge or completion router can refuse an outcome, so a managed owner's
    /// caller must choose how a retained completion is settled.
    ///
    /// A function refuses when it throws, and an edge also when it starts an operation whose admission
    /// can reject it, which `.rejectWhenActive` and `.parallel(limit:)` can.
    var completionCanRefuse: Bool {
        let edges = transitions.filter { [.success, .failure].contains($0.trigger.kind) }
        let routers = routes.filter { [.success, .failure].contains($0.trigger.kind) }
        let admissions = tables.operations
        return edges.contains { edge in
            edge.failureType != nil || edge.starts.contains { admissions[$0]?.admission != .latest }
        } || routers.contains { $0.failureType != nil }
    }

    /// Whether the `@Restoration` function throws, so `reset(restoring:)` reports either its failure or
    /// the owner's refusal through `ResetRejection`.
    var resetRejects: Bool { restoration?.failureType != nil }

    /// The names an authored member of the schema may not take: every member the generator emits for
    /// the selected owners, and the few names generated code spells without qualification.
    ///
    /// A name is reserved only when something the schema generates declares or uses it, so a schema
    /// that lists only `.local` may declare its own `Shared`. Generated code spells standard-library
    /// types such as `Swift::Hashable` and runtime types such as `StateMachine::Limits` through module
    /// selectors, so a schema may declare its own `Hashable`, `Result`, `Swift`, or `StateMachine`; the
    /// short names authored transitions return are reserved whatever the owners.
    var reservedNames: Set<String> {
        fixedGeneratedNames.union(operationTypeNames.map(\.name))
    }

    /// The names the schema's own name may not take: every reserved name, and each type a generated
    /// scope declares that generated code inside it reaches through the schema's name.
    ///
    /// `PendingCompletion` declares `Outcome` and `Rejection`, and its outcome's cases spell each
    /// operation's types from the schema's name.
    var schemaNameReservations: Set<String> {
        reservedNames.union(generatesObservingOwner && !operations.isEmpty ? ["Outcome", "Rejection"] : [])
    }

    /// The types the expansion declares at the schema's scope for its operations.
    ///
    /// Each is paired with the operation that generates it: its request, its completion, and `Local`'s
    /// work, for the owners that use them, and the generic struct a work specializes.
    var operationTypeNames: [(name: String, operation: String)] {
        operations.flatMap { operation -> [(name: String, operation: String)] in
            var names: [String] = []
            if operation.hasRequest { names.append(operation.request) }
            if generatesObservingOwner { names.append(operation.name + "Completion") }
            if generates(.local) { names.append(operation.work) }
            if generates(.local), !operation.neverSucceeds { names.append(operation.workStorage) }
            return names.map { (name: $0, operation: operation.name) }
        }
    }

    // MARK: Checked readings

    /// A reference the expansion checks names the standard library's `Void` or `Never`, which the
    /// macro read it as.
    struct StandardReference: Hashable {
        /// `Void` or `Never`.
        let standard: String
        /// The spelling the expansion checks at the schema's scope, such as `Load.Output`.
        let reference: String
    }

    /// The references that must name the standard library's `Void` or `Never`, in declaration order:
    /// each type the macro read as one of them without being able to confirm it, such as an `Output`
    /// spelled with a bare `Void`, or a type a function throws spelled with a bare `Never`.
    ///
    /// The macro cannot see a declaration outside the schema, an extension, or an inherited member, so
    /// the expansion checks the type itself, spelled at the schema's scope where it resolves as the
    /// author's declaration does.
    var standardNameChecks: [StandardReference] {
        typeChecks.compactMap { check in
            guard case .isStandard(let name, _) = check.kind else { return nil }
            return StandardReference(standard: name, reference: check.reference)
        }
    }

    /// The name of the witness function that checks a reference names the standard library's `Void` or `Never`.
    static func standardNameWitness(_ standard: String) -> String { "_stateMachineIsSwift\(standard)" }

    /// The spellings the expansion checks do not name the standard library's `Never`, in declaration
    /// order: each operation alias, event payload, and type an authored function throws that the macro
    /// reads as a type with values without being able to confirm it, because it names a type the macro
    /// cannot see into or reads through a name that something it cannot see could hide.
    ///
    /// Such a type may be an alias of `Never`, and reading it as a type with values would give an
    /// operation an input or key no transition can construct or an outcome that can never happen, an
    /// event a payload no transition can construct, and a function a failure it can never throw, which
    /// generated code would try to catch.
    var neverProbes: [String] {
        typeChecks.compactMap { check in
            guard case .isNotNever = check.kind else { return nil }
            return check.reference
        }
    }

    /// The witness functions the expansion declares for its checks, and the name each check calls.
    struct CheckPlan {
        /// Each check that a type is the standard library's `Void` or `Never`, by type and message,
        /// with the name of its function; a `nil` message is the one that says the macro read it so.
        private(set) var standards: [(standard: String, message: String?, function: String)] = []
        /// Each second stage of a check that a type is not `Never`, by message, with its function's name.
        private(set) var stages: [(message: String?, function: String)] = []
        /// Each function of `standards` and `stages` by what it checks, and how many functions check each
        /// standard type, so finding one takes one lookup however many messages there are.
        private var standardFunctions: [StandardCheck: String] = [:]
        private var standardCounts: [String: Int] = [:]
        private var stageFunctions: [String?: String] = [:]

        private struct StandardCheck: Hashable {
            let standard: String
            let message: String?
        }
        /// The protocols the schema is checked to conform to.
        private(set) var conformances: [String] = []
        /// Whether a check reads a type's `Never` probe, two types' probe, or an `Input` case's payload.
        private(set) var probesNever = false
        private(set) var probesPairs = false
        private(set) var readsCasePayloads = false
        /// Whether a check requires a type to be `Sendable`.
        private(set) var requiresSendable = false
        /// The reasons an `Owned` router's checks require a value to be `Sendable`, and the joins for which
        /// they require it or the value it is joined with to be.
        private(set) var routedShares: [TypeCheck.RoutedShare] = []
        private(set) var routedJoins: [TypeCheck.RoutedJoin] = []
        /// Whether a check sorts a type by whether it is `Sendable`.
        var sortsSharing: Bool { !routedShares.isEmpty || !routedJoins.isEmpty }

        init(_ checks: [TypeCheck]) {
            for check in checks {
                switch check.kind {
                case .isStandard(let standard, let message):
                    _ = function(standard, message)
                case .isNotNever(let message):
                    probesNever = true
                    _ = stage(message)
                case .casePayloadIsNotNever(let message):
                    probesNever = true
                    readsCasePayloads = true
                    _ = stage(message)
                case .finishes(let message):
                    probesPairs = true
                    _ = stage(message)
                case .conformsToStandard(let name):
                    if !conformances.contains(name) { conformances.append(name) }
                case .isSendable:
                    requiresSendable = true
                case .sharedAfterRouter(let reason):
                    if !routedShares.contains(reason) { routedShares.append(reason) }
                case .transfersAfterRouter(_, let joined):
                    if !routedJoins.contains(joined) { routedJoins.append(joined) }
                }
            }
        }

        /// The function that checks a type is the standard library's `standard`, reporting `message`.
        mutating func function(_ standard: String, _ message: String?) -> String {
            let check = StandardCheck(standard: standard, message: message)
            if let known = standardFunctions[check] { return known }
            let base = Schema.standardNameWitness(standard)
            let count = standardCounts[standard, default: 0]
            let name = count == 0 ? base : base + "\(count + 1)"
            standards.append((standard, message, name))
            standardFunctions[check] = name
            standardCounts[standard] = count + 1
            return name
        }

        /// The function that rejects a probe that found `Never`, reporting `message`.
        mutating func stage(_ message: String?) -> String {
            if let known = stageFunctions[message] { return known }
            let name = "_stateMachineIsNotSwiftNever" + (stages.isEmpty ? "" : "\(stages.count + 1)")
            stages.append((message, name))
            stageFunctions[message] = name
            return name
        }

        /// The name of the function that checks the schema conforms to the standard library's `name`.
        static func conformanceWitness(_ name: String) -> String { "_stateMachineConformsToSwift\(name)" }

        /// The name of the function that requires a value an `Owned` router's method gives away while it
        /// still passes it on to be `Sendable`.
        static func sharingWitness(_ reason: TypeCheck.RoutedShare) -> String {
            switch reason {
            case .routerSends: "_stateMachineReusedAfterRouter"
            case .edgesDiffer: "_stateMachineKeptByRouter"
            }
        }

        /// The name of the function that requires a value an `Owned` router joins with another, or that
        /// other, to be `Sendable`.
        static func joinWitness(_ joined: TypeCheck.RoutedJoin) -> String {
            switch joined {
            case .source: "_stateMachineTransfersAfterRouter"
            case .value: "_stateMachineTransfersWithRouterValue"
            }
        }

        /// Every name the plan's functions and types take.
        var names: Set<String> {
            var names = Set(standards.map(\.function) + stages.map(\.function))
            names.formUnion(conformances.map(Self.conformanceWitness))
            if probesNever || probesPairs { names.insert("_StateMachineReadsNever") }
            if probesNever { names.insert("_stateMachineNeverProbe") }
            if probesPairs { names.insert("_stateMachineNeverPairProbe") }
            if readsCasePayloads { names.insert("_stateMachineCasePayload") }
            if requiresSendable { names.insert("_SendingValueIsSendable") }
            if sortsSharing {
                names.formUnion(["_StateMachineShared", "_StateMachineUnshared", "_stateMachineSharing"])
                names.formUnion(routedShares.map(Self.sharingWitness) + routedJoins.map(Self.joinWitness))
            }
            return names
        }
    }

    /// The witness functions the expansion declares for its checks.
    var checkPlan: CheckPlan { CheckPlan(typeChecks) }

    /// Whether a function takes its payload as its own, so a caller gives it up: `consuming` or `__owned`,
    /// with or without `sending`, or `sending` without an ownership. `__shared sending` lends it.
    static func ownsPayload(ownership: String, convention: String) -> Bool {
        ownership == "consuming " || ownership == "__owned " || (ownership.isEmpty && convention.contains("sending "))
    }

    /// The ownership of an `Owned` routed method's payload parameter, which lends the payload to the
    /// router and then passes it on to the edge the router selects, chosen from the authored spellings
    /// alone so that the method is legal whatever type the payload is, a nonescaping closure or a
    /// noncopyable value among them, whenever the router and its edges are.
    ///
    /// - When some function of the group takes the payload `@escaping`, which Swift allows of a function
    ///   type alone, so the payload is copyable: none, and the method takes it escaping, so it can pass it
    ///   to an edge that keeps it and lend it to a nonescaping router or edge, converting it at each call;
    ///   `__shared` when a function of the group sends the payload, the one lending convention `sending`
    ///   can join, so the method passes it on as `sending` and a caller that only borrows it can call the
    ///   method. Neither repeats a `borrowing` the group spells: Swift 6.4 fails to compile a `borrowing`
    ///   escaping parameter lent to a nonescaping one.
    /// - None when some function of the group declares no ownership, which Swift requires of a
    ///   noncopyable parameter, so the payload is copyable and passes as a plain parameter does, copied
    ///   implicitly where it is needed twice; and none when the router takes the payload as its own,
    ///   which an edge taking it after leaves to a copyable payload alone, as
    ///   ``requiresCopyableRoutedPayload(_:)`` checks.
    /// - Otherwise, when an edge the router may select takes the payload as its own, the ownership that
    ///   passes it on: `consuming` when a function of the group spells `consuming`, so the payload is no
    ///   nonescaping closure, which cannot be `consuming`, and `__owned` otherwise, as the group spells it,
    ///   which any type can be.
    /// - Otherwise, when every function only lends the payload, `borrowing`, so a caller that only borrows
    ///   it can call the method; `__shared` when a function takes it `__shared sending`, the one lending
    ///   convention that `sending` can join, which the method's own parameter then repeats.
    func routedOwnership(_ route: Route) -> String {
        let edges = branches(route)
        let ownerships = [route.payloadOwnership] + edges.map(\.payloadOwnership)
        let conventions = [route.payloadConvention] + edges.map(\.payloadConvention)
        if conventions.contains(where: { $0.contains("@escaping ") }) {
            return conventions.contains { $0.contains("sending ") } ? "__shared " : ""
        }
        if ownerships.contains(where: \.isEmpty)
            || Self.ownsPayload(ownership: route.payloadOwnership, convention: route.payloadConvention)
        {
            return ""
        }
        if edges.contains(where: { Self.ownsPayload(ownership: $0.payloadOwnership, convention: $0.payloadConvention) })
        {
            return ownerships.contains("consuming ") ? "consuming " : "__owned "
        }
        return conventions.contains { $0.contains("sending ") } ? "__shared " : "borrowing "
    }

    /// Whether an `Owned` routed method checks that its payload is copyable: when every function of the
    /// group declares an ownership and none takes the payload `@escaping`, so the payload may be
    /// noncopyable, and the router takes the payload as its own while the edge it selects takes it after,
    /// which only a copyable payload allows.
    func requiresCopyableRoutedPayload(_ route: Route) -> Bool {
        let edges = branches(route)
        return route.namespace != nil && route.payloadType != nil
            && !([route.payloadOwnership] + edges.map(\.payloadOwnership)).contains(where: \.isEmpty)
            && !([route.payloadConvention] + edges.map(\.payloadConvention)).contains { $0.contains("@escaping ") }
            && Self.ownsPayload(ownership: route.payloadOwnership, convention: route.payloadConvention)
    }

    /// The role of a completion parameter that the expansion compares with its declared type: the
    /// output or failure a completion edge or router takes after its source, or its `request:`.
    enum CompletionRole: CaseIterable {
        case output, failure, request

        /// The witness function that compares a parameter of this role with its declared type.
        var witness: String {
            switch self {
            case .output: "_stateMachineTakesOutput"
            case .failure: "_stateMachineTakesFailure"
            case .request: "_stateMachineTakesRequest"
            }
        }

        /// The message of the witness's unavailable overload, which names the role and the repair.
        var message: String {
            switch self {
            case .output:
                "A success edge or router takes its operation's output in the unlabeled parameter after its source, so that parameter's type must be exactly the operation's Output; take the request with the argument label request:, or declare the Output this parameter takes."
            case .failure:
                "A failure edge or router takes its operation's failure in the unlabeled parameter after its source, so that parameter's type must be exactly the operation's Failure; take the request with the argument label request:, or declare the Failure this parameter takes."
            case .request:
                "A completion edge or router takes its operation's request in the parameter labeled request:, so that parameter's type must be exactly the request the macro generates for the operation, named <Operation>Request; take any other value without a label."
            }
        }
    }

    /// The completion roles whose parameters some edge or router takes, each compared by its witness.
    var completionRoles: [CompletionRole] {
        let functions =
            transitions.map { ($0.trigger.kind, $0.payloadType, $0.takesRequest) }
            + routes.map { ($0.trigger.kind, $0.payloadType, $0.takesRequest) }
        return CompletionRole.allCases.filter { role in
            functions.contains { kind, payload, request in
                switch role {
                case .output: kind == .success && payload != nil
                case .failure: kind == .failure && payload != nil
                case .request: request
                }
            }
        }
    }

    /// Whether an edge that an `Input` case triggers takes its payload, so a witness infers that payload
    /// from a pattern of its case.
    var witnessesInputPayloads: Bool {
        transitions.contains { $0.trigger.kind == .input && $0.payloadType != nil }
            || routes.contains { $0.trigger.kind == .input && $0.payloadType != nil }
    }

    /// The local alias through which each check names the type it checks, so a spelling of any form
    /// resolves as a type: a name the schema's source spells nowhere, so no spelling can name it.
    var checkedAlias: String {
        var candidate = "_StateMachineChecked"
        var next = 1
        // A check of two types also names the second through this name followed by `Other`.
        while authoredIdentifiers.contains(candidate) || authoredIdentifiers.contains(candidate + "Other") {
            next += 1
            candidate = "_StateMachineChecked\(next)"
        }
        return candidate
    }

    /// The names of the members the expansion declares for the selected owners whatever the schema's
    /// operations are called, and the few names generated code spells without qualification.
    var fixedGeneratedNames: Set<String> {
        var names: Set<String> = [
            // `Owned` and `Observed` are generic over `Phase`, which inside them would shadow a schema type.
            "Phase",
            // Authored transitions spell these runtime results by their short names. Generated code
            // names every other runtime and standard-library type through a module selector, such as
            // `StateMachine::Limits` or `Swift::Hashable`, which no declaration hides.
            "Change", "Advance",
            // Every schema generates its effects, graph, and compiler witnesses.
            "Effect", "graph", "_stateMachineGraph", "_StateMachineGraph", "_StateMachineSchema",
            "_StateMachineScopeID",
            "_StateMachineOperation",
            "_StateMachineKey", "_TransitionSourceIsPhasePayload",
            "_TransitionReturnsDeclaredResult", "_TriggerPayloadMatchesDeclaration", "_RouterSourceIsPhasePayload",
            "_SharedModeRequiresSendable", "_OperationFailureIsError", "_OperationKeyIsHashable", "_EffectIsCopyable",
            "_stateMachineWitnesses",
        ]
        names.formUnion(checkPlan.names)
        // Every expansion checks that the schema's name names the schema, and infers an `Input` case's
        // payload through its constructor.
        names.insert("_stateMachineNamesSchema")
        if witnessesInputPayloads { names.insert("_stateMachineInputPayload") }
        names.formUnion(completionRoles.map(\.witness))
        if generates(.owned), routes.contains(where: requiresCopyableRoutedPayload) {
            names.insert("_stateMachineCopy")
        }
        // Only a router with edges to choose has a choice type in `Route`.
        if !choosingRouters.isEmpty { names.insert("Route") }
        if generates(.owned) { names.formUnion(["Owned", "owned"]) }
        if generatesObservingOwner {
            names.formUnion([
                "Observed", "Snapshot", "Prepared", "PreparationRejection", "CommitResult", "CommitRejection",
                "Receipt", "SendRejection", "Restoration", "prepare", "_StateMachineEngine", "_stateMachineSnapshot",
                "_stateMachineAdmission", "_stateMachinePrepare", "_stateMachineEligibility",
            ])
            if restoration != nil { names.insert("_stateMachineRestored") }
            if resetRejects { names.insert("ResetRejection") }
        }
        // Deprecated functions are called through a protocol and type of the expansion's, and a deprecated
        // input edge's `Observed` method through one that is not deprecated.
        if transitions.contains(where: { $0.deprecation != nil }) || routes.contains(where: { $0.deprecation != nil })
            || restoration?.deprecation != nil
        {
            names.formUnion([
                "_StateMachineDeprecatedFunctions", "_StateMachineDeprecatedCalls", "_stateMachineDeprecated",
            ])
            for edge in transitions where edge.deprecation != nil && edge.trigger.kind == .input {
                names.insert("_stateMachineDeprecated\(edge.declaration)")
            }
        }
        if generatesObservingOwner && !operations.isEmpty {
            names.formUnion([
                "Completion", "PendingStatus", "PendingCompletionID", "PendingCompletion", "ReconcileResult",
                "DiscardResult", "_StateMachineLedger", "_stateMachineFinish", "_stateMachineDeliveryPreparation",
                "_stateMachineCompletion",
            ])
        }
        if generates(.local) {
            // `Local` declares the type witnesses of its harness conformance, which would shadow a
            // schema type of the same name inside it.
            names.formUnion(["Local", "LocalConfiguration", "InitialPhase"])
            // A restoring `Local` infers these witnesses from its restoring resets.
            if restoration != nil { names.formUnion(["RestorationArchive", "RestorationRejection"]) }
            if !operations.isEmpty {
                names.formUnion(["ExecutionHandle", "ExecutionDisposition", "AcknowledgmentResult", "DeliveryResult"])
            }
            if !operations.isEmpty || !events.isEmpty {
                names.formUnion(["Command", "CommandBatch", "_stateMachineBatch"])
            }
        }
        if generatesManagedOwner {
            names.formUnion([
                "Configuration", "SubscriptionFailure", "ShutdownResult", "ShutdownDiagnostics", "FlushResult", "Host",
            ])
            if !operations.isEmpty { names.insert("CompletionPolicy") }
        }
        // Each sequence alias exists for the owners that return it.
        if mode == .shared && generatesManagedOwner || mode != .shared && generates(.mainActorHost) {
            names.insert(mode == .shared ? "Snapshots" : "MainActorSnapshots")
            if !operations.isEmpty { names.insert("PendingCompletionUpdates") }
        }
        if mode != .shared && generates(.isolatedHost) {
            names.insert("IsolatedSnapshots")
            if !operations.isEmpty { names.insert("IsolatedPendingCompletionUpdates") }
        }
        if generates(.shared) { names.insert("Shared") }
        if generates(.actorHost) { names.insert("ActorHost") }
        if generates(.mainActorHost) {
            names.formUnion(["MainActorHost", "MainActorSubscription"])
            if !operations.isEmpty { names.insert("MainActorDrivers") }
        }
        // `IsolatedHost` is generic over `Owner`, which inside it would shadow a schema type of that name.
        if generates(.isolatedHost) { names.formUnion(["IsolatedHost", "Owner", "IsolatedSubscription"]) }
        if generates(.shared) || generates(.actorHost) { names.insert("Subscription") }
        if (generates(.shared) || generates(.actorHost) || generates(.isolatedHost)) && !operations.isEmpty {
            names.insert("Drivers")
        }
        return names
    }

    // MARK: Spelling

    /// The identity of a failure type: what a confirmed reading names, or the spelling of an unconfirmed one.
    enum FailureIdentity: Hashable {
        case reading(TypeKey)
        case spelled(String)
    }

    /// The identity of a type an authored function throws, the same for every spelling of it that the
    /// schema resolves alike: `Problem`, `Self.Problem`, `Flow.Problem`, and an alias of it that the
    /// schema declares, with any comments or spacing.
    ///
    /// A reading the macro cannot confirm is identified by its spelling alone, so two spellings share a
    /// failure through it only when they are one spelling; an alias declared outside the schema is
    /// invisible to the macro, so it keys apart from the type it names. A router's `failure:` names the
    /// common failure explicitly.
    func failureKey(_ spelling: String) -> FailureIdentity {
        let authored = spellingAliasTargets[spelling] ?? spelling
        let type = spellings.type(authored)
        let reading = typeScopes.resolve(type)
        return reading.isConfirmed
            ? .reading(reading.key) : .spelled(Schema.relativeKey(type, schema: name))
    }

    // MARK: Shielded spellings

    /// The type names the expansion declares in a scope nested inside the schema, where each would
    /// capture an authored spelling that means another type of that name at the schema's scope.
    ///
    /// They are the generic parameters of `Owned`, `Observed`, and `IsolatedHost`, each managed host's
    /// own aliases, the conformance types `Local` infers, and the members of `Route`, where an owned
    /// result spells the failures its edges throw. Every other type a nested scope declares is also
    /// declared, with the same meaning, at the schema's scope.
    var capturingNames: Set<String> {
        var names: Set<String> = []
        if generates(.owned) || generatesObservingOwner { names.insert("Phase") }
        if generatesManagedOwner { names.formUnion(["Host", "CompletionPolicy"]) }
        if generates(.isolatedHost) { names.formUnion(["Owner", "Drivers"]) }
        if generates(.local) { names.formUnion(["InitialPhase", "RestorationArchive", "RestorationRejection"]) }
        return names.union(routeMemberTypeNames)
    }

    /// The authored spellings that generated code may repeat inside a nested scope that would capture
    /// one of their names, each with the placeholder generation spells it through, in declaration order.
    ///
    /// ``SpellingShield`` then gives a schema-level alias, `_StateMachineType1` and so on, to the uses
    /// that a generated scope would capture, and spells every other use as authored. The alias is
    /// declared at the schema's scope, where the authored signature was resolved, so it names the type
    /// the author meant wherever generated code uses it. No placeholder or alias takes a name the
    /// schema's source spells, so none can capture an identifier of an authored spelling.
    var shieldedSpellings: [(alias: String, spelling: String)] {
        let names = capturingNames
        var result: [(alias: String, spelling: String)] = []
        // The spellings given an alias, so each is found in constant time.
        var shielded: Set<String> = []
        var next = 1
        func consider(_ spelling: String?) {
            guard let spelling, !Schema.freeNames(spellings.type(spelling)).isDisjoint(with: names),
                shielded.insert(spelling).inserted
            else { return }
            while authoredIdentifiers.contains("_StateMachineSpelling\(next)") { next += 1 }
            result.append(("_StateMachineSpelling\(next)", spelling))
            next += 1
        }
        for edge in transitions {
            consider(edge.payloadType)
            consider(edge.failureType)
        }
        for route in routes {
            consider(route.payloadType)
            consider(route.failureType)
            consider(route.pinnedFailure)
        }
        consider(restoration?.archiveType)
        consider(restoration?.failureType)
        return result
    }

    /// The schema with each spelling in ``shieldedSpellings`` replaced by its alias.
    func shieldingAuthoredSpellings() -> Schema {
        let aliases = Dictionary(uniqueKeysWithValues: shieldedSpellings.map { ($0.spelling, $0.alias) })
        guard !aliases.isEmpty else { return self }
        func shield(_ spelling: String?) -> String? { spelling.map { aliases[$0] ?? $0 } }
        var schema = self
        schema.transitions = transitions.map { edge in
            var edge = edge
            edge.payloadType = shield(edge.payloadType)
            edge.failureType = shield(edge.failureType)
            return edge
        }
        schema.routes = routes.map { route in
            var route = route
            route.payloadType = shield(route.payloadType)
            route.failureType = shield(route.failureType)
            route.pinnedFailure = shield(route.pinnedFailure)
            return route
        }
        if var restoration {
            restoration.archiveType = aliases[restoration.archiveType] ?? restoration.archiveType
            restoration.failureType = shield(restoration.failureType)
            schema.restoration = restoration
        }
        schema.spellingAliases = shieldedSpellings
        schema.spellingAliasTargets = Dictionary(
            shieldedSpellings.map { ($0.alias, $0.spelling) },
            uniquingKeysWith: { first, _ in first }
        )
        return schema
    }

    // MARK: Generated namespaces

    /// The types the expansion declares inside `Route`, at its top level and in its phase namespaces.
    var routeMemberTypeNames: Set<String> {
        var names = Set(routePhases.map(\.typeName))
        for router in choosingRouters {
            guard let namespace = router.namespace else { continue }
            names.insert(namespace)
            if generates(.owned), needsOwnedResult(router) { names.insert(namespace + "Result") }
        }
        return names
    }

    /// Qualifies an authored type spelling with the schema's name wherever it names one of the schema's
    /// own types or `Self`, so it resolves inside a generated namespace that shadows them.
    func qualify(_ spelling: String) -> String {
        TypeQualifier.qualify(spellings.type(spelling), owner: name, names: typeNames)
    }
}
