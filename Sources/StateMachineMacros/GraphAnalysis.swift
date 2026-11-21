/// The structural checks of a schema's graph, computed from its declarations alone.
///
/// The analysis over-approximates what can happen: an edge can fire as soon as its source is
/// reachable and, for a completion, its operation may be active there, because the macro cannot know
/// whether an authored function throws, which edge a router chooses, or which effects an edge
/// returns. A finding therefore means that no declared path exists, never that one is unlikely.
///
/// A path is followed through configurations: a phase together with the outstanding executions of
/// every operation at once, so work that one path starts is never combined with work that only
/// another path holds. A graph whose configurations take more than ``jointAnalysisBudget`` to explore
/// is checked per operation instead, which combines paths and so can only accept more graphs. A schema that
/// generates only `Owned` holds no work authority, so its completion edges need only their source.
extension Schema {
    /// A structural defect, named by the declaration at fault.
    enum GraphFinding: Equatable {
        /// No path leads to the phase from the initial phase or a restorable phase.
        case unreachablePhase(String)
        /// The phase has no outgoing edge and is not `@Terminal`.
        case missingExit(String)
        /// No transition lists the operation in `starts:`.
        case unstartedOperation(String)
        /// Every transition that lists the operation in `starts:` can never fire.
        case unreachableStart(String)
        /// The operation can start, but no edge accepts any of its outcomes where it may be active.
        case unacceptedOperation(String)
        /// The operation can start and some edge accepts one of its outcomes, but no edge accepts the
        /// other, `.success` or `.failure`, where it may be active.
        case unacceptedOutcome(String, Trigger.Kind)
        /// The completion edge, by index into `transitions`, can never fire, because its operation is
        /// never active in its source phase.
        case unfiredCompletion(Int)
        /// The completion router, by index into `routes`, can never run for the same reason.
        case unrunCompletionRouter(Int)
    }

    /// How many executions of one operation may be outstanding at once, as the analysis counts them.
    enum Outstanding: Hashable {
        /// Exactly this many, at least one.
        case exactly(Int)
        /// A number the declarations do not bound, so no completion is known to retire the last one.
        case unbounded
    }

    /// What a declared path can establish.
    struct GraphReach {
        /// The phases some path reaches.
        var phases: Set<String> = []
        /// The phases in which each operation, by effect case, may be active, with the counts of its
        /// outstanding executions that some path establishes there.
        var active: [String: [String: Set<Outstanding>]] = [:]
        /// The transitions, by index, that some path can take.
        var fired: Set<Int> = []

        /// The phases in which the operation may be active.
        func phases(active effect: String) -> Set<String> { Set((active[effect] ?? [:]).keys) }
    }

    /// The phases that restoration may enter, each with no outstanding work.
    var restorationEntrances: [String] { restoration == nil ? [] : restorablePhases.map(\.caseName) }

    /// The largest parallel limit whose outstanding executions the analysis counts one by one; a larger
    /// limit is treated as unbounded, which can only accept more graphs.
    static let countedParallelLimit = 32

    /// The most executions of an operation that can be outstanding at once, or `nil` when the
    /// declarations bound none: a keyed operation runs independent work for any number of keys.
    func outstandingLimit(_ operation: Operation) -> Int? {
        guard !operation.isKeyed else { return nil }
        switch operation.admission {
        case .latest, .rejectWhenActive: return 1
        case .parallel(let limit): return limit <= Self.countedParallelLimit ? limit : nil
        }
    }

    /// The most work the joint analysis does before it falls back to checking each operation on its
    /// own, counted as the operation counts it reads or writes.
    ///
    /// It bounds the macro's time on a graph whose operations combine into many configurations; the
    /// stress graphs and every example fit well within it.
    static let jointAnalysisBudget = 1 << 21

    /// The most phases, `Input` cases, operations, and effect cases (each operation, two cancellations of each
    /// cancelled operation, and each event) a schema may declare: Swift checks a switch over at most 628 cases
    /// that carry values in reasonable time, a routed input or an operation costs it more than a phase, and
    /// type-checking 512 operations for every owner takes it more than a minute where 256 take seconds.
    static let phaseLimit = 600
    static let inputLimit = 512
    static let operationLimit = 256
    static let effectLimit = 512

