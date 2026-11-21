import Testing

@testable import StateMachineMacros

/// Spellings Swift reads as the plain declaration read as it: parentheses around a type the schema's
/// shape names, and the underscored ownership of a source parameter.
struct TransparentSpellingTests {
    private static func parse(_ text: String) throws -> Schema { try DeclarationHygieneTests.parse(text) }
    private static func diagnostics(_ text: String) -> [String]? { DeclarationHygieneTests.diagnostics(text) }

    static let seed = #"""
        @StateMachine(mode: .shared, owners: [.owned, .local])
        enum Flow {
            struct Draft { var n = 0 }
            struct Review {}
            struct Approved {}
            @Initial case draft(Draft = Draft())
            case review(Review)
            @Terminal case approved(Approved)
            enum Input { case submit(Int), approve }
            @Operation(activeIn: [Review.self])
            enum Check { typealias Output = Int }
            @Event enum Note { typealias Payload = Int }
            @Transition(on: Input.submit, starts: [Check.self], emits: [Note.self])
            static func submit(_ source: Draft, _ value: Int) -> Change<Review, Effect.Submit> { fatalError() }
            @Transition(onSuccess: Check.self)
            static func checked(_ source: Review, _ value: Int) -> Review { fatalError() }
            @Route(on: Input.approve)
            static func decide(_ source: Review) -> Route.Decide { fatalError() }
            @Transition(on: Input.approve)
            static func accept(_ source: Review) -> Approved { fatalError() }
            @Transition(on: Input.approve)
            static func back(_ source: Review) -> Draft { fatalError() }
        }
        """#

    /// What the shape tests read: each phase's payload, each edge's source, destination, shape, and
    /// effects, and each router's choices.
    private static func shape(_ schema: Schema) -> [String] {
        ["initial: \(schema.initial) = \(schema.initialDefault ?? "-")"]
            + schema.phases.map { "\($0.caseName)(\($0.typeName))" }
            + schema.transitions.map {
                "\($0.name): \($0.from) -> \($0.to) \($0.shape) \($0.effectNamespace ?? "-") \($0.starts) \($0.emits)"
            }
            + schema.routes.map { "\($0.name): \($0.from) \($0.choices)" }
    }

    static let parenthesized: [(String, String)] = [
        ("case draft(Draft = Draft())", "case draft((Draft) = Draft())"),
        ("case draft(Draft = Draft())", "case draft(((Flow.Draft)) = Draft())"),
        ("case draft(Draft = Draft())", "case draft((_: Draft) = Draft())"),
        ("case draft(Draft = Draft())", "case draft((Self).Draft = Draft())"),
        ("case review(Review)", "case review((Review))"),
        ("func submit(_ source: Draft,", "func submit(_ source: (Draft),"),
        ("func submit(_ source: Draft,", "func submit(_ source: borrowing (Draft),"),
        ("func submit(_ source: Draft,", "func submit(_ source: (borrowing Draft),"),
        ("func submit(_ source: Draft,", "func submit(_ source: (Flow).Draft,"),
        ("_ value: Int) -> Change<Review", "_ value: (Int)) -> Change<Review"),
        ("-> Change<Review, Effect.Submit>", "-> (Change<Review, Effect.Submit>)"),
        ("-> Change<Review, Effect.Submit>", "-> Change<(Review), (Effect.Submit)>"),
        ("-> Change<Review, Effect.Submit>", "-> Change<Review, (Effect).Submit>"),
        ("-> Change<Review, Effect.Submit>", "-> ((StateMachine.Change<Review, Effect.Submit>))"),
        ("-> Route.Decide", "-> (Route.Decide)"),
        ("-> Route.Decide", "-> (Route).Decide"),
        ("-> Route.Decide", "-> (Self.Route.Decide)"),
        ("-> Approved {", "-> ((Approved)) {"),
        ("-> Draft {", "-> (Self).Draft {"),
    ]

    /// Swift reads a type in single unlabeled parentheses as that type, so the schema means what it
    /// means without them.
    @Test(arguments: parenthesized)
    func parenthesesChangeNoShape(_ plain: String, _ spelled: String) throws {
        let source = Self.seed.replacingOccurrences(of: plain, with: spelled)
        #expect(source != Self.seed)
        #expect(Self.diagnostics(source) == nil)
        #expect(try Self.shape(Self.parse(source)) == Self.shape(Self.parse(Self.seed)))
    }

    /// Parentheses that change what a spelling means keep their meaning: a labeled element is no type
    /// Swift accepts, and an optional payload is no phase payload.
    @Test func parenthesesThatMeanSomethingElseAreRefused() {
        for spelled in ["case draft((x: Draft))", "case draft((Draft)?)"] {
            #expect(
                Self.diagnostics(Self.seed.replacingOccurrences(of: "case draft(Draft = Draft())", with: spelled))?
                    .first?
                    .hasPrefix("Phase 'draft' needs a distinct nongeneric struct or enum") == true
            )
        }
    }

    /// `__shared` lends a source as `borrowing` does, and `__owned` takes it as its own as `consuming`
    /// does, so each is accepted where its modern spelling is and refused where it is not.
    @Test func underscoredOwnershipReadsAsItsModernSpelling() throws {
        let plain = "func submit(_ source: Draft,"
        for ownership in ["borrowing", "__shared"] {
            let source = Self.seed.replacingOccurrences(of: plain, with: "func submit(_ source: \(ownership) Draft,")
            #expect(Self.diagnostics(source) == nil)
            #expect(try Self.shape(Self.parse(source)) == Self.shape(Self.parse(Self.seed)))
            let routed = Self.seed.replacingOccurrences(
                of: "func decide(_ source: Review)",
                with: "func decide(_ source: \(ownership) Review)"
            )
            #expect(Self.diagnostics(routed) == nil)
        }
        for ownership in ["consuming", "__owned"] {
            #expect(
                Self.diagnostics(
                    Self.seed.replacingOccurrences(of: plain, with: "func submit(_ source: \(ownership) Draft,")
                ) == ["Use a plain or borrowing phase payload as the source parameter."]
            )
        }
        let owned = #"""
            @StateMachine(mode: .ownedOnly)
            enum Token: ~Copyable {
                struct Ready: ~Copyable {}
                struct Spent: ~Copyable {}
                @Initial case ready(Ready)
                @Terminal case spent(Spent)
                enum Input { case spend }
                @Transition(on: Input.spend)
                static func spend(_ source: OWNERSHIP Ready) -> Spent { fatalError() }
            }
            """#
        for ownership in ["consuming", "__owned"] {
            #expect(Self.diagnostics(owned.replacingOccurrences(of: "OWNERSHIP", with: ownership)) == nil)
        }
        for ownership in ["borrowing", "__shared", "sending", "inout"] {
            #expect(
                Self.diagnostics(owned.replacingOccurrences(of: "OWNERSHIP", with: ownership)) == [
                    "Use an explicitly consuming phase payload as the source parameter."
                ]
            )
        }
    }
}
