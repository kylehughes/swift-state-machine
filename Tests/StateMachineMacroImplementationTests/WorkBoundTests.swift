import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

/// The expansion's work grows with the declarations.
///
/// Each family is measured at two sizes by the macro's own counts of the work it does, which are the same
/// on every machine and in every configuration, so a bound holds however loaded the machine is: each
/// count is bounded by a constant times the size at both sizes, where work quadratic in the size would
/// pass the bound at the larger.
struct WorkBoundTests {
    private static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }

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
        for count in [250, 4_000] {
            let parsed = try Self.parse(schema(count))
            #expect(parsed.routes.count == count)
            // Each of the three functions of a trigger looks its input up once, and nothing searches for one.
            let work = parsed.work
            #expect(work.triggersFound == 3 * count && work.triggersScanned == 0, "\(work)")
            #expect(work.tablesBuilt <= 4 && work.tabledEntries <= 4 * (3 * count + 1), "\(work)")
            #expect(work.routerLookups <= 16 * count, "\(work)")
        }
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
        for count in [125, 2_000] {
            let parsed = try Self.parse(schema(count))
            let checks = parsed.typeChecks.count
            #expect(Set(parsed.typeChecks.map(\.reference)).count >= count)
            let validated = parsed.work
            #expect(validated.plansBuilt <= 4 && validated.plannedChecks <= 4 * checks, "\(validated)")
            _ = try Generator(schema: parsed).members()
            // Generation builds one plan, which finds each check's function once as it is built and once
            // as the check calls it, each time in one lookup.
            let generated = parsed.work.since(validated)
            #expect(generated.plansBuilt == 1 && generated.plannedChecks == checks, "\(generated)")
            #expect(generated.planLookups == 2 * checks, "\(generated)")
        }
    }

    /// One phase, six hundred operations an input edge may start, and a success self-loop for each: the
    /// joint analysis charges its setup against its budget before it allocates the setup, so a budget the
    /// setup exceeds is refused at once rather than after an operation-wide array for every edge.
    ///
    /// At three hundred operations and at six hundred, a refused analysis charges its setup and builds
    /// nothing, and an admitted one builds exactly what it charged.
    @Test func jointAnalysisChargesItsSetupFirst() throws {
        for count in [300, 600] {
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
            let before = schema.work
            #expect(schema.jointReach(budget: count - 1) == nil)
            let refused = schema.work.since(before)
            #expect(refused.jointSetupCharged == count && refused.jointSetupBuilt == 0, "\(refused)")
            // One phase and no invalidation: the setup is one mask, which a budget of its size admits.
            _ = schema.jointReach(budget: count)
            let admitted = schema.work.since(before).since(refused)
            #expect(admitted.jointSetupCharged == count && admitted.jointSetupBuilt == count, "\(admitted)")
            #expect(schema.jointReach() != nil)
        }
    }

    /// A namespace with a long name, read through an alias, whose thousand members form one composition:
    /// the long name is hashed when it is numbered, not again by every member's key, so reading it hashes
    /// as many characters as reading the long name and the thousand short members apart.
    ///
    /// The schema is read with a name of ten characters and of a hundred thousand, and with ten members and
    /// a thousand: the thousand members add the same characters with either name, and the long name adds
    /// its characters a few times, however many members there are.
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
        /// The characters hashed to number names while the schema is read and its output resolved.
        func keyed(nameLength: Int, members: Int) throws -> Int {
            let scopes = try schema(nameLength: nameLength, members: members).typeScopes
            #expect(!scopes.resolve("Load.Output").isCut)
            return scopes.work.keyed
        }
        let short = try keyed(nameLength: 10, members: 10)
        let longName = try keyed(nameLength: 100_000, members: 10)
        let manyMembers = try keyed(nameLength: 10, members: 1_000)
        let both = try keyed(nameLength: 100_000, members: 1_000)
        #expect(both - manyMembers == longName - short, "\(short), \(longName), \(manyMembers), \(both)")
        #expect(longName - short <= 8 * (100_000 - 10), "\(short), \(longName)")
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
        for count in [100, 1_600] {
            let parsed = try schema(count)
            #expect(parsed.scopeIndex("s\(count - 1)") == count - 1 && parsed.scopeIndex("Work.self") == count)
            let generator = Generator(schema: parsed)
            let before = parsed.work
            let preparation = generator.preparation()
            // Each scope's eligibility, the operation's scope, and each dependency are one lookup each.
            let work = parsed.work.since(before)
            #expect(work.scopeLookups == 2 * count + 2 && work.tablesBuilt <= 1, "\(work)")
            #expect(preparation.contains("_StateMachineScopeID(kind: \(count - 1))"))
        }
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

extension Schema.Work {
    /// The work counted since `earlier` was, count by count.
    func since(_ earlier: Schema.Work) -> Schema.Work {
        Schema.Work(
            triggersFound: triggersFound - earlier.triggersFound,
            triggersScanned: triggersScanned - earlier.triggersScanned,
            tablesBuilt: tablesBuilt - earlier.tablesBuilt,
            tabledEntries: tabledEntries - earlier.tabledEntries,
            routerLookups: routerLookups - earlier.routerLookups,
            dispatchedPairs: dispatchedPairs - earlier.dispatchedPairs,
            dispatchedEdges: dispatchedEdges - earlier.dispatchedEdges,
            failureAnalyses: failureAnalyses - earlier.failureAnalyses,
            failuresRead: failuresRead - earlier.failuresRead,
            rejectionCases: rejectionCases - earlier.rejectionCases,
            plansBuilt: plansBuilt - earlier.plansBuilt,
            plannedChecks: plannedChecks - earlier.plannedChecks,
            planLookups: planLookups - earlier.planLookups,
            jointSetupCharged: jointSetupCharged - earlier.jointSetupCharged,
            jointSetupBuilt: jointSetupBuilt - earlier.jointSetupBuilt,
            scopeLookups: scopeLookups - earlier.scopeLookups
        )
    }
}