    /// The refusal of a schema larger than a limit, or `nil`.
    ///
    /// The expansion checks it, so the parser's own work stays measurable on larger schemas.
    var sizeLimitExcess: String? {
        let sizes = [
            (phases.count, Self.phaseLimit, "phases", "Snapshot"),
            (inputs.count, Self.inputLimit, "input cases", "Input"),
            (operations.count, Self.operationLimit, "operations", "Completion"),
            (
                operations.count + 2 * cancelledOperations.count + events.count, Self.effectLimit,
                "operations, cancellations, and events", "Effect"
            ),
        ]
        guard let (count, limit, what, generated) = sizes.first(where: { $0.0 > $0.1 }) else { return nil }
        return
            "This schema declares \(count) \(what); the macro accepts at most \(limit), because Swift checks a switch over its \(generated) cases only within a fixed budget and type-checks a larger expansion slowly. Split the graph into several schemas."
    }

    /// Computes reachability and operation liveness.
    ///
    /// A schema that generates only `Owned` has no tickets: each completion edge is a consuming method
    /// that needs only its source phase, so every edge from a reached phase fires. Any other schema is
    /// explored by configuration, within ``jointAnalysisBudget``, and otherwise per operation.
    func reach() -> GraphReach {
        if !generatesObservingOwner { return ownedReach() }
        return jointReach() ?? operationReach()
    }

    /// Reachability when every edge fires from a reached source, as the methods of `Owned` do.
    func ownedReach() -> GraphReach {
        var reach = GraphReach()
        let outgoing = Dictionary(grouping: transitions.indices, by: { transitions[$0].from })
        var work = [initial] + restorationEntrances
        while let phase = work.popLast() {
            guard reach.phases.insert(phase).inserted else { continue }
            for index in outgoing[phase] ?? [] {
                reach.fired.insert(index)
                work.append(transitions[index].to)
            }
        }
        for operation in operations {
            for phase in operation.activeIn where reach.phases.contains(phase) {
                reach.active[operation.effect, default: [:]][phase] = [.unbounded]
            }
        }
        return reach
    }

