import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

/// Spellings of one type through a base alias read as the base's own spelling does: the same outcome,
/// the same members, the same key, in work within a constant factor of each other.
///
/// Each family of the reading-cost inputs is declared inside `enum Namespace`, and its output is spelled
/// at the schema's scope with every reference to it, or only the outermost one, through a base: the
/// namespace itself, an alias of it, an alias of that alias, `Self.Namespace`, the schema's name, or an
/// alias through the schema's name. The namespace's own references are also spelled through `Self.`, and
/// its leaf type through an alias of a module selector's type reached through a base alias. Each base, and
/// the target of each alias of the namespace, is spelled as written, in parentheses, in two pairs of
/// parentheses, and with every name in backticks, which name the same type.
struct ReadingEquivalenceTests {
    /// How a base, and the target of each alias of the namespace, is spelled.
    enum Form: CaseIterable, CustomStringConvertible {
        case plain, parenthesized, doublyParenthesized, backticked

        var description: String {
            switch self {
            case .plain: "plain"
            case .parenthesized: "parenthesized"
            case .doublyParenthesized: "doubly parenthesized"
            case .backticked: "backticked"
            }
        }

        /// `base` in this form: `Flow.N2`, `(Flow.N2)`, `((Flow.N2))`, or `` `Flow`.`N2` ``; `Self` stays
        /// a keyword.
        func spell(_ base: String) -> String {
            switch self {
            case .plain: base
            case .parenthesized: "(\(base))"
            case .doublyParenthesized: "((\(base)))"
            case .backticked:
                base.split(separator: ".").map { $0 == "Self" ? String($0) : "`\($0)`" }.joined(separator: ".")
            }
        }
    }

    /// A spelling of the output: how a reference to a member of the namespace is spelled.
    enum Spelling: CaseIterable, CustomStringConvertible {
        case namespace, alias, nested, selfQualified, schemaQualified, schemaAlias
        case namespaceOuter, aliasOuter, nestedOuter, selfQualifiedOuter, schemaQualifiedOuter, schemaAliasOuter
        case innerSelf, leafAlias

        var description: String { "\(self)" }

        /// The base of the outermost reference, and of every other one.
        var bases: (first: String, rest: String) {
            switch self {
            case .namespace, .innerSelf: ("Namespace", "Namespace")
            case .alias, .leafAlias: ("N1", "N1")
            case .nested: ("N2", "N2")
            case .selfQualified: ("Self.Namespace", "Self.Namespace")
            case .schemaQualified: ("Flow.Namespace", "Flow.Namespace")
            case .schemaAlias: ("Flow.N2", "Flow.N2")
            case .namespaceOuter: ("Namespace", "Namespace")
            case .aliasOuter: ("N1", "Namespace")
            case .nestedOuter: ("N2", "Namespace")
            case .selfQualifiedOuter: ("Self.Namespace", "Namespace")
            case .schemaQualifiedOuter: ("Flow.Namespace", "Namespace")
            case .schemaAliasOuter: ("Flow.N2", "Namespace")
            }
        }
    }

    /// A family: its output, with `@` where a reference through a base goes, and the namespace's members,
    /// with `$` before each name that `.innerSelf` qualifies with `Self.`.
    struct Family: CustomStringConvertible {
        let name: String
        let output: String
        let members: [String]

        var description: String { name }
    }

