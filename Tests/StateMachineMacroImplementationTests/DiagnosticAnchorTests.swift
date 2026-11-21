import SwiftDiagnostics
import SwiftParser
import SwiftSyntax
import SwiftSyntaxMacroExpansion
import Testing

@testable import StateMachineMacros

/// Each refusal stands at the smallest piece of the declaration that causes it, never at the attribute
/// that marks the declaration or at the start of the whole declaration, unless nothing smaller causes it.
struct DiagnosticAnchorTests {
    /// A refusal: its message and the line and column it stands at, both counted from one.
    struct Located: Equatable, CustomStringConvertible {
        let message: String
        let line: Int
        let column: Int
        var description: String { "\(line):\(column) \(message)" }
    }

    /// The refusals of a schema, each with the location of its node in the source.
    static func refusals(_ text: String) -> [Located] {
        let syntax = Parser.parse(source: text)
        guard let declaration = syntax.statements.first?.item.as(EnumDeclSyntax.self),
            let attribute = declaration.attributes.first?.as(AttributeSyntax.self)
        else { fatalError("Malformed test fixture") }
        let converter = SourceLocationConverter(fileName: "Flow.swift", tree: syntax)
        do {
            _ = try Schema.parse(declaration, attribute: attribute)
            return []
        } catch let error as DiagnosticsError {
            return error.diagnostics.map { diagnostic in
                let location = diagnostic.location(converter: converter)
                return Located(message: diagnostic.message, line: location.line, column: location.column)
            }
        } catch {
            return [Located(message: "\(error)", line: 0, column: 0)]
        }
    }

    /// The line and column of the start of the `occurrence`th appearance of `needle` in `text`.
    static func site(of needle: String, occurrence: Int = 1, in text: String) -> (line: Int, column: Int)? {
        var searched = text.startIndex ..< text.endIndex
        var found: Range<String.Index>?
        for _ in 0 ..< occurrence {
            guard let range = text.range(of: needle, range: searched) else { return nil }
            found = range
            searched = range.upperBound ..< text.endIndex
        }
        guard let found else { return nil }
        let before = text[..<found.lowerBound]
        let line = before.reduce(into: 1) { count, character in if character == "\n" { count += 1 } }
        let lineStart = before.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        return (line, text.utf8.distance(from: lineStart, to: found.lowerBound) + 1)
    }

    /// A refusal the macro anchors at a token: the schema it refuses, the message it begins with, and
    /// the text the refusal stands at the start of.
    struct Case: CustomStringConvertible {
        let name: String
        let source: String
        let message: String
        let needle: String
        var occurrence = 1
        var description: String { name }
    }