    /// Reachability through configurations, or `nil` when exploring them takes more than `budget`.
    ///
    /// A configuration is a phase and, for each operation, its outstanding executions: none, an exact
    /// count up to the operation's bound, or unbounded. The initial phase and each restorable phase
    /// start with none. An input or direct edge fires from any configuration of its source; a
    /// completion edge fires from one in which its operation has an execution outstanding, and retires
    /// one. Every operation's work is carried into the destination when the destination keeps every
    /// scope it holds and the edge invalidates none of them, and an edge that starts an operation may
    /// raise its count to the bound.
    ///
    /// Outstanding work never prevents an edge from firing, and a larger count reaches everything a
    /// smaller one does, so each edge is followed only with the most work it may start, and a
    /// configuration that another of the same phase covers count for count is not explored.
    func jointReach(budget: Int = Self.jointAnalysisBudget) -> GraphReach? {
        let unbounded = Int.max
        let effects = operations.map(\.effect)
        let operationIndex = Dictionary(uniqueKeysWithValues: effects.enumerated().map { ($1, $0) })
        let limits = operations.map { outstandingLimit($0) ?? unbounded }
        let phaseNames = phases.map(\.caseName)
        let phaseIndex = Dictionary(uniqueKeysWithValues: phaseNames.enumerated().map { ($1, $0) })
        /// What an edge does to each operation's count, by operation index.
        struct Step {
            let from: Int
            let to: Int
            /// The operation whose execution the edge completes, if it is a completion edge.
            let completes: Int?
            /// Whether each operation keeps its work across the edge: active in the destination, with
            /// no scope it holds invalidated. Edges that invalidate nothing share their destination's.
            let keeps: [Bool]
            /// Whether each operation is active in the destination, so the edge may start it there; one
            /// array for each destination, which its edges share.
            let startable: [Bool]
            /// The operations the edge may start, by index.
            let starts: [Int]
        }
        let width = max(operations.count, 1)
        // Setup builds one operation-wide mask for each phase and for each edge that invalidates a scope,
        // and is charged before it allocates any, so a graph too large to explore falls back at once.
        var spent = (phases.count + transitions.count(where: { !$0.invalidates.isEmpty })) * width
        workCounter.work.jointSetupCharged += spent
        guard spent <= budget else { return nil }
        let active = operations.map { Set($0.activeIn) }
        let startableIn = phaseNames.map { phase in active.map { $0.contains(phase) } }
        workCounter.work.jointSetupBuilt += phases.count * operations.count
        let steps = transitions.map { edge -> Step in
            let completes: Int? =
                edge.trigger.kind == .success || edge.trigger.kind == .failure
                ? operationIndex[edge.trigger.name] : nil
            let to = phaseIndex[edge.to]!
            let startable = startableIn[to]
            var keeps = startable
            if !edge.invalidates.isEmpty {
                workCounter.work.jointSetupBuilt += operations.count
                let invalidated = Set(edge.invalidates)
                for (index, operation) in operations.enumerated() where keeps[index] {
                    keeps[index] =
                        !invalidated.contains(operation.scopeKey)
                        && !operation.requires.contains(where: invalidated.contains)
                }
            }
            return Step(
                from: phaseIndex[edge.from]!,
                to: to,
                completes: completes,
                keeps: keeps,
                startable: startable,
                starts: edge.starts.compactMap { operationIndex[$0] }
            )
        }
        let outgoing = Dictionary(grouping: steps.indices, by: { steps[$0].from })
        // The configurations of each phase that no other covers, by identifier into `counts`.
        var covering = [[Int]](repeating: [], count: phases.count)
        var counts: [[Int]] = []
        var superseded: [Bool] = []
        var phaseOf: [Int] = []
        var stack: [Int] = []
        /// Records a configuration unless another of its phase covers it, or reports `false` once the
        /// work exceeds the budget.
        func admit(_ phase: Int, _ vector: [Int]) -> Bool {
            spent += width * (covering[phase].count + 1)
            guard spent <= budget else { return false }
            for existing in covering[phase] where zip(counts[existing], vector).allSatisfy({ $0 >= $1 }) {
                return true
            }
            let identifier = counts.count
            covering[phase]
                .removeAll { existing in
                    let covered = zip(vector, counts[existing]).allSatisfy { $0 >= $1 }
                    if covered { superseded[existing] = true }
                    return covered
                }
            covering[phase].append(identifier)
            counts.append(vector)
            superseded.append(false)
            phaseOf.append(phase)
            stack.append(identifier)
            return true
        }
        let empty = [Int](repeating: 0, count: operations.count)
        for entrance in [initial] + restorationEntrances {
            guard admit(phaseIndex[entrance]!, empty) else { return nil }
        }
        var fired: Set<Int> = []
        while let identifier = stack.popLast() {
            // A configuration covered since it was admitted reaches nothing its cover does not.
            guard !superseded[identifier] else { continue }
            let source = counts[identifier]
            for index in outgoing[phaseOf[identifier]] ?? [] {
                let step = steps[index]
                if let completes = step.completes, source[completes] == 0 { continue }
                fired.insert(index)
                var vector = empty
                for operation in operations.indices {
                    var count = step.keeps[operation] ? source[operation] : 0
                    if operation == step.completes, count != unbounded { count = max(count - 1, 0) }
                    vector[operation] = count
                }
                for operation in step.starts where step.startable[operation] {
                    vector[operation] = max(vector[operation], limits[operation])
                }
                guard admit(step.to, vector) else { return nil }
            }
        }
        var reach = GraphReach(fired: fired)
        for (identifier, vector) in counts.enumerated() {
            let phase = phaseNames[phaseOf[identifier]]
            reach.phases.insert(phase)
            for (operation, count) in vector.enumerated() where count > 0 {
                reach.active[effects[operation], default: [:]][phase, default: []]
                    .insert(count == unbounded ? .unbounded : .exactly(count))
            }
        }
        return reach
    }

    /// Reachability and operation liveness per operation, to a fixed point.
    ///
    /// The initial phase and each restorable phase start with no active work. An input or direct edge
    /// fires once its source is reached; a completion edge fires once its operation may be active in its
    /// source. Each operation's outstanding executions are counted where its declarations bound them:
    /// one for `.latest` and `.rejectWhenActive`, up to the limit for `.parallel(limit:)`, and without a
    /// bound for a keyed operation, whose keys each hold their own work. A fired edge carries the work
    /// of each operation active in its source into its destination when the destination keeps every
    /// scope the operation holds and the edge invalidates none of them; the operation's own completion
    /// retires one execution, and an edge that starts the operation may add executions up to its bound.
    ///
    /// Each operation's counts are tracked apart from the others', so an edge that one operation's work
    /// lets fire carries every other operation's work its source holds on any path.
    ///
    /// Edges that leave one phase for one destination and invalidate the same scopes carry every
    /// operation they neither start nor complete alike, so each such class carries an operation's count
    /// once, however many edges it has; only an edge's own operations are carried edge by edge. The work
    /// is then linear in the facts the analysis establishes and the classes and edges that carry them, and
    /// `steps` counts it.
    func operationReach() -> GraphReach {
        var steps = 0
        return operationReach(steps: &steps)
    }

