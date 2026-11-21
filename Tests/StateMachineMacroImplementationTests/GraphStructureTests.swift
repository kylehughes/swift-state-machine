import SwiftDiagnostics
import SwiftSyntax
import Testing

@testable import StateMachineMacros

/// The graph's structure: scope eligibility, terminal phases, the checks computed from declared
/// paths, owner selection, events, and direct owned-only edges.
struct GraphStructureTests {
    private static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }
    private static func diagnostics(_ text: String) -> [String]? { DeclarationHygieneTests.diagnostics(text) }

    /// The names of the members the generator emits directly inside the schema.
    private static func generated(_ text: String) throws -> Set<String> {
        let members = try Generator(schema: parse(text)).members()
        return Set(
            members.flatMap { member -> [String] in
                if let named = member.asProtocol(NamedDeclSyntax.self) { return [named.name.text] }
                if let variable = member.as(VariableDeclSyntax.self) {
                    return variable.bindings.compactMap { $0.pattern.as(IdentifierPatternSyntax.self)?.identifier.text }
                }
                return []
            }
        )
    }

    static let base = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            struct Idle {}
            struct Loading {}
            struct Loaded {}
            @Initial case idle(Idle)
            case loading(Loading)
            @Terminal case loaded(Loaded)
            enum Scope {
                @Active(in: [Loading.self])
                case load
                case session
            }
            enum Input { case start, cancel }
            @Operation(scope: Scope.load, requires: [Scope.session])
            enum Fetch { typealias Output = Int }
            @Transition(on: Input.start, starts: [Fetch.self])
            static func begin(_ source: Idle) -> Change<Loading, Effect.Begin> { fatalError() }
            @Transition(on: Input.cancel, invalidates: [Scope.load])
            static func cancel(_ source: Loading) -> Idle { fatalError() }
            @Transition(onSuccess: Fetch.self)
            static func received(_ source: Loading, _ output: Int) -> Loaded { fatalError() }
        }
        """#

    // MARK: Scope eligibility

    /// An omitted `Input`, `Output`, `Failure`, or event `Payload` is exported through the standard library's
    /// module, so the spelling names the standard type where the graph says it is read, inside the namespace,
    /// even where the schema and the namespace declare their own `Swift`, `Void`, and `Never`.
    @Test func theGraphExportsAnOmittedTypeThroughItsModule() throws {
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                enum Swift {}
                struct Void {}
                enum Never {}
                struct Idle {}
                struct Busy {}
                @Initial case idle(Idle)
                case busy(Busy)
                enum Input { case go }
                @Operation(activeIn: [Busy.self])
                enum Load {
                    enum Swift {}
                    struct Void {}
                    enum Never {}
                }
                @Event
                enum Logged {
                    struct Void {}
                }
                @Transition(on: Input.go, starts: [Load.self], emits: [Logged.self])
                static func go(_ source: Idle) -> Change<Busy, Effect.Go> { fatalError() }
                @Transition(onSuccess: Load.self)
                static func loaded(_ source: Busy) -> Idle { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        let load = try #require(schema.operations.first)
        #expect([load.inputType, load.outputType, load.failureType] == ["Swift::Void", "Swift::Void", "Swift::Never"])
        #expect(schema.events.map(\.payloadType) == ["Swift::Void"])
        let graph = Generator(schema: schema).graph()
        #expect(graph.contains(#"input: "Swift::Void", output: "Swift::Void","#))
        #expect(graph.contains(#"failure: "Swift::Never", canFail: false"#))
        #expect(graph.contains(#"payload: "Swift::Void")"#))
        // A declared alias keeps the author's spelling.
        let declared = try Self.parse(
            source.replacingOccurrences(of: "enum Swift {}\n        struct Void {}", with: "typealias Input = Void")
        )
        #expect(declared.operations.first?.inputType == "Void")
    }

    @Test func anOperationRunsInThePhasesOfItsScopesIntersection() throws {
        let schema = try Self.parse(Self.base)
        let fetch = try #require(schema.operations.first)
        #expect(fetch.activeIn == ["loading"] && fetch.privatePhases == nil)
        #expect(schema.scopePhases("load") == ["loading"])
        #expect(schema.scopePhases("session") == ["idle", "loading", "loaded"])
        #expect(schema.restingPhases.map(\.caseName) == ["idle", "loaded"])
        // A required scope narrows the primary one; the primary scope keeps its own phases.
        let narrowed = try Self.parse(
            Self.base
                .replacingOccurrences(of: "@Active(in: [Loading.self])", with: "@Active(in: [Idle.self, Loading.self])")
                .replacingOccurrences(of: "case session", with: "@Active(in: [Loading.self]) case session")
        )
        #expect(narrowed.operations.first?.activeIn == ["loading"])
        #expect(narrowed.scopePhases("load") == ["idle", "loading"])
        // A private scope is active exactly where `activeIn:` lists.
        let privateScope = try Self.parse(
            Self.base.replacingOccurrences(
                of: "@Operation(scope: Scope.load, requires: [Scope.session])",
                with: "@Operation(requires: [Scope.session], activeIn: [Loading.self])"
            )
        )
        #expect(privateScope.operations.first?.privatePhases == ["loading"])
        #expect(privateScope.scopePhases("Fetch.self") == ["loading"])
    }

    @Test func diagnosesScopeEligibility() {
        let failures: [(String, String)] = [
            (
                Self.base.replacingOccurrences(
                    of: "@Operation(scope: Scope.load,",
                    with: "@Operation(scope: Scope.load, activeIn: [Loading.self],"
                ),
                "Operation 'Fetch' runs in the phases of its scope's @Active(in:); remove activeIn:, or remove scope: to give the operation a private scope."
            ),
            (
                Self.base.replacingOccurrences(of: "scope: Scope.load, ", with: ""),
                "Name the phases in which operation 'Fetch' may run with activeIn:, or name the scope it holds with scope:."
            ),
            (
                Self.base.replacingOccurrences(of: "case session", with: "@Active(in: [Idle.self]) case session"),
                "Operation 'Fetch' can never run: no phase is active in its primary scope and every scope it requires; widen a scope's @Active(in:), or require fewer scopes."
            ),
            (
                Self.base
                    .replacingOccurrences(
                        of: "@Active(in: [Loading.self])",
                        with: "@Active(in: [Idle.self, Loading.self])"
                    )
                    .replacingOccurrences(of: "case session", with: "@Active(in: [Idle.self]) case session"),
                "Started operation 'Fetch' and every required scope must be eligible in destination 'Loading'."
            ),
            (
                Self.base.replacingOccurrences(of: "@Active(in: [Loading.self])", with: "@Active(in: [])"),
                "List at least one phase in @Active(in:)."
            ),
            (
                Self.base.replacingOccurrences(of: "@Active(in: [Loading.self])", with: "@Active(in: [Fetch.self])"),
                "'Fetch' is not a phase payload type declared in this schema."
            ),
            (
                Self.base.replacingOccurrences(of: "case load\n", with: "case load, other\n"),
                "@Active(in:) must mark a declaration of one Scope case."
            ),
        ]
        for (source, message) in failures {
            #expect(Self.diagnostics(source) == [message])
        }
    }

    // MARK: Terminal phases

    @Test func diagnosesWhatATerminalPhaseMayNotHave() {
        let failures: [(String, String)] = [
            (
                Self.base.replacingOccurrences(
                    of: "@Transition(onSuccess: Fetch.self)",
                    with:
                        "@Transition(on: Input.cancel)\n    static func reopen(_ source: Loaded) -> Idle { fatalError() }\n    @Transition(onSuccess: Fetch.self)"
                ),
                "Terminal phase 'loaded' cannot have an outgoing transition 'reopen'; remove '@Terminal', or remove the transition."
            ),
            (
                Self.base.replacingOccurrences(
                    of: "@Transition(onSuccess: Fetch.self)",
                    with:
                        "@Route(on: Input.cancel)\n    static func stuck(_ source: Loaded) throws(Problem) -> Never { fatalError() }\n    @Transition(onSuccess: Fetch.self)"
                ),
                "Terminal phase 'loaded' cannot have an outgoing router 'stuck'; remove '@Terminal', or remove the router."
            ),
            (
                Self.base.replacingOccurrences(
                    of: "@Active(in: [Loading.self])",
                    with: "@Active(in: [Loading.self, Loaded.self])"
                ),
                "Operation 'Fetch' cannot be active in terminal phase 'loaded'; remove Loaded.self from the phases where it is active, or remove '@Terminal'."
            ),
            (
                Self.base.replacingOccurrences(of: "@Active(in: [Loading.self])\n", with: ""),
                "Operation 'Fetch' cannot be active in terminal phase 'loaded', because its scope 'load' spans every phase; remove Loaded.self from the phases where it is active, or remove '@Terminal'."
            ),
            (
                Self.base.replacingOccurrences(of: "@Terminal case", with: "@Terminal(true) case"),
                "@Terminal takes no arguments and must mark a declaration of one phase case directly inside the schema."
            ),
        ]
        for (source, message) in failures {
            #expect(Self.diagnostics(source) == [message])
        }
        let single = #"""
            @StateMachine(mode: .shared)
            enum Fixed {
                struct Only {}
                @Initial @Terminal case only(Only)
                enum Input {}
            }
            """#
        #expect(Self.diagnostics(single) == nil)
    }

    // MARK: Paths

    @Test func diagnosesPhasesThatNoPathReachesOrLeaves() throws {
        #expect(
            Self.diagnostics(Self.base.replacingOccurrences(of: "@Terminal case loaded", with: "case loaded")) == [
                "Phase 'loaded' has no outgoing transitions; mark it '@Terminal' or declare a transition from it."
            ]
        )
        // A phase whose only edges lead back to it is a long-lived phase, not a sink.
        let looping = Self.base.replacingOccurrences(of: "@Terminal case loaded", with: "case loaded")
            .replacingOccurrences(
                of: "@Transition(onSuccess: Fetch.self)",
                with:
                    "@Transition(on: Input.cancel)\n    static func stay(_ source: Loaded) -> Loaded { fatalError() }\n    @Transition(onSuccess: Fetch.self)"
            )
        #expect(Self.diagnostics(looping) == nil)
        let archived = Self.base
            .replacingOccurrences(of: "struct Idle {}", with: "struct Idle {}\n    struct Archived {}")
            .replacingOccurrences(
                of: "case loading(Loading)",
                with: "case loading(Loading)\n    case archived(Archived)"
            )
        #expect(
            Self.diagnostics(archived) == [
                "Phase 'archived' is unreachable from the initial phase 'idle'; declare a transition into it, or remove it.",
                "Phase 'archived' has no outgoing transitions; mark it '@Terminal' or declare a transition from it.",
            ]
        )
        let leaving = archived.replacingOccurrences(
            of: "@Transition(onSuccess: Fetch.self)",
            with:
                "@Transition(on: Input.cancel)\n    static func unarchive(_ source: Archived) -> Idle { fatalError() }\n    @Transition(onSuccess: Fetch.self)"
        )
        func restoring(_ phases: String) -> String {
            leaving.replacingOccurrences(
                of: "enum Input",
                with:
                    "@Restoration(only: [\(phases)])\n    static func restore(_ saved: Int) -> Restoration { fatalError() }\n    enum Input"
            )
        }
        // A phase that saved data can restore is an entrance of its own.
        #expect(Self.diagnostics(restoring("Archived.self")) == nil)
        #expect(
            Self.diagnostics(restoring("Idle.self")) == [
                "Phase 'archived' is unreachable from the initial phase 'idle' or a phase @Restoration can restore; declare a transition into it, or remove it."
            ]
        )
    }

    @Test func diagnosesOperationsThatNeverStartOrNeverComplete() {
        let audit =
            "@Operation(activeIn: [Loading.self])\n    enum Audit {}\n    @Transition(onSuccess: Audit.self)\n    static func audited(_ source: Loading) -> Loading { fatalError() }\n"
        let fetched = "    @Transition(onSuccess: Fetch.self)"
        #expect(
            Self.diagnostics(
                Self.base.replacingOccurrences(of: "@Transition(onSuccess: Fetch.self)", with: audit + fetched)
            )
                == [
                    "Operation 'Audit' is never started: no transition lists it in starts:; start it from a transition, or remove it."
                ]
        )
        // Only an edge from a phase that nothing reaches starts it.
        let unreachableStart = Self.base
            .replacingOccurrences(
                of: "struct Idle {}",
                with: "struct Idle {}\n    struct Archived {}"
            )
            .replacingOccurrences(
                of: "case loading(Loading)",
                with: "case loading(Loading)\n    case archived(Archived)"
            )
            .replacingOccurrences(
                of: "@Transition(onSuccess: Fetch.self)",
                with: audit
                    + "    @Transition(on: Input.start, starts: [Audit.self])\n    static func revive(_ source: Archived) -> Change<Loading, Effect.Revive> { fatalError() }\n"
                    + fetched
            )
        #expect(
            Self.diagnostics(unreachableStart) == [
                "Phase 'archived' is unreachable from the initial phase 'idle'; declare a transition into it, or remove it.",
                "Operation 'Audit' is never started: every transition that lists it in starts: leaves a phase the graph never reaches or completes an operation that is never active there; start it from a reachable transition, or remove it.",
            ]
        )
        // A router that always declines accepts no result, so the work can never complete.
        let declining = Self.base.replacingOccurrences(
            of:
                "@Transition(onSuccess: Fetch.self)\n    static func received(_ source: Loading, _ output: Int) -> Loaded { fatalError() }",
            with:
                "@Route(onSuccess: Fetch.self)\n    static func refuse(_ source: Loading, _ output: Int) throws(Problem) -> Never { fatalError() }"
        )
        #expect(
            Self.diagnostics(declining) == [
                "Phase 'loaded' is unreachable from the initial phase 'idle'; declare a transition into it, or remove it.",
                "Operation 'Fetch' can start but never complete: no phase in which it can be active has a completion edge for it; declare one, or give its completion router an edge to choose.",
            ]
        )
    }

    /// A graph whose `Fetch` may be active in `Waiting`, as `edge` reaches it from `Loading`.
    private static func waiting(edge: String, admission: String = ".latest", completion: String? = nil) -> String {
        """
        @StateMachine(mode: .shared)
        enum Flow {
            struct Idle {}
            struct Loading {}
            struct Waiting {}
            @Initial case idle(Idle)
            case loading(Loading)
            case waiting(Waiting)
            enum Scope {
                @Active(in: [Loading.self, Waiting.self])
                case load
            }
            enum Input { case start, park, cancel }
            @Operation(scope: Scope.load, admission: \(admission))
            enum Fetch { typealias Output = Int }
            @Transition(on: Input.start, starts: [Fetch.self])
            static func begin(_ source: Idle) -> Change<Loading, Effect.Begin> { fatalError() }
            @Transition(on: Input.park)
            static func park(_ source: Idle) -> Waiting { fatalError() }
            \(edge)
            @Transition(on: Input.cancel)
            static func cancel(_ source: Waiting) -> Idle { fatalError() }
            @Transition(onSuccess: Fetch.self)
            static func received(_ source: Loading, _ output: Int) -> Idle { fatalError() }
            \(completion ?? "@Transition(onSuccess: Fetch.self)\n    static func parked(_ source: Waiting, _ output: Int) -> Idle { fatalError() }")
        }
        """
    }

    @Test func aCompletionFiresOnlyWhereSomePathKeepsItsWorkActive() {
        let carried = "@Transition(on: Input.park)\n    static func wait(_ source: Loading) -> Waiting { fatalError() }"
        #expect(Self.diagnostics(Self.waiting(edge: carried)) == nil)
        let never =
            "Completion edge 'parked' can never fire: no path from a transition that starts 'Fetch' reaches phase 'waiting' while 'Fetch' stays active; start 'Fetch' on a transition into 'waiting', or remove Waiting.self from the phases where 'Fetch' is active."
        // Reaching the phase without the work keeps nothing active there.
        #expect(Self.diagnostics(Self.waiting(edge: "")) == [never])
        // Invalidating the scope on the way revokes the work.
        let invalidating =
            "@Transition(on: Input.park, invalidates: [Scope.load])\n    static func wait(_ source: Loading) -> Waiting { fatalError() }"
        #expect(Self.diagnostics(Self.waiting(edge: invalidating)) == [never])
        let router =
            "@Route(onSuccess: Fetch.self)\n    static func refuse(_ source: Waiting, _ output: Int) throws(Problem) -> Never { fatalError() }"
        #expect(
            Self.diagnostics(Self.waiting(edge: "", completion: router)) == [
                "Completion router 'refuse' can never run: no path from a transition that starts 'Fetch' reaches phase 'waiting' while 'Fetch' stays active; start 'Fetch' on a transition into 'waiting', or remove Waiting.self from the phases where 'Fetch' is active."
            ]
        )
    }

    @Test func parallelWorkSurvivesTheCompletionOfAnotherMember() {
        // `received` leads to `waiting` through the operation's own completion.
        let own = { (admission: String) in
            Self.waiting(edge: "", admission: admission)
                .replacingOccurrences(
                    of: "static func received(_ source: Loading, _ output: Int) -> Idle",
                    with: "static func received(_ source: Loading, _ output: Int) -> Waiting"
                )
        }
        #expect(Self.diagnostics(own(".parallel(limit: 2)")) == nil)
        #expect(
            Self.diagnostics(own(".latest"))?.first?.hasPrefix("Completion edge 'parked' can never fire") == true
        )
        #expect(
            Self.diagnostics(own(".parallel(limit: 1)"))?.first?.hasPrefix("Completion edge 'parked' can never fire")
                == true
        )
    }

    /// A schema whose `Work` is active in `A`, `B`, and `C`, started on `Start -> A` with `admission`
    /// and, when `keyed`, a `Key`; each completion advances one phase toward `D`.
    private static func counted(admission: String, keyed: Bool = false, completions: Int = 3) -> String {
        let phases = ["A", "B", "C", "D"]
        let edges = (0 ..< completions)
            .map {
                "@Transition(onSuccess: Work.self)\n    static func step\($0)(_ source: \(phases[$0])) -> \(phases[$0 + 1]) { fatalError() }"
            }
            .joined(separator: "\n    ")
        return """
            @StateMachine(mode: .shared)
            enum Flow {
                struct Start {}
                struct A {}
                struct B {}
                struct C {}
                struct D {}
                @Initial case start(Start)
                case a(A)
                case b(B)
                case c(C)
                @Terminal case d(D)
                enum Input { case go }
                @Operation(activeIn: [A.self, B.self, C.self], admission: \(admission))
                enum Work { \(keyed ? "typealias Key = Int" : "") }
                @Transition(on: Input.go, starts: [Work.self])
                static func go(_ source: Start) -> Change<A, Effect.Go> { fatalError() }
                \(edges)
            }
            """
    }

    @Test func boundedParallelWorkRetiresOneExecutionPerCompletion() {
        // At most two executions start, so the third completion never has work to complete.
        #expect(
            Self.diagnostics(Self.counted(admission: ".parallel(limit: 2)")) == [
                "Phase 'd' is unreachable from the initial phase 'start'; declare a transition into it, or remove it.",
                "Completion edge 'step2' can never fire: no path from a transition that starts 'Work' reaches phase 'c' while 'Work' stays active; start 'Work' on a transition into 'c', or remove C.self from the phases where 'Work' is active.",
            ]
        )
        #expect(Self.diagnostics(Self.counted(admission: ".parallel(limit: 3)")) == nil)
        // A limit beyond what the analysis counts is treated as unbounded, which accepts the graph.
        #expect(
            Self.diagnostics(
                Self.counted(admission: ".parallel(limit: 2)").replacingOccurrences(of: "limit: 2", with: "limit: 33")
            ) == nil
        )
        // A keyed operation holds independent work for each key, so any number of executions may remain.
        #expect(Self.diagnostics(Self.counted(admission: ".latest", keyed: true)) == nil)
        #expect(Self.diagnostics(Self.counted(admission: ".rejectWhenActive", keyed: true)) == nil)
    }

    @Test func keyedWorkSurvivesTheCompletionOfAnotherKey() {
        // Keys 1 and 2 start in `A`; completing 1 enters `B`, and completing 2 enters `C`.
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                struct A {}
                struct B {}
                struct C {}
                @Initial case a(A)
                case b(B)
                @Terminal case c(C)
                enum Input { case fetch(Int) }
                @Operation(activeIn: [A.self, B.self])
                enum Fetch { typealias Key = Int }
                @Transition(on: Input.fetch, starts: [Fetch.self])
                static func fetch(_ source: A, _ key: Int) -> Change<A, Effect.Fetch> { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func first(_ source: A) -> B { fatalError() }
                @Transition(onSuccess: Fetch.self)
                static func second(_ source: B) -> C { fatalError() }
            }
            """#
        #expect(Self.diagnostics(source) == nil)
        #expect(
            Self.diagnostics(
                source.replacingOccurrences(of: "enum Fetch { typealias Key = Int }", with: "enum Fetch {}")
            )?
            .first?
            .hasPrefix("Phase 'c' is unreachable") == true
        )
    }

    /// A graph whose terminal phase needs work that no path into its source holds.
    ///
    /// `a` and `b` each enter `X` with one operation's work, `A`'s success moves to `Y`, and `B`'s
    /// success in `Y` would enter `Z`: every path into `Y` has consumed `A`, and none holds `B`.
    static let exclusive = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            struct Start {}
            struct X {}
            struct Y {}
            struct Z {}
            @Initial case start(Start)
            case x(X)
            case y(Y)
            @Terminal case z(Z)
            enum Input { case a, b }
            @Operation(activeIn: [X.self])
            enum A {}
            @Operation(activeIn: [X.self, Y.self])
            enum B {}
            @Transition(on: Input.a, starts: [A.self])
            static func a(_ source: Start) -> Change<X, Effect.A> { fatalError() }
            @Transition(on: Input.b, starts: [B.self])
            static func b(_ source: Start) -> Change<X, Effect.B> { fatalError() }
            @Transition(onSuccess: A.self)
            static func advanced(_ source: X) -> Y { fatalError() }
            @Transition(onSuccess: B.self)
            static func returned(_ source: X) -> Start { fatalError() }
            @Transition(onSuccess: B.self)
            static func finished(_ source: Y) -> Z { fatalError() }
        }
        """#

    @Test func aPathCarriesOnlyTheWorkItStarted() throws {
        #expect(
            Self.diagnostics(Self.exclusive) == [
                "Phase 'z' is unreachable from the initial phase 'start'; declare a transition into it, or remove it.",
                "Completion edge 'finished' can never fire: no path from a transition that starts 'B' reaches phase 'y' while 'B' stays active; start 'B' on a transition into 'y', or remove Y.self from the phases where 'B' is active.",
            ]
        )
        // One edge that may start both operations makes the path real.
        let both = Self.exclusive.replacingOccurrences(
            of: "@Transition(on: Input.a, starts: [A.self])\n    static func a(_ source: Start) -> Change<X, Effect.A>",
            with:
                "@Transition(on: Input.a, starts: [A.self, B.self])\n    static func a(_ source: Start) -> Change<X, Effect.A>"
        )
        #expect(Self.diagnostics(both) == nil)
        // Checked per operation, `B`'s work in `X` is carried along `A`'s completion, which only accepts
        // more graphs.
        let exclusive = try Self.parse(both).starting(["a"], on: "a")
        #expect(exclusive.jointReach()?.phases.contains("z") == false)
        #expect(exclusive.operationReach().phases.contains("z"))
        // A graph whose configurations take more work than the budget is checked per operation.
        #expect(exclusive.jointReach(budget: 4) == nil)
    }

    /// The operation-heavy stress graph: a ring of `phases` on one input, and `operations` operations,
    /// each started in the first of `span` consecutive phases where its scope is active and completed
    /// in each of them, as `Scripts/check-macro-fixtures.py --variant operation-heavy` declares it.
    private static func operationHeavy(phases: Int = 128, operations: Int = 32, span: Int = 8) -> String {
        let stride = max(1, phases / operations)
        let active = (0 ..< operations).map { op in (0 ..< span).map { (op * stride + $0) % phases } }
        var lines = ["@StateMachine(mode: .shared)", "enum Flow {", "    enum Problem: Error { case failed }"]
        lines.append("    enum Scope {")
        for (op, phases) in active.enumerated() {
            lines.append(
                "        @Active(in: [\(phases.map { "Phase\($0).self" }.joined(separator: ", "))]) case work\(op)"
            )
        }
        lines.append("    }")
        for phase in 0 ..< phases { lines.append("    struct Phase\(phase) {}") }
        for phase in 0 ..< phases {
            lines.append("    \(phase == 0 ? "@Initial " : "")case phase\(phase)(Phase\(phase))")
        }
        lines.append("    enum Input { case next, start }")
        for op in 0 ..< operations {
            lines.append("    @Operation(scope: Scope.work\(op))")
            lines.append("    enum Op\(op) { typealias Failure = \(op % 2 == 0 ? "Problem" : "Never") }")
        }
        for phase in 0 ..< phases {
            lines.append("    @Transition(on: Input.next)")
            lines.append(
                "    static func next\(phase)(_ source: Phase\(phase)) -> Phase\((phase + 1) % phases) { fatalError() }"
            )
        }
        for (op, phases) in active.enumerated() {
            lines.append("    @Transition(on: Input.start, starts: [Op\(op).self])")
            lines.append(
                "    static func start\(op)(_ source: Phase\(phases[0])) -> Change<Phase\(phases[0]), Effect.Start\(op)> { fatalError() }"
            )
            for phase in phases {
                lines.append("    @Transition(onSuccess: Op\(op).self)")
                lines.append(
                    "    static func done\(op)in\(phase)(_ source: Phase\(phase)) -> Phase\(phase) { fatalError() }"
                )
                guard op % 2 == 0 else { continue }
                lines.append("    @Transition(onFailure: Op\(op).self)")
                lines.append(
                    "    static func fail\(op)in\(phase)(_ source: Phase\(phase), _ reason: Problem) -> Phase\(phase) { fatalError() }"
                )
            }
        }
        lines.append("}")
        return lines.joined(separator: "\n")
    }

    @Test func theOperationHeavyStressGraphIsExploredJointly() throws {
        let schema = try Self.parse(Self.operationHeavy())
        let joint = try #require(schema.jointReach())
        #expect(joint.phases.count == 128)
        #expect(joint.fired.count == schema.transitions.count)
    }

    @Test func anOutcomeIsAcceptedOnlyWhereAPathHoldsItsWork() {
        // `A` may be active in `Y` only along `B`'s completion, which no path holding `A` takes.
        let source = #"""
            @StateMachine(mode: .shared)
            enum Flow {
                enum Problem: Error { case failed }
                struct Start {}
                struct X {}
                struct Y {}
                @Initial case start(Start)
                case x(X)
                case y(Y)
                enum Input { case a, b }
                @Operation(activeIn: [X.self, Y.self])
                enum A { typealias Failure = Problem }
                @Operation(activeIn: [X.self])
                enum B {}
                @Transition(on: Input.a, starts: [A.self])
                static func a(_ source: Start) -> Change<X, Effect.A> { fatalError() }
                @Transition(on: Input.b, starts: [B.self])
                static func b(_ source: Start) -> Change<X, Effect.B> { fatalError() }
                @Transition(onSuccess: B.self)
                static func moved(_ source: X) -> Y { fatalError() }
                @Transition(onSuccess: A.self)
                static func done(_ source: X) -> Start { fatalError() }
                @Route(onFailure: A.self)
                static func refuse(_ source: X, _ failure: Problem) throws(Problem) -> Never { fatalError() }
                @Transition(onSuccess: A.self)
                static func doneLater(_ source: Y) -> Start { fatalError() }
                @Transition(onFailure: A.self)
                static func failedLater(_ source: Y, _ failure: Problem) -> Start { fatalError() }
                @Transition(on: Input.a)
                static func leave(_ source: Y) -> Start { fatalError() }
            }
            """#
        #expect(
            Self.diagnostics(source) == [
                "Operation 'A' can start but its failure is never accepted: no phase in which it can be active has an onFailure: edge for it, so every failure stays pending until it is discarded; declare one, or give its failure router an edge to choose.",
                "Completion edge 'doneLater' can never fire: no path from a transition that starts 'A' reaches phase 'y' while 'A' stays active; start 'A' on a transition into 'y', or remove Y.self from the phases where 'A' is active.",
                "Completion edge 'failedLater' can never fire: no path from a transition that starts 'A' reaches phase 'y' while 'A' stays active; start 'A' on a transition into 'y', or remove Y.self from the phases where 'A' is active.",
            ]
        )
    }

    @Test func anOwnedOnlyGraphChecksPhasePathsWithoutCountingWork() {
        // `Owned` completion methods consume their source, so a caller may take both in turn.
        let twice = Self.counted(admission: ".latest", completions: 2)
            .replacingOccurrences(of: "@Terminal case d(D)", with: "case d(D)")
            .replacingOccurrences(of: "case c(C)", with: "@Terminal case c(C)")
            .replacingOccurrences(of: "activeIn: [A.self, B.self, C.self]", with: "activeIn: [A.self, B.self]")
        let owned = twice.replacingOccurrences(of: "mode: .shared", with: "mode: .shared, owners: [.owned]")
        #expect(Self.diagnostics(owned)?.contains { $0.hasPrefix("Phase 'd' is unreachable") } == true)
        #expect(
            Self.diagnostics(
                owned.replacingOccurrences(of: "struct D {}\n", with: "")
                    .replacingOccurrences(
                        of: "    case d(D)\n",
                        with: ""
                    )
            ) == nil
        )
        // A hosted owner retires its one execution on the first completion.
        let hosted = twice.replacingOccurrences(of: "struct D {}\n", with: "")
            .replacingOccurrences(of: "    case d(D)\n", with: "")
        #expect(Self.diagnostics(hosted)?.first?.hasPrefix("Phase 'c' is unreachable") == true)
        #expect(
            Self.diagnostics(
                hosted.replacingOccurrences(of: "mode: .shared", with: "mode: .shared, owners: [.owned, .local]")
            )?
            .first?
            .hasPrefix("Phase 'c' is unreachable") == true
        )
        // Phase paths and routing are still checked.
        let declining = owned.replacingOccurrences(of: "struct D {}\n", with: "")
            .replacingOccurrences(of: "    case d(D)\n", with: "")
            .replacingOccurrences(
                of: "@Transition(onSuccess: Work.self)\n    static func step1(_ source: B) -> C { fatalError() }",
                with:
                    "@Route(onSuccess: Work.self)\n    static func step1(_ source: B) throws(Problem) -> Never { fatalError() }"
            )
        #expect(
            Self.diagnostics(declining) == [
                "Phase 'b' has no outgoing transitions; mark it '@Terminal' or declare a transition from it.",
                "Phase 'c' is unreachable from the initial phase 'start'; declare a transition into it, or remove it.",
            ]
        )
    }

    @Test func eachOutcomeOfAFallibleOperationNeedsAnAcceptingEdge() throws {
        let failing = Self.base
            .replacingOccurrences(
                of: "enum Fetch { typealias Output = Int }",
                with: "enum Fetch { typealias Output = Int; typealias Failure = Problem }"
            )
        let refusing =
            "@Route(onFailure: Fetch.self)\n    static func refuse(_ source: Loading, _ failure: Problem) throws(Problem) -> Never { fatalError() }\n    @Transition(onSuccess: Fetch.self)"
        #expect(
            Self.diagnostics(failing.replacingOccurrences(of: "@Transition(onSuccess: Fetch.self)", with: refusing))
                == [
                    "Operation 'Fetch' can start but its failure is never accepted: no phase in which it can be active has an onFailure: edge for it, so every failure stays pending until it is discarded; declare one, or give its failure router an edge to choose."
                ]
        )
        let accepting =
            "@Transition(onFailure: Fetch.self)\n    static func failed(_ source: Loading, _ failure: Problem) -> Idle { fatalError() }\n    @Transition(onSuccess: Fetch.self)"
        #expect(
            Self.diagnostics(failing.replacingOccurrences(of: "@Transition(onSuccess: Fetch.self)", with: accepting))
                == nil
        )
        // Every phase in which the work can be active still declares an edge or router for each outcome
        // whose type the macro confirms has values.
        let confirmed = failing.replacingOccurrences(
            of: "typealias Failure = Problem",
            with: "enum Lost: Error {}; typealias Failure = Lost"
        )
        #expect(
            Self.diagnostics(confirmed) == [
                "Operation 'Fetch' needs a failure edge or router in active phase case 'loading'."
            ]
        )
        // One a namespace extension could change says by its edges whether the operation fails, and
        // the expansion checks the failure it reads.
        let unconfirmed = try Self.parse(failing)
        #expect(unconfirmed.operations.first?.isInfallible == true)
        #expect(
            TypeSpellingMatrixTests.checkMessage(unconfirmed, at: "Fetch.Failure")?
                .hasPrefix("Operation 'Fetch' has no onFailure: edge or router") == true
        )
    }

    // MARK: Owners

    @Test func ownersDefaultToEverySurfaceTheModeSupports() throws {
        #expect(
            try Self.parse(Self.base).owners == [.owned, .local, .shared, .actorHost, .mainActorHost, .isolatedHost]
        )
        let isolated = Self.base.replacingOccurrences(of: "mode: .shared", with: "mode: .isolated")
        #expect(try Self.parse(isolated).owners == [.owned, .local, .mainActorHost, .isolatedHost])
        let selected = Self.base.replacingOccurrences(
            of: "mode: .shared",
            with: "mode: .shared, owners: [.mainActorHost, .local]"
        )
        #expect(try Self.parse(selected).owners == [.local, .mainActorHost])
        let qualified = selected.replacingOccurrences(of: "@StateMachine(", with: "@StateMachine.StateMachine(")
        #expect(try Self.parse(qualified).owners == [.local, .mainActorHost])
    }

    @Test func diagnosesOwnerSelections() {
        func owners(_ list: String, mode: String = ".shared") -> String {
            Self.base.replacingOccurrences(of: "mode: .shared", with: "mode: \(mode), owners: \(list)")
        }
        let failures: [(String, String)] = [
            (owners("[]"), "List at least one owner, or omit owners: to generate every owner .shared supports."),
            (owners("[.local, .local]"), "List each owner once; '.local' appears twice."),
            (
                owners("[.remote]"),
                "'.remote' is not an owner; use .owned, .local, .shared, .actorHost, .mainActorHost, or .isolatedHost."
            ),
            (owners(".local"), "Use an array literal of owners such as [.local, .mainActorHost]."),
            (
                owners("[.local, .shared]", mode: ".isolated"),
                "Owner '.shared' is unavailable in .isolated, which supports .owned, .local, .mainActorHost, .isolatedHost."
            ),
            (
                owners("[.owned]")
                    .replacingOccurrences(
                        of: "enum Input",
                        with:
                            "@Restoration\n    static func restore(_ saved: Int) -> Restoration { fatalError() }\n    enum Input"
                    ),
                "@Restoration needs an owner that a restoring initializer creates; list .local or a managed host in owners:."
            ),
        ]
        for (source, message) in failures {
            #expect(Self.diagnostics(source) == [message])
        }
        let owned = #"""
            @StateMachine(mode: .ownedOnly, owners: [.local])
            enum Unique {
                struct Only: ~Copyable {}
                @Initial @Terminal case only(Only)
            }
            """#
        #expect(Self.diagnostics(owned) == ["Owner '.local' is unavailable in .ownedOnly, which supports .owned."])
    }

    @Test func aSelectionGeneratesOnlyWhatItsOwnersUse() throws {
        func selecting(_ owners: String) throws -> Set<String> {
            try Self.generated(
                Self.base.replacingOccurrences(of: "mode: .shared", with: "mode: .shared, owners: \(owners)")
            )
        }
        let all = try Self.generated(Self.base)
        #expect(
            all.isSuperset(of: [
                "Owned", "Local", "Shared", "ActorHost", "MainActorHost", "IsolatedHost", "Drivers", "MainActorDrivers",
                "FetchWork", "Command", "DeliveryResult", "ShutdownResult", "graph",
            ])
        )
        let local = try selecting("[.local]")
        #expect(local.isSuperset(of: ["Local", "Command", "CommandBatch", "FetchWork", "DeliveryResult", "Snapshot"]))
        #expect(local.isDisjoint(with: ["Owned", "Shared", "ActorHost", "MainActorHost", "Drivers", "ShutdownResult"]))
        let managed = try selecting("[.actorHost]")
        #expect(managed.isSuperset(of: ["ActorHost", "Drivers", "ShutdownResult", "PendingCompletion", "Completion"]))
        #expect(
            managed.isDisjoint(with: [
                "Local", "Shared", "Command", "FetchWork", "DeliveryResult", "ExecutionHandle", "Owned",
            ])
        )
        let confined = try selecting("[.isolatedHost]")
        #expect(
            confined.isSuperset(of: ["IsolatedHost", "ShutdownResult", "PendingCompletion", "IsolatedSubscription"])
        )
        #expect(
            confined.isDisjoint(with: [
                "Local", "Shared", "ActorHost", "MainActorHost", "Drivers", "Owned", "Subscription",
            ])
        )
        let owned = try selecting("[.owned]")
        #expect(owned.isSuperset(of: ["Owned", "owned", "Effect", "graph"]))
        #expect(owned.isDisjoint(with: ["Snapshot", "Observed", "Prepared", "Local", "Restoration", "prepare"]))
    }

    // MARK: Events

    static let tracked = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            struct Idle {}
            struct Noted {}
            @Initial case idle(Idle)
            @Terminal case noted(Noted)
            enum Input { case note(String), ping }
            @Event
            enum Tracked { typealias Payload = String }
            @StateMachine.Event
            enum Pinged {}
            @Transition(on: Input.note, emits: [Tracked.self])
            static func note(_ source: Idle, _ text: String) -> Change<Noted, Effect.Note> { fatalError() }
            @Transition(on: Input.ping, emits: [Pinged.self, Tracked.self])
            static func ping(_ source: Idle) -> Change<Idle, Effect.Ping> { fatalError() }
        }
        """#

    @Test func eventsAreInertEffectsThatEdgesEmit() throws {
        let schema = try Self.parse(Self.tracked)
        #expect(schema.events.map(\.name) == ["Tracked", "Pinged"])
        #expect(schema.events.map(\.effect) == ["tracked", "pinged"])
        #expect(schema.events.map(\.payload) == ["Tracked.Payload", "Swift::Void"])
        #expect(schema.events.map(\.takesPayload) == [true, false])
        #expect(schema.events.map(\.handler) == ["onTracked", "onPinged"])
        #expect(schema.transitions.map(\.emits) == [["tracked"], ["pinged", "tracked"]])
        #expect(schema.transitions.map(\.starts) == [[], []])
        #expect(schema.transitions.map { schema.effectType($0) } == ["Effect.Note", "Effect.Ping"])
    }

    @Test func diagnosesEventDeclarationsAndReferences() {
        let failures: [(String, String)] = [
            (
                Self.tracked.replacingOccurrences(of: "emits: [Tracked.self])\n", with: "starts: [Tracked.self])\n"),
                "'Tracked' is an @Event; list it in emits:."
            ),
            (
                Self.tracked.replacingOccurrences(of: "emits: [Tracked.self])\n", with: "emits: [Missing.self])\n"),
                "'Missing' is not a declared @Event namespace."
            ),
            (
                Self.tracked.replacingOccurrences(of: "@Event\n", with: "@Event @Operation(activeIn: [Idle.self])\n"),
                "A namespace cannot be both an @Operation and an @Event."
            ),
            (
                Self.tracked.replacingOccurrences(of: "typealias Payload = String", with: "typealias Value = String"),
                "An event declares only a nongeneric Payload typealias, at most once; an omitted Payload is Void."
            ),
            (
                Self.tracked.replacingOccurrences(of: "enum Pinged {}", with: "enum TRACKED {}"),
                "Event 'TRACKED' generates the same effect case 'tracked' as another operation or event; rename one."
            ),
            (
                Self.tracked.replacingOccurrences(of: "-> Change<Noted, Effect.Note>", with: "-> Noted"),
                "This transition emits Tracked; return Change<Noted, Effect.Note>."
            ),
            (
                Self.tracked.replacingOccurrences(of: "Effect.Ping", with: "Effect"),
                "This transition emits Pinged, Tracked; name its effects Effect.Ping."
            ),
        ]
        for (source, message) in failures {
            #expect(Self.diagnostics(source) == [message])
        }
    }

    // MARK: Direct owned-only edges

    @Test func anOwnedOnlyEdgeNeedsNoInput() throws {
        let source = #"""
            @StateMachine(mode: .ownedOnly)
            enum Ticket {
                struct Valid: ~Copyable {}
                struct Used: ~Copyable {}
                @Initial case valid(Valid)
                @Terminal case used(Used)
                @Transition
                static func scan(_ source: consuming Valid) -> Used { fatalError() }
            }
            """#
        let schema = try Self.parse(source)
        #expect(schema.inputs.isEmpty)
        #expect(schema.transitions.map(\.trigger) == [Schema.Trigger(kind: .direct, name: "scan")])
        #expect(schema.transitions.first?.payloadType == nil)
        // Every other mode routes inputs, so its edges name one and the schema declares the enum.
        let shared = source.replacingOccurrences(of: "mode: .ownedOnly", with: "mode: .shared")
            .replacingOccurrences(of: ": ~Copyable", with: "")
            .replacingOccurrences(of: "consuming ", with: "")
        #expect(
            Self.diagnostics(shared) == [
                "Declare a closed Input enum directly inside the schema; an empty enum is allowed."
            ]
        )
        #expect(
            Self.diagnostics(shared.replacingOccurrences(of: "@Transition\n", with: "enum Input {}\n    @Transition\n"))
                == [
                    "Name exactly one trigger: on: Input.<case>, onSuccess: <Operation>.self, or onFailure: <Operation>.self."
                ]
        )
    }
}

extension Schema {
    /// This schema with the `starts:` of the edges named `edge` replaced, past the parser's graph checks.
    fileprivate func starting(_ starts: [String], on edge: String) -> Schema {
        let edges = transitions.map { old in
            guard old.name == edge else { return old }
            return Transition(
                name: old.name,
                from: old.from,
                to: old.to,
                trigger: old.trigger,
                invalidates: old.invalidates,
                starts: starts,
                cancels: old.cancels,
                emits: old.emits,
                payloadType: old.payloadType,
                sourceType: old.sourceType,
                returnType: old.returnType,
                failureType: old.failureType,
                shape: old.shape,
                effectNamespace: old.effectNamespace,
                declaration: old.declaration,
                sources: old.sources,
                requestType: old.requestType
            )
        }
        return Schema(
            name: name,
            access: access,
            mode: mode,
            initial: initial,
            initialDefault: initialDefault,
            scopes: scopes,
            scopeActiveIn: scopeActiveIn,
            phases: phases,
            inputs: inputs,
            operations: operations,
            events: events,
            transitions: edges,
            routes: routes,
            restoration: restoration,
            valueConformances: valueConformances,
            typeNames: typeNames,
            owners: owners
        )
    }
}