    /// Asserts that `source` is refused first with a message that begins with `message`, at `needle`.
    static func expect(_ refusal: Case, sourceLocation: Testing.SourceLocation = #_sourceLocation) {
        let refusals = Self.refusals(refusal.source)
        guard let first = refusals.first else {
            Issue.record("\(refusal.name): the schema was accepted", sourceLocation: sourceLocation)
            return
        }
        #expect(first.message.hasPrefix(refusal.message), "\(refusal.name): \(first)", sourceLocation: sourceLocation)
        guard let site = site(of: refusal.needle, occurrence: refusal.occurrence, in: refusal.source) else {
            Issue.record("\(refusal.name): no '\(refusal.needle)' in the source", sourceLocation: sourceLocation)
            return
        }
        #expect(
            first.line == site.line && first.column == site.column,
            "\(refusal.name): expected \(site.line):\(site.column) at '\(refusal.needle)', found \(first)",
            sourceLocation: sourceLocation
        )
    }

    /// The schema with `original` replaced by `replacement`, which must appear in it.
    static func variant(_ base: String, _ original: String, _ replacement: String) -> String {
        precondition(base.contains(original), "No '\(original)' in the base schema")
        return base.replacingOccurrences(of: original, with: replacement)
    }

    /// A schema of two phases and two inputs, each phase leaving for the other.
    static let edges = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            struct Idle {}
            struct Busy {}
            @Initial case idle(Idle)
            case busy(Busy)
            enum Input { case go, stop }
            @Transition(on: Input.go)
            static func go(_ source: Idle) -> Busy { Busy() }
            @Transition(on: Input.stop)
            static func stop(_ source: Busy) -> Idle { Idle() }
        }
        """#

    /// A schema whose one operation runs in `Busy`, where its scope is active, and ends in a terminal phase.
    static let operations = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            struct Idle {}
            struct Busy {}
            struct Done {}
            @Initial case idle(Idle)
            case busy(Busy)
            @Terminal case done(Done)
            enum Input { case go }
            enum Scope {
                @Active(in: [Busy.self]) case work
            }
            @Operation(scope: Scope.work)
            enum Load { typealias Output = Swift::Int }
            @Transition(on: Input.go, starts: [Load.self])
            static func go(_ source: Idle) -> Change<Busy, Effect.Go> { Change(Busy(), effects: [.load]) }
            @Transition(onSuccess: Load.self)
            static func loaded(_ source: Busy, _ value: Int) -> Done { Done() }
        }
        """#

    /// An owned-only schema with one direct edge.
    static let ownedOnly = #"""
        @StateMachine(mode: .ownedOnly)
        enum Flow {
            struct Idle {}
            struct Done {}
            struct Problem: Error {}
            @Initial case idle(Idle)
            @Terminal case done(Done)
            @Transition
            static func finish(_ source: consuming Idle) -> Done { Done() }
        }
        """#

    /// A schema that validates saved data.
    static let restoring = #"""
        @StateMachine(mode: .shared)
        enum Flow {
            struct Idle {}
            struct Busy {}
            struct Saved {}
            @Initial case idle(Idle)
            case busy(Busy)
            enum Input { case go, stop }
            @Transition(on: Input.go)
            static func go(_ source: Idle) -> Busy { Busy() }
            @Transition(on: Input.stop)
            static func stop(_ source: Busy) -> Idle { Idle() }
            @Restoration
            static func restore(_ saved: Saved) -> Restoration { .idle(Idle()) }
        }
        """#

    @Test func theBaseSchemasAreAccepted() {
        for source in [Self.edges, Self.operations, Self.ownedOnly, Self.restoring] {
            #expect(Self.refusals(source) == [])
        }
    }

    /// The refusals the macro anchors at a function's offending token rather than at its attribute.
    @Test func functionShapeRefusalsStandAtTheOffendingToken() {
        let synchronous = "Use a synchronous nongeneric static function"
        let go = "static func go(_ source: Idle) -> Busy"
        let cases: [Case] = [
            Case(
                name: "async",
                source: Self.variant(Self.edges, go, "static func go(_ source: Idle) async -> Busy"),
                message: synchronous,
                needle: "async"
            ),
            Case(
                name: "generic parameters",
                source: Self.variant(Self.edges, go, "static func go<T>(_ source: Idle) -> Busy"),
                message: synchronous,
                needle: "<T>"
            ),
            Case(
                name: "generic where clause",
                source: Self.variant(
                    Self.edges,
                    go,
                    "static func go(_ source: Idle) -> Busy where Idle: Sendable"
                ),
                message: synchronous,
                needle: "where Idle"
            ),
            Case(
                name: "not static",
                source: Self.variant(Self.edges, go, "func go(_ source: Idle) -> Busy"),
                message: synchronous,
                needle: "func go"
            ),
            Case(
                name: "a labeled parameter",
                source: Self.variant(Self.edges, go, "static func go(source: Idle) -> Busy"),
                message: synchronous,
                needle: "source: Idle"
            ),
            Case(
                name: "a variadic parameter",
                source: Self.variant(Self.edges, go, "static func go(_ source: Idle...) -> Busy"),
                message: synchronous,
                needle: "..."
            ),
            Case(
                name: "a default",
                source: Self.variant(Self.edges, go, "static func go(_ source: Idle = Idle()) -> Busy"),
                message: synchronous,
                needle: "= Idle()"
            ),
            Case(
                name: "untyped throws",
                source: Self.variant(Self.edges, go, "static func go(_ source: Idle) throws -> Busy"),
                message: "Transitions must use typed throws(Failure), or omit throws.",
                needle: "throws"
            ),
            Case(
                name: "rethrows",
                source: Self.variant(Self.edges, go, "static func go(_ source: Idle) rethrows -> Busy"),
                message: "Transitions must use typed throws(Failure), or omit throws.",
                needle: "rethrows"
            ),
            Case(
                name: "a router's untyped throws",
                source: Self.variant(
                    Self.edges,
                    "@Transition(on: Input.stop)\n    static func stop(_ source: Busy) -> Idle { Idle() }",
                    """
                    @Transition(on: Input.stop)
                        static func stop(_ source: Busy) -> Idle { Idle() }
                        @Route(on: Input.stop)
                        static func pick(_ source: Busy) throws -> Route.Pick { .stop }
                    """
                ),
                message: "Routers must use typed throws(Failure), or omit throws.",
                needle: "throws"
            ),
            Case(
                name: "a restoration's untyped throws",
                source: Self.variant(
                    Self.restoring,
                    "restore(_ saved: Saved) -> Restoration",
                    "restore(_ saved: Saved) throws -> Restoration"
                ),
                message: "Restoration functions must use typed throws(Failure), or omit throws.",
                needle: "throws"
            ),
            Case(
                name: "a missing body",
                source: Self.variant(Self.edges, "-> Busy { Busy() }", "-> Busy"),
                message: "Provide the authored function body in the schema.",
                needle: "go("
            ),
            Case(
                name: "a missing payload parameter",
                source: Self.variant(Self.edges, "enum Input { case go, stop }", "enum Input { case go(Int), stop }"),
                message: "This trigger requires source and trigger payload parameters.",
                needle: "(_ source: Idle)"
            ),
            Case(
                name: "a missing completion output",
                source: Self.variant(
                    Self.operations,
                    "(_ source: Busy, _ value: Int) -> Done",
                    "(_ source: Busy) -> Done"
                ),
                message: "Operation 'Load' succeeds with output",
                needle: "(_ source: Busy)"
            ),
            Case(
                name: "a from: transition that takes a source",
                source: Self.variant(
                    Self.edges,
                    "@Transition(on: Input.go)\n    static func go(_ source: Idle)",
                    "@Transition(on: Input.go, from: [Idle.self])\n    static func go(_ source: Idle)"
                ),
                message: "A transition that lists its source phases in from: takes no parameters.",
                needle: "(_ source: Idle)"
            ),
            Case(
                name: "a missing return",
                source: Self.variant(
                    Self.edges,
                    "static func go(_ source: Idle) -> Busy { Busy() }",
                    "static func go(_ source: Idle) {}"
                ),
                message: "Return the destination phase payload, a Change, or a Route choice.",
                needle: "(_ source: Idle) {}"
            ),
            Case(
                name: "an owned-only transition that throws",
                source: Self.variant(
                    Self.ownedOnly,
                    "consuming Idle) -> Done",
                    "consuming Idle) throws(Problem) -> Done"
                ),
                message: "Owned-only transitions cannot throw;",
                needle: "throws(Problem)"
            ),
            Case(
                name: "an owned-only source without consuming",
                source: Self.variant(Self.ownedOnly, "consuming Idle) -> Done", "Idle) -> Done"),
                message: "Use an explicitly consuming phase payload as the source parameter.",
                needle: "Idle) -> Done"
            ),
            Case(
                name: "a consuming source",
                source: Self.variant(Self.edges, "go(_ source: Idle)", "go(_ source: consuming Idle)"),
                message: "Use a plain or borrowing phase payload as the source parameter.",
                needle: "consuming"
            ),
            Case(
                name: "a source with a second specifier",
                source: Self.variant(Self.edges, "go(_ source: Idle)", "go(_ source: borrowing sending Idle)"),
                message: "Use a plain or borrowing phase payload as the source parameter.",
                needle: "sending"
            ),
            Case(
                name: "both a transition and a router",
                source: Self.variant(
                    Self.edges,
                    "@Transition(on: Input.go)\n",
                    "@Transition(on: Input.go) @Route(on: Input.go)\n"
                ),
                message: "A function cannot be both a transition and a router.",
                needle: "@Route"
            ),
            Case(
                name: "a restoration that is a transition",
                source: Self.variant(
                    Self.restoring,
                    "@Restoration\n",
                    "@Restoration @Transition(on: Input.go)\n"
                ),
                message: "A @Restoration function cannot also be a transition or a router.",
                needle: "@Transition(on: Input.go)\n",
                occurrence: 2
            ),
            Case(
                name: "a plain function named like an edge",
                source: Self.variant(
                    Self.edges,
                    "    @Transition(on: Input.stop)",
                    "    static func go() {}\n    @Transition(on: Input.stop)"
                ),
                message: "'go' names a transition or router;",
                needle: "go() {}"
            ),
        ]
        for refusal in cases { Self.expect(refusal) }
    }

    /// The refusals of a graph that stand at the phase, operation, or reference they are about.
    @Test func graphRefusalsStandAtTheDeclarationTheyAreAbout() {
        let cases: [Case] = [
            Case(
                name: "an operation active in a terminal phase it lists",
                source: Self.variant(
                    Self.operations,
                    "@Operation(scope: Scope.work)",
                    "@Operation(activeIn: [Busy.self, Done.self])"
                ),
                message: "Operation 'Load' cannot be active in terminal phase 'done'",
                needle: "Done.self"
            ),
            Case(
                name: "an operation active in a terminal phase through its scope",
                source: Self.variant(Self.operations, "@Active(in: [Busy.self]) case work", "case work"),
                message: "Operation 'Load' cannot be active in terminal phase 'done', because its scope 'work'",
                needle: "Scope.work)"
            ),
            Case(
                name: "a terminal phase's outgoing edge",
                source: Self.variant(Self.edges, "case busy(Busy)", "@Terminal case busy(Busy)"),
                message: "Terminal phase 'busy' cannot have an outgoing transition 'stop'",
                needle: "_ source: Busy"
            ),
            Case(
                name: "a terminal phase's outgoing edge listed in from:",
                source: Self.variant(
                    Self.variant(Self.edges, "case busy(Busy)", "@Terminal case busy(Busy)"),
                    "@Transition(on: Input.stop)\n    static func stop(_ source: Busy) -> Idle",
                    "@Transition(on: Input.stop, from: [Idle.self, Busy.self])\n    static func stop() -> Idle"
                ),
                message: "Terminal phase 'busy' cannot have an outgoing transition 'stop'",
                needle: "Busy.self"
            ),
            Case(
                name: "an unreachable phase",
                source: Self.variant(
                    Self.edges,
                    "case busy(Busy)",
                    "case busy(Busy)\n    struct Lost {}\n    case lost(Lost)\n    @Transition(on: Input.go)\n    static func found(_ source: Lost) -> Idle { Idle() }"
                ),
                message: "Phase 'lost' is unreachable from the initial phase 'idle'",
                needle: "lost(Lost)"
            ),
            Case(
                name: "a phase without an exit",
                source: Self.variant(
                    Self.edges,
                    "case busy(Busy)",
                    "case busy(Busy)\n    struct Stuck {}\n    case stuck(Stuck)\n    @Transition(on: Input.stop)\n    static func jam(_ source: Idle) -> Stuck { Stuck() }"
                ),
                message: "Phase 'stuck' has no outgoing transitions",
                needle: "stuck(Stuck)"
            ),
            Case(
                name: "an operation that can never run",
                source: Self.variant(
                    Self.variant(
                        Self.operations,
                        "@Active(in: [Busy.self]) case work",
                        "@Active(in: [Busy.self]) case work\n        @Active(in: [Idle.self]) case other"
                    ),
                    "@Operation(scope: Scope.work)",
                    "@Operation(scope: Scope.work, requires: [Scope.other])"
                ),
                message: "Operation 'Load' can never run",
                needle: "Load {"
            ),
            Case(
                name: "a phase whose payload is not a nested nominal type",
                source: Self.variant(Self.edges, "case busy(Busy)", "case busy(Int)"),
                message: "Phase 'busy' needs a distinct nongeneric struct or enum",
                needle: "Int)"
            ),
            Case(
                name: "two phases of one payload",
                source: Self.variant(Self.edges, "case busy(Busy)", "case busy(Busy)\n    case also(Busy)"),
                message: "Declare at least one phase, with a different nested nominal payload type for every phase.",
                needle: "Busy)",
                occurrence: 2
            ),
            Case(
                name: "an undeclared scope",
                source: Self.variant(Self.operations, "@Operation(scope: Scope.work)", "@Operation(scope: Scope.rest)"),
                message: "Operation metadata must reference declared Scope cases",
                needle: "Scope.rest"
            ),
            Case(
                name: "a required scope that is the primary one",
                source: Self.variant(
                    Self.operations,
                    "@Operation(scope: Scope.work)",
                    "@Operation(scope: Scope.work, requires: [Scope.work])"
                ),
                message: "Operation metadata must reference declared Scope cases",
                needle: "Scope.work])"
            ),
            Case(
                name: "an empty activeIn:",
                source: Self.variant(Self.operations, "@Operation(scope: Scope.work)", "@Operation(activeIn: [])"),
                message: "Operation metadata must reference declared Scope cases",
                needle: "[])"
            ),
            Case(
                name: "a completion edge outside the operation's phases",
                source: Self.variant(
                    Self.operations,
                    "static func loaded(_ source: Busy, _ value: Int) -> Done { Done() }",
                    "static func loaded(_ source: Busy, _ value: Int) -> Done { Done() }\n    @Transition(onSuccess: Load.self)\n    static func early(_ source: Idle, _ value: Int) -> Done { Done() }"
                ),
                message: "Completion edges must start in an operation's activeIn phase.",
                needle: "Idle, _ value"
            ),
            Case(
                name: "a phase without the operation's success edge",
                source: Self.variant(
                    Self.operations,
                    "@Active(in: [Busy.self]) case work",
                    "@Active(in: [Busy.self, Idle.self]) case work"
                ),
                message: "Operation 'Load' needs a success edge or router in active phase case 'idle'.",
                needle: "Load {"
            ),
            Case(
                name: "two edges of one source and trigger",
                source: Self.variant(
                    Self.edges,
                    "    @Transition(on: Input.stop)",
                    "    @Transition(on: Input.go)\n    static func again(_ source: Idle) -> Idle { Idle() }\n    @Transition(on: Input.stop)"
                ),
                message: "Ambiguous routing from 'Idle' for on: Input.go",
                needle: "again("
            ),
            Case(
                name: "an undeclared scope in invalidates:",
                source: Self.variant(
                    Self.operations,
                    "@Transition(onSuccess: Load.self)",
                    "@Transition(onSuccess: Load.self, invalidates: [Scope.work, Scope.rest])"
                ),
                message: "invalidates must reference declared Scope cases.",
                needle: "Scope.rest"
            ),
            Case(
                name: "two triggers",
                source: Self.variant(
                    Self.edges,
                    "@Transition(on: Input.go)",
                    "@Transition(on: Input.go, onSuccess: Busy.self)"
                ),
                message: "Name exactly one trigger",
                needle: "onSuccess: Busy.self"
            ),
        ]
        for refusal in cases { Self.expect(refusal) }
    }

    /// The refusals of a declaration's shape that stand at the token that makes it so.
    @Test func declarationRefusalsStandAtTheOffendingToken() {
        let cases: [Case] = [
            Case(
                name: "a generic schema",
                source: Self.variant(Self.edges, "enum Flow {", "enum Flow<T> {"),
                message: "Generic schemas are unsupported",
                needle: "<T>"
            ),
            Case(
                name: "a generic Input",
                source: Self.variant(Self.edges, "enum Input {", "enum Input<T> {"),
                message: "Input and Scope must be nongeneric closed enums.",
                needle: "<T>"
            ),
            Case(
                name: "a mode that is not one",
                source: Self.variant(Self.edges, "mode: .shared", "mode: .other"),
                message: "Mode must be .shared, .isolated, or .ownedOnly.",
                needle: ".other"
            ),
            Case(
                name: "a second @Initial",
                source: Self.variant(Self.edges, "case busy(Busy)", "@Initial case busy(Busy)"),
                message: "Mark exactly one phase case with @Initial.",
                needle: "@Initial",
                occurrence: 2
            ),
            Case(
                name: "no @Initial",
                source: Self.variant(Self.edges, "@Initial case idle(Idle)", "case idle(Idle)"),
                message: "Mark exactly one phase case with @Initial.",
                needle: "Flow {"
            ),
            Case(
                name: "@Initial with arguments",
                source: Self.variant(Self.edges, "@Initial case idle(Idle)", "@Initial(1) case idle(Idle)"),
                message: "@Initial takes no arguments",
                needle: "1) case idle"
            ),
            Case(
                name: "a marker applied twice",
                source: Self.variant(Self.edges, "@Initial case idle(Idle)", "@Initial @Initial case idle(Idle)"),
                message: "Apply @Initial only once to a declaration.",
                needle: "@Initial case idle"
            ),
            Case(
                name: "no Input",
                source: Self.variant(Self.edges, "enum Input { case go, stop }", ""),
                message: "Declare a closed Input enum directly inside the schema",
                needle: "Flow {"
            ),
            Case(
                name: "a repeated case",
                source: Self.variant(Self.edges, "enum Input { case go, stop }", "enum Input { case go, stop, go }"),
                message: "Case names must be unique",
                needle: "go }"
            ),
            Case(
                name: "a phase without a payload",
                source: Self.variant(Self.edges, "case busy(Busy)", "case busy"),
                message: "Each phase case requires exactly one unlabeled payload.",
                needle: "busy\n"
            ),
            Case(
                name: "an input with two payloads",
                source: Self.variant(Self.edges, "case go, stop", "case go(Int, Int), stop"),
                message: "Each Input case accepts zero or one unlabeled payload.",
                needle: "(Int, Int)"
            ),
            Case(
                name: "a labeled payload",
                source: Self.variant(Self.edges, "case go, stop", "case go(count: Int), stop"),
                message: "Use an unlabeled payload without a default value.",
                needle: "count:"
            ),
            Case(
                name: "a payload default outside the initial case",
                source: Self.variant(Self.edges, "case go, stop", "case go(Int = 1), stop"),
                message: "Use an unlabeled payload without a default value.",
                needle: "= 1"
            ),
            Case(
                name: "an input that carries Never",
                source: Self.variant(Self.edges, "case go, stop", "case go(Swift::Never), stop"),
                message: "Input case 'go' carries Never",
                needle: "Swift::Never)"
            ),
            Case(
                name: "@Active on two cases",
                source: Self.variant(
                    Self.operations,
                    "@Active(in: [Busy.self]) case work",
                    "@Active(in: [Busy.self]) case work, rest"
                ),
                message: "@Active(in:) must mark a declaration of one Scope case.",
                needle: "rest"
            ),
            Case(
                name: "an operation that is also an event",
                source: Self.variant(
                    Self.operations,
                    "@Operation(scope: Scope.work)",
                    "@Operation(scope: Scope.work) @Event"
                ),
                message: "A namespace cannot be both an @Operation and an @Event.",
                needle: "@Event"
            ),
            Case(
                name: "a generic operation",
                source: Self.variant(Self.operations, "enum Load {", "enum Load<T> {"),
                message: "Operation namespaces must be nongeneric enums.",
                needle: "<T>"
            ),
            Case(
                name: "an alias an operation does not declare",
                source: Self.variant(
                    Self.operations,
                    "typealias Output = Swift::Int",
                    "typealias Output = Swift::Int; typealias Extra = Int"
                ),
                message: "An operation declares only nongeneric Input, Output, Failure, and Key typealiases",
                needle: "Extra"
            ),
            Case(
                name: "an alias an operation declares twice",
                source: Self.variant(
                    Self.operations,
                    "typealias Output = Swift::Int",
                    "typealias Output = Swift::Int; typealias Output = Swift::Int"
                ),
                message: "An operation declares only nongeneric Input, Output, Failure, and Key typealiases",
                needle: "Output = Swift::Int",
                occurrence: 2
            ),
            Case(
                name: "a generic operation alias",
                source: Self.variant(
                    Self.operations,
                    "typealias Output = Swift::Int",
                    "typealias Output<T> = Swift::Int"
                ),
                message: "An operation declares only nongeneric Input, Output, Failure, and Key typealiases",
                needle: "<T>"
            ),
            Case(
                name: "a key of Never",
                source: Self.variant(
                    Self.operations,
                    "typealias Output = Swift::Int",
                    "typealias Output = Swift::Int; typealias Key = Swift::Never"
                ),
                message: "Operation 'Load' takes Never as its key",
                needle: "Swift::Never"
            ),
            Case(
                name: "an alias an event does not declare",
                source: Self.variant(
                    Self.operations,
                    "@Transition(on: Input.go, starts: [Load.self])",
                    "@Event\n    enum Logged { typealias Value = Int }\n    @Transition(on: Input.go, starts: [Load.self], emits: [Logged.self])"
                ),
                message: "An event declares only a nongeneric Payload typealias",
                needle: "Value"
            ),
            Case(
                name: "an event that carries Never",
                source: Self.variant(
                    Self.operations,
                    "@Transition(on: Input.go, starts: [Load.self])",
                    "@Event\n    enum Logged { typealias Payload = Swift::Never }\n    @Transition(on: Input.go, starts: [Load.self], emits: [Logged.self])"
                ),
                message: "Event 'Logged' carries Never",
                needle: "Swift::Never"
            ),
            Case(
                name: "a schema shadowed by a member",
                source: Self.variant(Self.edges, "struct Busy {}", "struct Busy {}\n    struct Flow {}"),
                message: "The schema name is reserved or shadowed by a direct member",
                needle: "Flow {}"
            ),
            Case(
                name: "a reserved member name",
                source: Self.variant(Self.edges, "struct Busy {}", "struct Busy {}\n    struct Phase {}"),
                message: "'Phase' is reserved for generated members",
                needle: "Phase {}"
            ),
            Case(
                name: "both allows: and only:",
                source: Self.variant(
                    Self.restoring,
                    "@Restoration\n",
                    "@Restoration(allows: [Busy.self], only: [Idle.self])\n"
                ),
                message:
                    "Use only: to list every restorable phase, or allows: to add phases to the resting ones, not both.",
                needle: "only:"
            ),
            Case(
                name: "a restoration without a result",
                source: Self.variant(
                    Self.restoring,
                    "restore(_ saved: Saved) -> Restoration",
                    "restore(_ saved: Saved)"
                ),
                message: "A @Restoration function returns Restoration, the phase to restore.",
                needle: "(_ saved: Saved)"
            ),
            Case(
                name: "saved data taken inout",
                source: Self.variant(Self.restoring, "_ saved: Saved", "_ saved: inout Saved"),
                message: "Pass the saved data to a @Restoration function by value, not inout.",
                needle: "inout"
            ),
            Case(
                name: "an opaque parameter",
                source: Self.variant(
                    Self.variant(Self.edges, "case go, stop", "case go(Int), stop"),
                    "go(_ source: Idle)",
                    "go(_ source: Idle, _ value: some BinaryInteger)"
                ),
                message: "Take this payload as a concrete type",
                needle: "some"
            ),
            Case(
                name: "a payload taken as an autoclosure",
                source: Self.variant(
                    Self.variant(Self.edges, "case go, stop", "case go(Int), stop"),
                    "go(_ source: Idle)",
                    "go(_ source: Idle, _ value: @autoclosure () -> Int)"
                ),
                message: "Take this payload without '@autoclosure'",
                needle: "@autoclosure"
            ),
            Case(
                name: "an alias that names itself",
                source: Self.variant(
                    Self.variant(Self.edges, "case go, stop", "case go(Loop), stop"),
                    "struct Busy {}",
                    "struct Busy {}\n    private typealias Loop = [Loop]"
                ),
                message: "Type alias 'Loop' names itself",
                needle: "Loop = [Loop]"
            ),
        ]
        for refusal in cases { Self.expect(refusal) }
    }

    /// The schema attribute on a declaration other than an enum is refused at the keyword that declares it.
    @Test func aSchemaThatIsNotAnEnumIsRefusedAtItsKeyword() throws {
        let source = """
            @StateMachine(mode: .shared)
            public struct Flow {}
            """
        let syntax = Parser.parse(source: source)
        let declaration = try #require(syntax.statements.first?.item.as(StructDeclSyntax.self))
        let attribute = try #require(declaration.attributes.first?.as(AttributeSyntax.self))
        let converter = SourceLocationConverter(fileName: "Flow.swift", tree: syntax)
        do {
            _ = try StateMachineMacro.expansion(
                of: attribute,
                providingMembersOf: declaration,
                conformingTo: [],
                in: BasicMacroExpansionContext()
            )
            Issue.record("The struct was accepted")
        } catch let error as DiagnosticsError {
            let diagnostic = try #require(error.diagnostics.first)
            #expect(diagnostic.message == "@StateMachine requires an enum declaration")
            let location = diagnostic.location(converter: converter)
            #expect(location.line == 2 && location.column == 8)
        }
    }
}