    /// ``operationReach()``, adding each fact it visits and each carry it tries to `steps`.
    func operationReach(steps: inout Int) -> GraphReach {
        var reach = GraphReach()
        let limits = Dictionary(uniqueKeysWithValues: operations.map { ($0.effect, outstandingLimit($0)) })
        // What `carried` asks of each operation and edge, as sets, so each question takes constant time.
        let activeIn = Dictionary(uniqueKeysWithValues: operations.map { ($0.effect, Set($0.activeIn)) })
        let held = Dictionary(uniqueKeysWithValues: operations.map { ($0.effect, [$0.scopeKey] + $0.requires) })
        let starts = transitions.map { Set($0.starts) }
        let invalidates = transitions.map { Set($0.invalidates) }
        let completes = transitions.map { [.success, .failure].contains($0.trigger.kind) ? $0.trigger.name : nil }
        /// The operations an edge carries on its own: those it starts and the one it completes.
        let own = transitions.indices.map { starts[$0].union(completes[$0].map { [$0] } ?? []) }
        struct Carry: Hashable {
            let from: String
            let to: String
            let invalidates: Set<String>
        }
        struct Held: Hashable {
            let phase: String
            let effect: String
        }
        let carries = transitions.indices.map {
            Carry(from: transitions[$0].from, to: transitions[$0].to, invalidates: invalidates[$0])
        }
        // The edges that leave each phase and carry each operation on their own.
        var owning: [Held: [Int]] = [:]
        var entries: [String: [Int]] = [:]
        for (index, edge) in transitions.enumerated() {
            for effect in own[index] { owning[Held(phase: edge.from, effect: effect), default: []].append(index) }
            if edge.trigger.kind == .input || edge.trigger.kind == .direct {
                entries[edge.from, default: []].append(index)
            }
        }
        // The classes with a fired edge, by source phase, and for each the operations that every edge fired
        // in it carries on its own, which the class does not yet carry.
        var carrying: [String: [Carry]] = [:]
        var unshared: [Carry: Set<String>] = [:]
        var holding: [String: [(effect: String, count: Outstanding)]] = [:]
        enum Fact {
            case phase(String)
            case active(String, String, Outstanding)
            case edge(Int)
        }
        var work: [Fact] = ([initial] + restorationEntrances).map { .phase($0) }
        /// The counts an operation may have in the edge's destination, given `count` in its source,
        /// where `nil` is none outstanding.
        func carried(_ index: Int, _ effect: String, _ count: Outstanding?) -> [Outstanding] {
            let edge = transitions[index]
            guard activeIn[effect]!.contains(edge.to) else { return [] }
            var remaining = count
            if completes[index] == effect {
                // The completion settles one of the executions it needs in order to fire.
                switch count {
                case nil: return []
                case .exactly(let number): remaining = number > 1 ? .exactly(number - 1) : nil
                case .unbounded: break
                }
            }
            if !invalidates[index].isEmpty, held[effect]!.contains(where: invalidates[index].contains) {
                remaining = nil
            }
            guard starts[index].contains(effect) else { return remaining.map { [$0] } ?? [] }
            // The edge may start none of its listed work, or as many executions as admission allows.
            guard let limit = limits[effect]!, remaining != .unbounded else { return [.unbounded] }
            let base: Int
            if case .exactly(let number) = remaining { base = number } else { base = 0 }
            return (max(base, 1) ... limit).map(Outstanding.exactly) + (remaining.map { [$0] } ?? [])
        }
        func propagate(_ index: Int, _ effect: String, _ count: Outstanding?) {
            steps += 1
            for result in carried(index, effect, count) { work.append(.active(effect, transitions[index].to, result)) }
        }
        /// Carries a count through a class of edges none of which starts or completes the operation.
        func carry(_ group: Carry, _ effect: String, _ count: Outstanding) {
            steps += 1
            guard activeIn[effect]!.contains(group.to), !held[effect]!.contains(where: group.invalidates.contains)
            else { return }
            work.append(.active(effect, group.to, count))
        }
        while let fact = work.popLast() {
            steps += 1
            switch fact {
            case .phase(let phase):
                guard reach.phases.insert(phase).inserted else { continue }
                for index in entries[phase] ?? [] { work.append(.edge(index)) }
            case .active(let effect, let phase, let count):
                guard reach.active[effect, default: [:]][phase, default: []].insert(count).inserted else { continue }
                holding[phase, default: []].append((effect, count))
                for index in owning[Held(phase: phase, effect: effect)] ?? [] {
                    if completes[index] == effect { work.append(.edge(index)) }
                    // An edge that fires later carries every count its source holds by then.
                    if reach.fired.contains(index) { propagate(index, effect, count) }
                }
                for group in carrying[phase] ?? [] where !unshared[group]!.contains(effect) {
                    carry(group, effect, count)
                }
            case .edge(let index):
                guard reach.fired.insert(index).inserted else { continue }
                let edge = transitions[index]
                work.append(.phase(edge.to))
                for effect in edge.starts { propagate(index, effect, nil) }
                for effect in own[index] {
                    for count in reach.active[effect]?[edge.from] ?? [] { propagate(index, effect, count) }
                }
                let group = carries[index]
                if let pending = unshared[group] {
                    // An operation another edge of the class carried on its own, and this one does not, now
                    // passes through the class.
                    unshared[group] = pending.intersection(own[index])
                    for effect in pending where !own[index].contains(effect) {
                        for count in reach.active[effect]?[edge.from] ?? [] { carry(group, effect, count) }
                    }
                } else {
                    unshared[group] = own[index]
                    carrying[edge.from, default: []].append(group)
                    for (effect, count) in holding[edge.from] ?? [] where !own[index].contains(effect) {
                        carry(group, effect, count)
                    }
                }
            }
        }
        return reach
    }