    static func families(_ count: Int) -> [Family] {
        let range = 0 ..< count
        let parameters = range.map { "T\($0)" }.joined(separator: ", ")
        let ints = Array(repeating: "Swift::Int", count: count).joined(separator: ", ")
        let fanout = 100
        let uses = Array(repeating: "U", count: fanout).joined(separator: ", ")
        let fanoutParameters = (0 ..< fanout).map { "T\($0)" }.joined(separator: ", ")
        let fanoutMembers =
            [
                "typealias Ignore<\(fanoutParameters)> = Swift::Int",
                "typealias W<\(fanoutParameters)> = $Ignore<"
                    + (0 ..< fanout).map { "[T\($0)]" }.joined(separator: ", ") + ">",
                "typealias X<U> = $W<\(uses)>",
            ] + (0 ..< fanout).map { "struct C\($0) {}" }
        let fanoutTuple = "(" + (0 ..< fanout).map { "@X<@C\($0)>" }.joined(separator: ", ") + ")"
        return [
            Family(
                name: "tuple-aliases",
                output: "(" + range.map { "@A\($0)" }.joined(separator: ", ") + ")",
                members: ["typealias Id<T> = T"]
                    + range.map { "typealias A\($0) = $Id<$U\($0)>; typealias U\($0) = Swift::Int" }
            ),
            Family(
                name: "ignore-wrapped",
                output: "@Wrapper<\(ints)>",
                members: [
                    "typealias Ignore<\(parameters)> = Swift::Int",
                    "typealias Wrapper<\(parameters)> = $Ignore<" + range.map { "[T\($0)]" }.joined(separator: ", ")
                        + ">",
                ]
            ),
            Family(
                name: "composition",
                output: "any Swift::Sendable & " + range.map { "@C\($0)" }.joined(separator: " & "),
                members: range.map { "protocol P\($0) {}; typealias C\($0) = $P\($0)" }
            ),
            Family(
                name: "deep-chain",
                output: "@G\(count)<Swift::Int>",
                members: ["typealias G0<T> = T"] + (1 ... count).map { "typealias G\($0)<T> = $G\($0 - 1)<[T]>" }
            ),
            Family(
                name: "nongeneric-chain",
                output: "@K\(count)",
                members: ["typealias K0 = Swift::Int"] + (1 ... count).map { "typealias K\($0) = $K\($0 - 1)" }
            ),
            Family(
                name: "tuple-of-chains",
                output: "(" + range.map { "@B\($0)" }.joined(separator: ", ") + ")",
                members: range.map { "typealias B\($0) = $C\($0); typealias C\($0) = Swift::Int" }
            ),
            Family(name: "fanout-uses", output: fanoutTuple, members: fanoutMembers),
            // The reported input: an alias that ignores its argument, used with the fan-out's tuple.
            Family(
                name: "discard-fanout",
                output: "@Discard<\(fanoutTuple)>",
                members: ["typealias Discard<T> = Swift::Int"] + fanoutMembers
            ),
            Family(
                name: "cycle-ring",
                output: "@R0",
                members: (0 ..< 200)
                    .map { index in
                        "typealias R\(index) = (" + (1 ... 20).map { "$R\((index + $0) % 200)" }.joined(separator: ", ")
                            + ")"
                    }
            ),
        ]
    }

    static func source(_ family: Family, _ spelling: Spelling, _ form: Form = .plain) -> String {
        let (first, rest) = (form.spell(spelling.bases.first), form.spell(spelling.bases.rest))
        var output = family.output
        if let range = output.range(of: "@") { output.replaceSubrange(range, with: first + ".") }
        output = output.replacingOccurrences(of: "@", with: rest + ".")
        var members = family.members.joined(separator: "\n")
            .replacingOccurrences(of: "$", with: spelling == .innerSelf ? "Self." : "")
        if spelling == .leafAlias {
            members = members.replacingOccurrences(of: "Swift::Int", with: "SInt") + "\ntypealias SInt = Swift::Int"
        }
        return """
            @StateMachine(mode: .shared)
            enum Flow {
                enum Namespace {
                    \(members)
                }
                typealias N1 = \(form.spell("Namespace"))
                typealias N2 = \(form.spell("N1"))
                typealias Payload = \(output)
                struct Idle {}
                struct Running {}
                @Initial case idle(Idle)
                case running(Running)
                enum Input { case go }
                @Operation(activeIn: [Running.self])
                enum Load { typealias Output = Payload }
                @Transition(onSuccess: Load.self)
                static func done(_ source: Running, _ value: Load.Output) -> Idle { fatalError() }
                @Transition(on: Input.go, starts: [Load.self])
                static func go(_ source: Idle) -> Change<Running, Effect.Go> { fatalError() }
            }
            """
    }

