import Testing

@testable import StateMachineMacros

/// The shape of the generated dispatch, which decides what the compiler does with a large schema.
struct GeneratedDispatchTests {
    private static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }

    /// `count` phases in a cycle, each taking `next` with a payload, and `count` operations, each started
    /// by an input from the first phase and completed there, for every owner.
    static func schema(_ count: Int) -> String {
        let phases = (0 ..< count).map { "struct P\($0) {}\n    \($0 == 0 ? "@Initial " : "")case p\($0)(P\($0))" }
        let edges = (0 ..< count)
            .map {
                "@Transition(on: Input.next)\n    static func next\($0)(_ source: P\($0), _ value: Int) -> P\(($0 + 1) % count) { fatalError() }"
            }
        let operations = (0 ..< count)
            .map {
                """
                @Operation(activeIn: [P0.self]) enum O\($0) { typealias Input = Int }
                    @Transition(on: Input.start\($0), starts: [O\($0).self])
                    static func start\($0)(_ source: P0) -> Change<P0, Effect.Start\($0)> { fatalError() }
                    @Transition(onSuccess: O\($0).self)
                    static func done\($0)(_ source: P0) -> P0 { fatalError() }
                """
            }
        let inputs = (0 ..< count).map { "case start\($0)" }.joined(separator: "\n        ")
        return """
            @StateMachine(mode: .shared, owners: [.owned, .local, .shared, .actorHost, .mainActorHost, .isolatedHost])
            enum Flow {
                \(phases.joined(separator: "\n    "))
                enum Input {
                    case next(Int)
                    \(inputs)
                }
                \(operations.joined(separator: "\n    "))
                \(edges.joined(separator: "\n    "))
            }
            """
    }

    private static func generated(_ count: Int) throws -> String {
        try Generator(schema: parse(schema(count))).members().map(\.description).joined(separator: "\n")
    }

    /// Swift checks a switch over a tuple of two large enums in time that grows with the product of
    /// their cases, past its budget at a hundred operations, so each dispatch nests single-subject
    /// switches: on the trigger, naming every case without a default, then on the snapshot.
    @Test func dispatchNestsSingleSubjectSwitches() throws {
        let text = try Self.generated(8)
        #expect(!text.contains("switch (input, snapshot)"))
        #expect(!text.contains("switch (completion, snapshot)"))
        #expect(text.contains("switch input {"))
        #expect(text.contains("switch completion {"))
        // Every input and operation has its own case in the outer switch.
        for index in 0 ..< 8 {
            #expect(text.contains("case .start\(index):"))
            #expect(text.contains("case .o\(index)(let completion):"))
        }
    }

    /// A managed owner's driver selects the execution of the operation it runs and awaits it once: an
    /// async closure that awaited every operation's driver in its own case compiled, for each suspension,
    /// code for every case, which took the compiler gigabytes at a hundred operations.
    @Test func aManagedDriverAwaitsOnce() throws {
        let text = try Self.generated(8)
        let drivers = text.components(separatedBy: "driver: { ").dropFirst()
        #expect(drivers.count == 4)
        for driver in drivers {
            let body = driver.components(separatedBy: "}, ticket:")[0]
            #expect(body.components(separatedBy: "return await execution()").count == 2)
            #expect(body.components(separatedBy: "execution = {").count == 9)
        }
    }

    /// The generated text, and with it the compiler's work on the dispatch, grows linearly.
    @Test func generatedTextGrowsLinearly() throws {
        let small = try Self.generated(16).utf8.count
        let large = try Self.generated(128).utf8.count
        #expect(large < small * 9, "\(small) then \(large) bytes")
    }

    /// A schema past a limit is refused, naming the limit, before Swift meets a switch it cannot check.
    @Test func aSchemaPastALimitIsRefused() throws {
        #expect(try Self.parse(Self.schema(8)).sizeLimitExcess == nil)
        let phases = (0 ..< 601).map { "struct P\($0) {}\n    \($0 == 0 ? "@Initial " : "")case p\($0)(P\($0))" }
        let edges = (0 ..< 601)
            .map {
                "@Transition(on: Input.next)\n    static func next\($0)(_ source: P\($0)) -> P\(($0 + 1) % 601) { fatalError() }"
            }
        let schema = try Self.parse(
            """
            @StateMachine(mode: .shared)
            enum Flow {
                \(phases.joined(separator: "\n    "))
                enum Input { case next }
                \(edges.joined(separator: "\n    "))
            }
            """
        )
        #expect(
            schema.sizeLimitExcess
                == "This schema declares 601 phases; the macro accepts at most 600, because Swift checks a switch over its Snapshot cases only within a fixed budget and type-checks a larger expansion slowly. Split the graph into several schemas."
        )
        #expect(
            try Self.parse(Self.schema(257)).sizeLimitExcess?.hasPrefix("This schema declares 257 operations") == true
        )
    }
}