    /// The structural defects of the graph in declaration order: phases, then operations, then edges
    /// and routers.
    ///
    /// A defect that follows from another is left out: an operation that never starts reports no
    /// completion of its own, and a phase that is never reached reports no completion that leaves it.
    func graphFindings() -> [GraphFinding] {
        let reach = reach()
        var findings: [GraphFinding] = []
        // What each loop below asks of every edge, gathered in one pass over the edges and routers, so the
        // findings take time linear in the declarations.
        let sources = Set(transitions.map(\.from))
        let listedStarts = Set(transitions.flatMap(\.starts))
        var accepting: [Trigger: Set<String>] = [:]
        for edge in transitions { accepting[edge.trigger, default: []].insert(edge.from) }
        struct Dispatch: Hashable {
            let from: String
            let trigger: Trigger
        }
        let routed = Set(routes.map { Dispatch(from: $0.from, trigger: $0.trigger) })
        for phase in phases {
            if !reach.phases.contains(phase.caseName) { findings.append(.unreachablePhase(phase.caseName)) }
            if !phase.isTerminal, !sources.contains(phase.caseName) {
                findings.append(.missingExit(phase.caseName))
            }
        }
        var started: Set<String> = []
        for index in reach.fired { started.formUnion(transitions[index].starts) }
        for operation in operations {
            guard started.contains(operation.effect) else {
                let listed = listedStarts.contains(operation.effect)
                findings.append(listed ? .unreachableStart(operation.name) : .unstartedOperation(operation.name))
                continue
            }
            let active = reach.phases(active: operation.effect)
            // A router without candidates declares no edge, so it accepts no outcome. An operation whose
            // output and failure are both `Never` has no outcome to accept: it runs until it is revoked.
            let outcomes = [Trigger.Kind.success, .failure]
                .filter {
                    $0 == .success ? !operation.neverSucceeds : !operation.isInfallible
                }
            guard !outcomes.isEmpty else { continue }
            let unaccepted = outcomes.filter { kind in
                (accepting[Trigger(kind: kind, name: operation.effect)] ?? []).isDisjoint(with: active)
            }
            if unaccepted.count == outcomes.count {
                findings.append(.unacceptedOperation(operation.name))
            } else if let kind = unaccepted.first {
                findings.append(.unacceptedOutcome(operation.name, kind))
            }
        }
        // A router's candidates fire exactly when the router runs, so the router alone is reported.
        for (index, edge) in transitions.enumerated()
        where [.success, .failure].contains(edge.trigger.kind) && started.contains(edge.trigger.name)
            && reach.phases.contains(edge.from) && !reach.fired.contains(index)
            && !routed.contains(Dispatch(from: edge.from, trigger: edge.trigger))
        {
            findings.append(.unfiredCompletion(index))
        }
        for (index, route) in routes.enumerated()
        where [.success, .failure].contains(route.trigger.kind) && started.contains(route.trigger.name)
            && reach.phases.contains(route.from)
            && !reach.phases(active: route.trigger.name).contains(route.from)
        {
            findings.append(.unrunCompletionRouter(index))
        }
        return findings
    }
}