    /// What a spelling comes to: its diagnostics, or its members, the output's reading, and the steps.
    struct Outcome: Equatable {
        var diagnostics: [String]?
        var members: Int?
        var key: TypeKey?
        var confirmed: Bool?
    }

    static func outcome(_ source: String) throws -> (Outcome, steps: Int?) {
        if let messages = DeclarationHygieneTests.diagnostics(source) {
            return (Outcome(diagnostics: messages), nil)
        }
        let schema = try DeclarationHygieneTests.parse(source)
        let members = try Generator(schema: schema).members().count
        let reading = schema.typeScopes.resolve("Load.Output")
        return (
            Outcome(members: members, key: reading.key, confirmed: reading.isConfirmed), schema.typeScopes.work.steps
        )
    }

    @Test(arguments: families(300), Form.allCases)
    func everySpellingThroughABaseAliasReadsAlike(_ family: Family, _ form: Form) throws {
        let (expected, baseline) = try Self.outcome(Self.source(family, .namespace))
        for spelling in Spelling.allCases where spelling != .namespace || form != .plain {
            let (outcome, steps) = try Self.outcome(Self.source(family, spelling, form))
            #expect(outcome == expected, "\(family) \(spelling) \(form)")
            if let steps, let baseline {
                #expect(
                    steps <= 3 * baseline + 64,
                    "\(family) \(spelling) \(form): \(steps) steps against \(baseline)"
                )
            }
        }
    }

    /// Members of distinct base aliases nested inside each other's arguments, spelled inline or through
    /// generic aliases a level each, read in steps linear in the levels, as through the namespace itself:
    /// a base alias that is a path of names is read where it is reached, and one spelled through a generic
    /// alias waits while the member's arguments, read meanwhile, reach every base inside them in one pass.
    @Test func nestedMembersOfDistinctBaseAliasesReadLinearly() throws {
        func schema(_ levels: Int, base target: String?, declared: Bool) -> String {
            let base = { (level: Int) in target == nil ? "Namespace" : "N\(level)" }
            let aliases = target.map { target in
                (0 ..< levels).map { "typealias N\($0) = \(target)" }.joined(separator: "; ")
            }
            var output = "Swift::Int"
            var declarations = "typealias Id<T> = T" + (aliases.map { "; " + $0 } ?? "")
            if declared {
                declarations +=
                    "; typealias L0<T> = \(base(0)).X<T>; "
                    + (1 ..< levels).map { "typealias L\($0)<T> = \(base($0)).X<L\($0 - 1)<T>>" }
                    .joined(separator: "; ")
                output = "L\(levels - 1)<Swift::Int>"
            } else {
                for level in 0 ..< levels { output = "\(base(level)).X<\(output)>" }
            }
            return TypeResolutionTests.loading(
                aliases: "typealias Output = \(output)",
                declarations: "enum Namespace { typealias X<T> = T }; " + declarations,
                edges:
                    "@Transition(onSuccess: Load.self)\nstatic func done(_ source: Running, _ value: Load.Output) -> Idle { fatalError() }"
            )
        }
        // The parser's own recursion bounds how deeply a test's thread nests arguments inline: a debug
        // SwiftSyntax reads 20 levels, and the macro refuses a declaration it cut short.
        for (declared, counts) in [(false, [3, 6, 12]), (true, [100, 200, 400])] {
            for target in ["Namespace", "Id<Namespace>"] {
                var steps: [Int] = []
                for levels in counts {
                    let (expected, _) = try Self.outcome(schema(levels, base: nil, declared: declared))
                    let (outcome, read) = try Self.outcome(schema(levels, base: target, declared: declared))
                    #expect(outcome == expected && outcome.diagnostics == nil, "\(levels) \(target) \(declared)")
                    steps.append(try #require(read))
                }
                #expect(steps[1] <= 2 * steps[0] + 64 && steps[2] <= 2 * steps[1] + 64, "\(target): \(steps)")
            }
        }
    }
}
