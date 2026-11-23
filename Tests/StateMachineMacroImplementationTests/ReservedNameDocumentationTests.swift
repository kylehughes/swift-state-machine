import Foundation
import Testing

@testable import StateMachineMacros

/// Keeps the reserved-names reference in `DeclaringAGraph.md` aligned with `Naming.swift`.
struct ReservedNameDocumentationTests {
    private static func reservedNamesSection() throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let guideURL =
            packageRoot
            .appendingPathComponent("Documentation/StateMachine.docc/DeclaringAGraph.md")
        let fullText = try String(contentsOf: guideURL, encoding: .utf8)
        guard let range = fullText.range(of: "### Size limits and reserved names") else {
            Issue.record("Missing '### Size limits and reserved names' section in DeclaringAGraph.md")
            return ""
        }
        return String(fullText[range.lowerBound...])
    }

    private static func parse(_ source: String) throws -> Schema {
        try DeclarationHygieneTests.parse(source)
    }

    private static func sampleSchemas() throws -> [Schema] {
        let sharedFull = try parse(
            #"""
            @StateMachine(mode: .shared, owners: [.owned, .local, .shared, .actorHost, .mainActorHost, .isolatedHost])
            nonisolated enum SharedFull: Sendable {
                struct Idle: Sendable {}
                struct Busy: Sendable {}
                struct Done: Sendable {}
                @Initial case idle(Idle = Idle())
                case busy(Busy)
                @Terminal case done(Done)
                enum Input: Sendable { case go, cancel }
                enum FetchFailure: Error, Sendable { case bad }
                @Operation(activeIn: [Busy.self])
                enum Fetch {
                    typealias Input = Int
                    typealias Output = String
                    typealias Failure = FetchFailure
                }
                @Event enum Tracked { typealias Payload = String }
                @Transition(on: Input.go, starts: [Fetch.self], emits: [Tracked.self])
                fileprivate static func start(_ source: Idle) -> Change<Busy, Effect.Start> { fatalError() }
                @Transition(on: Input.go)
                fileprivate static func skip(_ source: Idle) -> Done { fatalError() }
                @Route(on: Input.go)
                fileprivate static func choose(_ source: Idle) -> Route.Choose { .skip }
                @Transition(on: Input.cancel)
                fileprivate static func cancel(_ source: Busy) -> Idle { fatalError() }
                @Transition(onSuccess: Fetch.self)
                fileprivate static func fetched(_ source: Busy, _ out: Fetch.Output) -> Done { fatalError() }
                @Transition(onFailure: Fetch.self)
                fileprivate static func failed(_ source: Busy, _ err: Fetch.Failure) -> Idle { fatalError() }
                @Restoration
                fileprivate static func restore(_ data: Data) throws(FetchFailure) -> Restoration { fatalError() }
            }
            """#
        )
        let isolatedFull = try parse(
            #"""
            @StateMachine(mode: .isolated, owners: [.owned, .local, .mainActorHost, .isolatedHost])
            nonisolated enum IsolatedFull {
                struct Idle {}
                struct Busy {}
                struct Done {}
                @Initial case idle(Idle)
                case busy(Busy)
                @Terminal case done(Done)
                enum Input { case go }
                @Operation(activeIn: [Busy.self])
                enum Load { typealias Output = Int }
                @Transition(on: Input.go, starts: [Load.self])
                fileprivate static func start(_ source: Idle) -> Change<Busy, Effect.Start> { fatalError() }
                @Transition(onSuccess: Load.self)
                fileprivate static func done(_ source: Busy, _ value: Load.Output) -> Done { fatalError() }
            }
            """#
        )
        let ownedOnly = try parse(
            #"""
            @StateMachine(mode: .ownedOnly)
            nonisolated enum OwnedMinimal: ~Copyable {
                struct Idle: ~Copyable {}
                struct Done: ~Copyable {}
                @Initial case idle(Idle)
                @Terminal case done(Done)
                @Transition
                fileprivate static func finish(_ source: consuming Idle) -> Done { Done() }
            }
            """#
        )
        let localOnly = try parse(
            #"""
            @StateMachine(mode: .shared, owners: [.local])
            nonisolated enum LocalOnly: Sendable {
                struct Idle: Sendable {}
                struct Done: Sendable {}
                @Initial case idle(Idle)
                @Terminal case done(Done)
                enum Input: Sendable { case finish }
                @Transition(on: Input.finish)
                fileprivate static func finish(_ source: Idle) -> Done { Done() }
            }
            """#
        )
        let mainActorOnly = try parse(
            #"""
            @StateMachine(mode: .shared, owners: [.mainActorHost])
            nonisolated enum MainActorOnly: Sendable {
                struct Idle: Sendable {}
                struct Done: Sendable {}
                @Initial case idle(Idle)
                @Terminal case done(Done)
                enum Input: Sendable { case finish }
                @Transition(on: Input.finish)
                fileprivate static func finish(_ source: Idle) -> Done { Done() }
            }
            """#
        )
        return [sharedFull, isolatedFull, ownedOnly, localOnly, mainActorOnly]
    }

    @Test func everyPublicReservedNameInNamingIsDocumentedInDeclaringAGraph() throws {
        let section = try Self.reservedNamesSection()
        let schemas = try Self.sampleSchemas()

        // Collect every non-underscore fixed generated name and schema-name reservation across all configurations.
        var publicReserved: Set<String> = []
        for schema in schemas {
            let operationNames = Set(schema.operationTypeNames.map(\.name))
            for name in schema.fixedGeneratedNames.union(schema.schemaNameReservations)
            where !name.hasPrefix("_") && !operationNames.contains(name) {
                publicReserved.insert(name)
            }
        }

        for name in publicReserved.sorted() {
            #expect(
                section.contains("`\(name)`"),
                "Reserved name '\(name)' from Naming.swift is missing from DeclaringAGraph.md's reserved-names section."
            )
        }

        // Verify operation-derived patterns, router companion/case reservations, and underscore witness families are documented.
        for pattern in [
            "<Op>Request", "<Op>Completion", "<Op>Work", "_<Op>Work", "_StateMachine*", "_stateMachine*",
            "route", "<Router>Result", "rejected",
        ] {
            #expect(
                section.contains("`\(pattern)`"),
                "Reserved pattern '\(pattern)' is missing from DeclaringAGraph.md."
            )
        }
    }

    @Test func contextualReservationsRemainOwnerSpecific() throws {
        let schemas = try Self.sampleSchemas()
        let ownedOnly = schemas[2]
        let localOnly = schemas[3]
        let mainActorOnly = schemas[4]

        // Unconditional names are reserved everywhere.
        for unconditional in ["Change", "Advance", "Phase", "Effect", "graph"] {
            #expect(ownedOnly.fixedGeneratedNames.contains(unconditional))
            #expect(localOnly.fixedGeneratedNames.contains(unconditional))
            #expect(mainActorOnly.fixedGeneratedNames.contains(unconditional))
        }

        // Contextual names are NOT unconditionally reserved on unrelated owners.
        #expect(!ownedOnly.fixedGeneratedNames.contains("Configuration"))
        #expect(!ownedOnly.fixedGeneratedNames.contains("LocalConfiguration"))
        #expect(!ownedOnly.fixedGeneratedNames.contains("Route"))
        #expect(!ownedOnly.fixedGeneratedNames.contains("Snapshot"))

        #expect(localOnly.fixedGeneratedNames.contains("LocalConfiguration"))
        #expect(!localOnly.fixedGeneratedNames.contains("Configuration"))
        #expect(!localOnly.fixedGeneratedNames.contains("Shared"))

        #expect(mainActorOnly.fixedGeneratedNames.contains("Configuration"))
        #expect(!mainActorOnly.fixedGeneratedNames.contains("LocalConfiguration"))
        #expect(!mainActorOnly.fixedGeneratedNames.contains("Local"))
    }
}
