import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

/// The expansion's work grows with the declarations.
///
/// Each family is measured at two sizes sixteen
/// times apart, where linear work takes about sixteen times as long and work quadratic in the varied
/// size 256 times; the bound, 64, leaves room for a loaded machine between those.
struct WorkBoundTests {
    private static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }

    /// The shortest of `runs` runs of `body`, in seconds.
    private static func seconds(runs: Int = 3, _ body: () throws -> Void) rethrows -> Double {
        let clock = ContinuousClock()
        var best = Double.infinity
        for _ in 0 ..< runs {
            let elapsed = try clock.measure(body)
            best = min(best, Double(elapsed.components.attoseconds) / 1e18 + Double(elapsed.components.seconds))
        }
        return best
    }

    /// Requires the larger family to take less than 64 times as long as the smaller, or under 50 ms,
    /// timing the two in turn and keeping each one's shortest run, so both share whatever else the
    /// machine runs meanwhile.
    private static func expectLinear(
        runs: Int = 3,
        _ comment: String,
        small: () throws -> Void,
        large: () throws -> Void
    ) rethrows {
        var first = Double.infinity
        var second = Double.infinity
        for _ in 0 ..< runs {
            first = min(first, try seconds(runs: 1, small))
            second = min(second, try seconds(runs: 1, large))
        }
        #expect(second < 0.05 || second < 64 * first, "\(comment): \(first) s, then \(second) s")
    }

    /// One phase with `count` input triggers, each with a router and two self-loop candidates: every
    /// function finds its trigger's input, and a completion its operation, by name.
    @Test func routedInputsAreFoundByName() throws {
        func schema(_ count: Int) -> String {
            let cases = (0 ..< count).map { "i\($0)" }.joined(separator: ", ")
            let functions = (0 ..< count)
                .map { index in
                    """
                    @Transition(on: Input.i\(index))
                    static func a\(index)(_ source: Idle) -> Idle { fatalError() }
                    @Transition(on: Input.i\(index))
                    static func b\(index)(_ source: Idle) -> Idle { fatalError() }
                    @Route(on: Input.i\(index))
                    static func r\(index)(_ source: Idle) -> Route.R\(index) { fatalError() }
                    """
                }
            return """
                @StateMachine(mode: .shared)
                enum Flow {
                    struct Idle {}
                    @Initial case idle(Idle)
                    enum Input { case \(cases) }
                \(functions.joined(separator: "\n"))
                }
                """
        }
        let small = schema(250)
        let large = schema(4_000)
        #expect(try Self.parse(small).routes.count == 250)
        try Self.expectLinear(
            "parsing 250 and 4 000 routed inputs",
            small: { _ = try Self.parse(small) },
            large: { _ = try Self.parse(large) }
        )
    }

    /// `count` events whose payloads name a type declared outside the schema, each checked with a
    /// message that names its event: each message's function is found by the message.
    @Test func witnessFunctionsAreFoundByMessage() throws {
        func schema(_ count: Int) -> String {
            let events = (0 ..< count).map { "@Event enum E\($0) { typealias Payload = Outside\($0) }" }
            let emitted = (0 ..< count).map { "E\($0).self" }.joined(separator: ", ")
            return """
                @StateMachine(mode: .shared)
                enum Flow {
                    struct Idle {}
                    @Initial case idle(Idle)
                    enum Input { case go }
                    \(events.joined(separator: "\n    "))
                    @Transition(on: Input.go, emits: [\(emitted)])
                    static func go(_ source: Idle) -> Change<Idle, Effect.Go> { fatalError() }
                }
                """
        }
        let small = try Self.parse(schema(125))
        let large = try Self.parse(schema(2_000))
        #expect(Set(small.typeChecks.map(\.reference)).count >= 125)
        try Self.expectLinear(
            "generating 125 and 2 000 event checks",
            small: { _ = try Generator(schema: small).members() },
            large: { _ = try Generator(schema: large).members() }
        )
    }

    /// One phase, six hundred operations an input edge may start, and a success self-loop for each: the
    /// joint analysis charges its setup against its budget before it allocates the setup, so a budget the
    /// setup exceeds is refused at once rather than after an operation-wide array for every edge.
    @Test func jointAnalysisChargesItsSetupFirst() throws {
        let count = 600
        let operations = (0 ..< count).map { "@Operation(activeIn: [Idle.self]) enum O\($0) {}" }
        let started = (0 ..< count).map { "O\($0).self" }.joined(separator: ", ")
        let completions = (0 ..< count)
            .map {
                "@Transition(onSuccess: O\($0).self)\n    static func done\($0)(_ source: Idle) -> Idle { fatalError() }"
            }
        let schema = try Self.parse(
            """
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
        )
        #expect(schema.jointReach(budget: count - 1) == nil)
        // One phase and no invalidation: the setup is one mask, which a budget of its size admits.
        let full = Self.seconds { _ = schema.jointReach() }
        let refused = Self.seconds { #expect(schema.jointReach(budget: count - 1) == nil) }
        #expect(refused < full / 20, "a refused setup took \(refused) s, a full analysis \(full) s")
    }

    /// A namespace with a long name, read through an alias, whose thousand members form one composition:
    /// the long name is hashed when it is numbered, not again by every member's key, so the reading takes
    /// about as long as reading the long name once and the thousand short members apart.
    @Test func aLongNamespaceNameIsHashedOnce() throws {
        func schema(nameLength: Int, members count: Int) throws -> Schema {
            let name = "Long" + String(repeating: "x", count: nameLength)
            let members = (0 ..< count).map { "protocol P\($0) {}" }.joined(separator: "; ")
            let output = "any " + (0 ..< count).map { "NS.P\($0)" }.joined(separator: " & ")
            return try Self.parse(
                TypeResolutionTests.loading(
                    aliases: "typealias Output = \(output)",
                    declarations: "enum \(name) { \(members) }; typealias NS = \(name)",
                    edges:
                        "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Load.Output) -> Idle { fatalError() }"
                )
            )
        }
        let longName = try schema(nameLength: 100_000, members: 10)
        let manyMembers = try schema(nameLength: 10, members: 1_000)
        let both = try schema(nameLength: 100_000, members: 1_000)
        let apart =
            Self.seconds { _ = longName.typeScopes.resolve("Load.Output") }
            + Self.seconds { _ = manyMembers.typeScopes.resolve("Load.Output") }
        let together = Self.seconds(runs: 1) { _ = both.typeScopes.resolve("Load.Output") }
        #expect(together < 0.05 || together < 10 * apart, "apart \(apart) s, together \(together) s")
        #expect(KeyName(number: 7, text: "a") == KeyName(number: 7, text: "b"))
        #expect(KeyName(number: 7, text: "a").hashValue == KeyName(number: 7, text: "b").hashValue)
    }

    /// One operation that requires `count` scopes and an edge that invalidates them all: each scope's
    /// identifier is found in the schema's table, so emitting the dependencies and the invalidations takes
    /// time linear in the scopes.
    @Test func scopeIdentifiersAreFoundInOneTable() throws {
        func schema(_ count: Int) throws -> Schema {
            let cases = (0 ..< count).map { "s\($0)" }.joined(separator: ", ")
            let scopes = (0 ..< count).map { "Scope.s\($0)" }.joined(separator: ", ")
            return try Self.parse(
                """
                @StateMachine(mode: .shared)
                enum Flow {
                    struct Idle {}
                    struct Busy {}
                    @Initial case idle(Idle)
                    case busy(Busy)
                    enum Scope { case \(cases) }
                    enum Input { case go, stop }
                    @Operation(requires: [\(scopes)], activeIn: [Busy.self])
                    enum Work {}
                    @Transition(on: Input.go, starts: [Work.self])
                    static func go(_ source: Idle) -> Change<Busy, Effect.Go> { fatalError() }
                    @Transition(on: Input.stop, invalidates: [\(scopes)])
                    static func stop(_ source: Busy) -> Idle { fatalError() }
                    @Transition(onSuccess: Work.self)
                    static func done(_ source: Busy) -> Idle { fatalError() }
                }
                """
            )
        }
        let small = try schema(100)
        let large = try schema(1_600)
        #expect(small.scopeIndex("s99") == 99 && large.scopeIndex("Work.self") == 1_600)
        #expect(Generator(schema: small).preparation().contains("_StateMachineScopeID(kind: 99)"))
        Self.expectLinear(
            "emitting 100 and 1 600 scope dependencies",
            small: { _ = Generator(schema: small).preparation() },
            large: { _ = Generator(schema: large).preparation() }
        )
    }

    /// `count` generated methods in one type whose signatures use a spelling that type would capture:
    /// the type's members are read once to decide every use, not once per use.
    @Test func shieldingReadsEachGeneratedScopeOnce() throws {
        func declarations(_ count: Int) -> [DeclSyntax] {
            let methods = (0 ..< count).map { "func f\($0)(_ value: _StateMachineSpelling1) {}" }
            return [DeclSyntax(stringLiteral: "struct Shared {\nstruct Host {}\n\(methods.joined(separator: "\n"))\n}")]
        }
        let shield = SpellingShield(
            aliases: [("_StateMachineSpelling1", "Host")],
            schemaAccess: .internal,
            authoredIdentifiers: ["Host"]
        )
        for count in [10, 1_000] {
            let shielded = shield.apply(to: declarations(count))
            #expect(shielded.aliases.map(\.spelling) == ["Host"])
            #expect(shielded.membersRead == count + 1, "\(count) uses")
            #expect(
                shielded.declarations.first?.description.contains("f\(count - 1)(_ value: _StateMachineType1)") == true
            )
        }
    }

    /// An operation's `Output` nested twenty arrays deep, which the graph shows as the parser kept it.
    ///
    /// Generating the graph parses nothing again, where parsing nested brackets takes time that doubles
    /// with each level. Every spelling the macro parses is parsed through the schema's spellings, which
    /// record it, so the graph adds none to them.
    @Test func theGraphShowsSpellingsWithoutParsingThemAgain() throws {
        let nested = String(repeating: "[", count: 20) + "Swift::Int" + String(repeating: "]", count: 20)
        let schema = try Self.parse(
            TypeResolutionTests.loading(
                aliases: "typealias Output = \(nested)",
                edges:
                    "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Load.Output) -> Idle { fatalError() }"
            )
        )
        #expect(schema.operations.first?.outputType == nested)
        let parsed = schema.spellings.parsed
        let graph = Generator(schema: schema).graph()
        #expect(graph.contains(nested))
        #expect(schema.spellings.parsed == parsed, "\(schema.spellings.parsed.subtracting(parsed))")
        #expect(!schema.spellings.parsed.contains { $0.contains("[[[") }, "\(schema.spellings.parsed)")
    }

    /// An edge whose payload, request, and failure are nested `depth` arrays deep: generating every
    /// member reads each authored spelling from the author's syntax, so none is parsed again.
    @Test func authoredSpellingsAreNeverParsedAgain() throws {
        let nested = String(repeating: "[", count: 12) + "Swift::Int" + String(repeating: "]", count: 12)
        let schema = try Self.parse(
            """
            @StateMachine(mode: .shared)
            enum Flow {
                struct Problem<T>: Error {}
                struct Idle {}
                struct Done {}
                @Initial case idle(Idle)
                @Terminal case done(Done)
                enum Input { case go(\(nested)) }
                @Transition(on: Input.go)
                static func go(_ source: Idle, _ value: \(nested)) throws(Problem<\(nested)>) -> Done { fatalError() }
            }
            """
        )
        _ = try Generator(schema: schema).members()
        #expect(!schema.spellings.parsed.contains { $0.contains("[[[") }, "\(schema.spellings.parsed)")
    }
}
