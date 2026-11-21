import Testing

@testable import StateMachineMacros

/// The per-operation analysis that checks a graph whose configurations are too many to explore jointly.
struct FallbackAnalysisTests {
    private static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }

    /// One phase, `count` operations an input edge starts, and a success self-loop for each.
    static func onePhase(_ count: Int) -> String {
        let operations = (0 ..< count).map { "@Operation(activeIn: [Idle.self]) enum O\($0) {}" }
        let started = (0 ..< count).map { "O\($0).self" }.joined(separator: ", ")
        let completions = (0 ..< count)
            .map {
                "@Transition(onSuccess: O\($0).self)\n    static func done\($0)(_ source: Idle) -> Idle { fatalError() }"
            }
        return """
            @StateMachine(mode: .shared)
            enum Flow {
                struct Idle {}
                @Initial case idle(Idle)
                enum Input { case go }
                \(operations.joined(separator: "\n    "))
                @Transition(on: Input.go, starts: [\(started)])
                static func go(_ source: Idle) -> Change<Idle, Effect.Go> { fatalError() }
                \(completions.joined(separator: "\n    "))
            }
            """
    }

    /// Edges that share a source, a destination, and the scopes they invalidate carry the other
    /// operations' work as one, so one phase with many operations and an edge for each takes work linear
    /// in the operations, where carrying every count along every edge takes work quadratic in them.
    @Test func carryingWorkIsLinearInTheOperations() throws {
        func steps(_ count: Int) throws -> (current: Int, reference: Int) {
            let schema = try Self.parse(Self.onePhase(count))
            var current = 0
            var reference = 0
            let reach = schema.operationReach(steps: &current)
            let expected = schema.referenceOperationReach(steps: &reference)
            #expect(reach.phases == expected.phases)
            #expect(reach.active == expected.active)
            #expect(reach.fired == expected.fired)
            return (current, reference)
        }
        let small = try steps(100)
        let large = try steps(800)
        // Eight times the operations: at most about eight times the work, where the reference does about
        // sixty-four times its own.
        #expect(large.current <= small.current * 9, "\(small.current) then \(large.current) steps")
        #expect(large.reference >= small.reference * 50, "\(small.reference) then \(large.reference) steps")
    }

    /// A small deterministic generator, so a failing graph can be found again from its seed.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    /// Phases, scopes, and operations of every admission, keyed and not, whose edges each test replaces.
    static let declarations = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            struct P0 {}
            struct P1 {}
            struct P2 {}
            struct P3 {}
            struct P4 {}
            @Initial case p0(P0)
            case p1(P1)
            case p2(P2)
            case p3(P3)
            @Terminal case p4(P4)
            enum Scope {
                @Active(in: [P1.self, P2.self, P3.self])
                case a
                case b
            }
            enum Input { case go }
            @Operation(activeIn: [P1.self, P2.self])
            enum Latest {}
            @Operation(scope: Scope.a, admission: .rejectWhenActive)
            enum Exclusive {}
            @Operation(scope: Scope.b, requires: [Scope.a], admission: .parallel(limit: 3))
            enum Parallel {}
            @Operation(activeIn: [P2.self, P3.self], admission: .parallel(limit: 40))
            enum Wide {}
            @Operation(scope: Scope.a)
            enum Keyed { typealias Key = Int }
            @Transition(on: Input.go, starts: [Latest.self, Exclusive.self, Parallel.self, Keyed.self])
            static func go(_ source: P0) -> Change<P1, Effect.Go> { fatalError() }
            @Transition(on: Input.go, starts: [Wide.self])
            static func on1(_ source: P1) -> Change<P2, Effect.On1> { fatalError() }
            @Transition(onSuccess: Latest.self)
            static func latestIn1(_ source: P1) -> P4 { fatalError() }
            @Transition(onSuccess: Latest.self)
            static func latestIn2(_ source: P2) -> P4 { fatalError() }
            @Transition(onSuccess: Exclusive.self)
            static func exclusiveIn1(_ source: P1) -> P4 { fatalError() }
            @Transition(onSuccess: Exclusive.self)
            static func exclusiveIn2(_ source: P2) -> P4 { fatalError() }
            @Transition(onSuccess: Exclusive.self)
            static func exclusiveIn3(_ source: P3) -> P4 { fatalError() }
            @Transition(onSuccess: Parallel.self)
            static func parallelIn1(_ source: P1) -> P4 { fatalError() }
            @Transition(onSuccess: Parallel.self)
            static func parallelIn2(_ source: P2) -> P4 { fatalError() }
            @Transition(onSuccess: Parallel.self)
            static func parallelIn3(_ source: P3) -> P4 { fatalError() }
            @Transition(onSuccess: Wide.self)
            static func wideIn2(_ source: P2) -> P4 { fatalError() }
            @Transition(onSuccess: Wide.self)
            static func wideIn3(_ source: P3) -> P4 { fatalError() }
            @Transition(onSuccess: Keyed.self, invalidates: [Scope.a])
            static func keyedIn1(_ source: P1) -> P2 { fatalError() }
            @Transition(onSuccess: Keyed.self)
            static func keyedIn2(_ source: P2) -> P4 { fatalError() }
            @Transition(onSuccess: Keyed.self)
            static func keyedIn3(_ source: P3) -> P4 { fatalError() }
            @Transition(on: Input.go)
            static func on2(_ source: P2) -> P3 { fatalError() }
            @Transition(on: Input.go)
            static func on3(_ source: P3) -> P4 { fatalError() }
        }
        """#

    /// Random edges reach exactly what carrying every count along every edge reaches.
    ///
    /// The edges join the declared phases and operations: input edges and completions of either outcome,
    /// each starting and invalidating a random selection, several often sharing a source and destination.
    @Test func groupedCarryingReachesWhatEdgeByEdgeCarryingReaches() throws {
        var schema = try Self.parse(Self.declarations)
        let phases = schema.phases.map(\.caseName)
        let effects = schema.operations.map(\.effect)
        let scopes = Array(Set(schema.operations.flatMap { [$0.scopeKey] + $0.requires })).sorted()
        var random = Seeded(state: 2026)
        for _ in 0 ..< 400 {
            let count = Int.random(in: 1 ... 24, using: &random)
            schema.transitions = (0 ..< count)
                .map { index in
                    let trigger: Schema.Trigger
                    switch Int.random(in: 0 ..< 3, using: &random) {
                    case 0: trigger = Schema.Trigger(kind: .input, name: "go")
                    case 1: trigger = Schema.Trigger(kind: .success, name: effects.randomElement(using: &random)!)
                    default: trigger = Schema.Trigger(kind: .failure, name: effects.randomElement(using: &random)!)
                    }
                    // Few sources make edges that share a source and a destination common.
                    let from = phases[Int.random(in: 0 ..< 3, using: &random)]
                    let to = phases[Int.random(in: 0 ..< phases.count, using: &random)]
                    return Schema.Transition(
                        name: "e\(index)",
                        from: from,
                        to: to,
                        trigger: trigger,
                        invalidates: scopes.filter { _ in Int.random(in: 0 ..< 4, using: &random) == 0 },
                        starts: effects.filter { _ in Int.random(in: 0 ..< 3, using: &random) == 0 },
                        cancels: [],
                        emits: [],
                        sourceType: nil,
                        returnType: "",
                        shape: .destination,
                        effectNamespace: nil,
                        declaration: index,
                        sources: [from],
                        requestType: nil
                    )
                }
            var steps = 0
            let reach = schema.operationReach()
            let expected = schema.referenceOperationReach(steps: &steps)
            #expect(reach.phases == expected.phases)
            #expect(reach.active == expected.active)
            #expect(reach.fired == expected.fired)
        }
    }
}

extension Schema {
    /// The fallback analysis as it carried every count along every edge, kept as the reference the
    /// grouped analysis must agree with; `steps` counts the facts it visits and the pairs it tries.
    func referenceOperationReach(steps: inout Int) -> GraphReach {
        var reach = GraphReach()
        let outgoing = Dictionary(grouping: transitions.indices, by: { transitions[$0].from })
        let limits = Dictionary(uniqueKeysWithValues: operations.map { ($0.effect, outstandingLimit($0)) })
        // What `carried` asks of each operation and edge, as sets, so each question takes constant time.
        let activeIn = Dictionary(uniqueKeysWithValues: operations.map { ($0.effect, Set($0.activeIn)) })
        let held = Dictionary(uniqueKeysWithValues: operations.map { ($0.effect, [$0.scopeKey] + $0.requires) })
        let starts = transitions.map { Set($0.starts) }
        let invalidates = transitions.map { Set($0.invalidates) }
        enum Fact {
            case phase(String)
            case active(String, String, Outstanding)
            case edge(Int)
        }
        var work: [Fact] = ([initial] + restorationEntrances).map { .phase($0) }
        func isCompletion(_ edge: Transition, of effect: String) -> Bool {
            (edge.trigger.kind == .success || edge.trigger.kind == .failure) && edge.trigger.name == effect
        }
        /// The counts an operation may have in the edge's destination, given `count` in its source,
        /// where `nil` is none outstanding.
        func carried(_ index: Int, _ effect: String, _ count: Outstanding?) -> [Outstanding] {
            let edge = transitions[index]
            guard activeIn[effect]!.contains(edge.to) else { return [] }
            var remaining = count
            if isCompletion(edge, of: effect) {
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
            for result in carried(index, effect, count) { work.append(.active(effect, transitions[index].to, result)) }
        }
        while let fact = work.popLast() {
            steps += 1
            switch fact {
            case .phase(let phase):
                guard reach.phases.insert(phase).inserted else { continue }
                for index in outgoing[phase] ?? [] {
                    let kind = transitions[index].trigger.kind
                    if kind == .input || kind == .direct { work.append(.edge(index)) }
                }
            case .active(let effect, let phase, let count):
                guard reach.active[effect, default: [:]][phase, default: []].insert(count).inserted else { continue }
                for index in outgoing[phase] ?? [] {
                    steps += 1
                    if isCompletion(transitions[index], of: effect) { work.append(.edge(index)) }
                    // An edge that fires later carries every count its source holds by then.
                    if reach.fired.contains(index) { propagate(index, effect, count) }
                }
            case .edge(let index):
                guard reach.fired.insert(index).inserted else { continue }
                let edge = transitions[index]
                work.append(.phase(edge.to))
                for effect in edge.starts { propagate(index, effect, nil) }
                for (effect, phases) in reach.active {
                    steps += 1
                    for count in phases[edge.from] ?? [] { propagate(index, effect, count) }
                }
            }
        }
        return reach
    }
}
