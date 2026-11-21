/// The declared structure of a `@StateMachine` graph: its phases, inputs, scopes, operations, events,
/// edges, and routers.
///
/// A schema's generated `graph` describes exactly the declarations the macro read, in declaration
/// order. It is inert metadata: it holds names and type spellings, never a payload, a ticket, an
/// observation, or a reference to an owner, so it grants no authority and can be encoded, compared,
/// and rendered anywhere.
///
/// Identifiers are the names an author writes. A phase is identified by its case name, an input by its
/// case name, a scope by its `Scope` case name, and an operation or event by its namespace name. An edge
/// or router is identified by its source phase and name, `"<phase>.<name>"`, so edges of one name that
/// leave different phases stay distinct.
///
/// Each type spelling is the author's text: the type's tokens as written, in order, with one space
/// wherever whitespace, a line break, or a comment separated two of them, and nothing else, so
/// `Self.Draft` and `(@Sendable () -> Int)` are kept as written. It means what it means where it was
/// written: a phase's payload inside the schema, an input case's payload inside `Input`, and an
/// operation's or event's types inside its namespace. A type the namespace omits is spelled
/// through the standard library's module, `Swift::Void` or `Swift::Never`, which no declaration shadows.
///
/// A path in the graph shows only that an edge is declared. Whether it is taken depends on the authored
/// functions, which may throw, choose another edge, or return no effects.
///
/// The encoded form records ``formatVersion``. Decoding a graph of another version throws, so a tool
/// that persists graphs never misreads one written by another version of the package.
nonisolated public struct StateMachineGraph: Sendable, Hashable, Codable {
    /// The version of the encoded form that this package writes and reads.
    public static let currentFormatVersion = 2
    /// One declared phase.
    public struct Phase: Sendable, Hashable, Codable, Identifiable {
        /// The phase case name.
        public let id: String
        /// The spelling of the phase's payload type, which means what it means inside the schema.
        public let payload: String

        /// Describes a phase.
        public init(id: String, payload: String) {
            self.id = id
            self.payload = payload
        }
    }

    /// One case of the schema's `Input`.
    public struct Input: Sendable, Hashable, Codable, Identifiable {
        /// The input case name.
        public let id: String
        /// The spelling of the case's payload type, which means what it means inside `Input`, or `nil`
        /// when the case carries none.
        public let payload: String?

        /// Describes an input.
        public init(id: String, payload: String?) {
            self.id = id
            self.payload = payload
        }
    }

    /// One case of the schema's `Scope`.
    public struct Scope: Sendable, Hashable, Codable, Identifiable {
        /// The scope case name.
        public let id: String
        /// The phases in which the scope's authority stays valid.
        public let activeIn: [String]

        /// Describes a scope.
        public init(id: String, activeIn: [String]) {
            self.id = id
            self.activeIn = activeIn
        }
    }

    /// One `@Operation` namespace.
    public struct Operation: Sendable, Hashable, Codable, Identifiable {
        /// The operation namespace name.
        public let id: String
        /// The `Effect` case that requests it.
        public let effect: String
        /// The named primary scope, or `nil` when the operation holds a private scope.
        public let scope: String?
        /// The additional scopes the operation depends on.
        public let requires: [String]
        /// The phases in which the operation may run: those of its primary scope and every required scope.
        public let activeIn: [String]
        /// The admission policy for concurrent work, which applies to each key of a keyed operation.
        public let admission: StateMachineAdmission
        /// The spelling of the key type of a keyed operation, which means what it means inside the
        /// namespace, or `nil` when the operation is unkeyed.
        public let key: String?
        /// Whether the operation's work is keyed, so admission applies its policy to each key.
        public var isKeyed: Bool { key != nil }
        /// The spelling of the input type, which means what it means inside the namespace, or
        /// `Swift::Void` when the namespace omits it.
        public let input: String
        /// The spelling of the output type, which means what it means inside the namespace, or
        /// `Swift::Void` when the namespace omits it.
        public let output: String
        /// The spelling of the failure type, which means what it means inside the namespace, or
        /// `Swift::Never` when the namespace omits it.
        ///
        /// The spelling is the author's, so an alias keeps its name; ``canFail`` reports whether it names
        /// the standard library's `Never`.
        public let failure: String
        /// Whether the operation can fail, so its failure needs an edge or router: its `Failure` names
        /// a type other than the standard library's `Never`, as the macro reads it.
        public let canFail: Bool
        /// Whether the operation can succeed, so its success needs an edge or router: its `Output` names
        /// a type other than the standard library's `Never`, as the macro reads it.
        public let canSucceed: Bool

        /// Describes an operation.
        public init(
            id: String,
            effect: String,
            scope: String?,
            requires: [String],
            activeIn: [String],
            admission: StateMachineAdmission,
            key: String?,
            input: String,
            output: String,
            failure: String,
            canFail: Bool,
            canSucceed: Bool
        ) {
            self.id = id
            self.effect = effect
            self.scope = scope
            self.requires = requires
            self.activeIn = activeIn
            self.admission = admission
            self.key = key
            self.input = input
            self.output = output
            self.failure = failure
            self.canFail = canFail
            self.canSucceed = canSucceed
        }
    }

    /// One `@Event` namespace.
    public struct Event: Sendable, Hashable, Codable, Identifiable {
        /// The event namespace name.
        public let id: String
        /// The `Effect` case that carries it.
        public let effect: String
        /// The spelling of the payload type, which means what it means inside the namespace, or
        /// `Swift::Void` when the namespace omits it.
        public let payload: String

        /// Describes an event.
        public init(id: String, effect: String, payload: String) {
            self.id = id
            self.effect = effect
            self.payload = payload
        }
    }

    /// What takes an edge or router.
    public enum Trigger: Sendable, Hashable, Codable {
        /// An input case, by name.
        case input(String)
        /// An operation's success, by operation name.
        case success(String)
        /// An operation's failure, by operation name.
        case failure(String)
        /// A direct call on an owned phase, in an `.ownedOnly` schema.
        case direct
    }

    /// One declared transition from one source phase.
    public struct Edge: Sendable, Hashable, Codable, Identifiable {
        /// The source phase and edge name, `"<phase>.<name>"`.
        public let id: String
        /// The authored function name.
        public let name: String
        /// The source phase.
        public let source: String
        /// The destination phase.
        public let destination: String
        /// What takes the edge.
        public let trigger: Trigger
        /// The identifier of the router that chooses this edge, when one does.
        public let router: String?
        /// The operations the edge may start.
        public let starts: [String]
        /// The keyed operations whose work the edge may cancel, by key or entirely.
        public let cancels: [String]
        /// The events the edge may emit.
        public let emits: [String]
        /// The scopes whose authority the edge revokes.
        public let invalidates: [String]

        /// Describes an edge.
        public init(
            id: String,
            name: String,
            source: String,
            destination: String,
            trigger: Trigger,
            router: String?,
            starts: [String],
            cancels: [String],
            emits: [String],
            invalidates: [String]
        ) {
            self.id = id
            self.name = name
            self.source = source
            self.destination = destination
            self.trigger = trigger
            self.router = router
            self.starts = starts
            self.cancels = cancels
            self.emits = emits
            self.invalidates = invalidates
        }
    }

    /// One declared router.
    public struct Router: Sendable, Hashable, Codable, Identifiable {
        /// The source phase and router name, `"<phase>.<name>"`.
        public let id: String
        /// The authored function name.
        public let name: String
        /// The source phase.
        public let source: String
        /// What runs the router.
        public let trigger: Trigger
        /// The identifiers of the edges it may choose, in declaration order; empty when it always declines.
        public let candidates: [String]

        /// Describes a router.
        public init(id: String, name: String, source: String, trigger: Trigger, candidates: [String]) {
            self.id = id
            self.name = name
            self.source = source
            self.trigger = trigger
            self.candidates = candidates
        }
    }

    /// The version of the encoded form, ``currentFormatVersion`` for every graph this package creates.
    public let formatVersion: Int
    /// The schema name.
    public let name: String
    /// The data mode the schema declares.
    public let mode: StateMachineMode
    /// The owners the schema generates, in the order ``StateMachineOwner`` declares them.
    public let owners: [StateMachineOwner]
    /// The phase in which fresh authority is created.
    public let initial: String
    /// The phases marked `@Terminal`, in declaration order.
    public let terminal: [String]
    /// The phases saved data can restore through the schema's `@Restoration` function, in declaration
    /// order; empty when the schema declares none.
    public let restorable: [String]
    /// Every phase in declaration order.
    public let phases: [Phase]
    /// Every input case in declaration order.
    public let inputs: [Input]
    /// Every named scope in declaration order.
    public let scopes: [Scope]
    /// Every operation in declaration order.
    public let operations: [Operation]
    /// Every event in declaration order.
    public let events: [Event]
    /// Every edge in declaration order, one per source phase of each authored transition.
    public let edges: [Edge]
    /// Every router in declaration order.
    public let routers: [Router]

    /// Describes a graph in the current format.
    public init(
        name: String,
        mode: StateMachineMode,
        owners: [StateMachineOwner],
        initial: String,
        terminal: [String],
        restorable: [String],
        phases: [Phase],
        inputs: [Input],
        scopes: [Scope],
        operations: [Operation],
        events: [Event],
        edges: [Edge],
        routers: [Router]
    ) {
        formatVersion = Self.currentFormatVersion
        self.name = name
        self.mode = mode
        self.owners = owners
        self.initial = initial
        self.terminal = terminal
        self.restorable = restorable
        self.phases = phases
        self.inputs = inputs
        self.scopes = scopes
        self.operations = operations
        self.events = events
        self.edges = edges
        self.routers = routers
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, name, mode, owners, initial, terminal, restorable, phases, inputs, scopes, operations
        case events, edges, routers
    }

    /// Decodes a graph, throwing `DecodingError.dataCorrupted` for a format version other than
    /// ``currentFormatVersion``.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == Self.currentFormatVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription:
                    "Graph format version \(formatVersion) is not \(Self.currentFormatVersion), the version this package reads."
            )
        }
        name = try container.decode(String.self, forKey: .name)
        mode = try container.decode(StateMachineMode.self, forKey: .mode)
        owners = try container.decode([StateMachineOwner].self, forKey: .owners)
        initial = try container.decode(String.self, forKey: .initial)
        terminal = try container.decode([String].self, forKey: .terminal)
        restorable = try container.decode([String].self, forKey: .restorable)
        phases = try container.decode([Phase].self, forKey: .phases)
        inputs = try container.decode([Input].self, forKey: .inputs)
        scopes = try container.decode([Scope].self, forKey: .scopes)
        operations = try container.decode([Operation].self, forKey: .operations)
        events = try container.decode([Event].self, forKey: .events)
        edges = try container.decode([Edge].self, forKey: .edges)
        routers = try container.decode([Router].self, forKey: .routers)
    }

    /// Renders the phases and edges as a Mermaid `stateDiagram-v2`.
    ///
    /// Each phase is a state named `p0`, `p1`, and so on in declaration order, labeled with the phase's
    /// name, so no name is ever read as Mermaid syntax, even one such as `note` or `end` that the
    /// diagram language reserves. The diagram enters the initial phase from `[*]`, enters each other
    /// restorable phase from `[*]` with the label `restored`, labels each edge with its name, and leaves
    /// each terminal phase to `[*]`. A label keeps letters, digits, and `_`, and writes every other
    /// character as a Mermaid entity code, such as `#32;` for a space, which Mermaid renders as the
    /// character. Lines follow declaration order, so equal graphs render identical text.
    public func mermaid() -> String {
        let states = DiagramStates(self)
        var lines = ["stateDiagram-v2"]
        for (phase, state) in states.declared { lines.append("    state \"\(Self.mermaidLabel(phase))\" as \(state)") }
        lines.append("    [*] --> \(states[initial])")
        for phase in restorable where phase != initial { lines.append("    [*] --> \(states[phase]) : restored") }
        for edge in edges {
            lines.append("    \(states[edge.source]) --> \(states[edge.destination]) : \(Self.mermaidLabel(edge.name))")
        }
        for phase in terminal { lines.append("    \(states[phase]) --> [*]") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Renders the phases and edges as a Graphviz `digraph`.
    ///
    /// Each phase is a node named `p0`, `p1`, and so on in declaration order, labeled with the phase's
    /// name, so no name is ever read as DOT syntax or meets the entry point, a point node named `entry`,
    /// which enters the initial phase, and with a dashed edge labeled `restored` each other restorable
    /// phase. Terminal phases have a double outline, and each edge is labeled with its name. A label
    /// escapes a quotation mark, a backslash, and `&`, one Unicode scalar at a time, and writes every line
    /// ending as a line break, so each renders as itself. The graph's identifier, the graph's name, is
    /// not a label: it is a quoted DOT identifier, whose only escape is `\"`, so `R&D` stays `R&D` and a
    /// backslash stays a backslash. Lines follow declaration order, so equal graphs render identical text.
    public func dot() -> String {
        // Every phase is a node with an internal identifier, `p0`, `p1`, and so on, labeled with its
        // name, so no name can be read as DOT syntax or meet the entry point, whose identifier is
        // `entry`, which no phase's identifier can be.
        let states = DiagramStates(self)
        let terminals = Set(terminal)
        var lines = ["digraph \(Self.dotID(name)) {", "    entry [shape=point];"]
        for (phase, state) in states.declared {
            let outline = terminals.contains(phase) ? ", peripheries=2" : ""
            lines.append("    \(state) [label=\(Self.dotString(phase))\(outline)];")
        }
        lines.append("    entry -> \(states[initial]);")
        for phase in restorable where phase != initial {
            lines.append("    entry -> \(states[phase]) [label=\"restored\", style=dashed];")
        }
        for edge in edges {
            lines.append(
                "    \(states[edge.source]) -> \(states[edge.destination]) [label=\(Self.dotString(edge.name))];"
            )
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    /// A Mermaid label for `text`: letters, digits, and `_` as they are, and every other character as
    /// a decimal entity code, which Mermaid replaces before it reads the diagram and renders as the
    /// character.
    ///
    /// Mermaid's own placeholders for entity codes use `ß` and `ﬂ`, so those letters are encoded too.
    private static func mermaidLabel(_ text: String) -> String {
        var label = ""
        for scalar in text.unicodeScalars {
            let plain = scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType == .decimal
            if plain, scalar != "\u{DF}", scalar != "\u{FB02}" {
                label.unicodeScalars.append(scalar)
            } else {
                label += "#\(scalar.value);"
            }
        }
        return label
    }

    /// A quoted DOT identifier of `text`, which DOT reads as `text` itself.
    ///
    /// In a quoted identifier, `\"` is the only escape and a backslash followed by a line feed is a line
    /// continuation, which DOT removes; every other scalar, a backslash included, stands for itself, and
    /// entities and `\n` mean something only in a label. So each quotation mark is escaped, and a
    /// backslash that ends the text or precedes a line feed, which DOT would otherwise read as escaping
    /// the closing quotation mark or as a continuation, is followed by a continuation of its own.
    private static func dotID(_ text: String) -> String {
        var quoted = "\""
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\" where pending == nil || pending == "\n": quoted += "\\\\\n"
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }

    /// A quoted DOT string of `text`, which Graphviz reads, and renders as a label, as `text` itself.
    private static func dotString(_ text: String) -> String {
        // Each Unicode scalar is read on its own, so a quotation mark or a backslash that a combining
        // scalar follows is still escaped. Every line ending, a carriage return and line feed pair
        // included, becomes one escaped line break.
        var quoted = "\""
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "&": quoted += "&amp;"
            case "\r":
                if pending == "\n" { pending = scalars.next() }
                quoted += "\\n"
            case "\n", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}": quoted += "\\n"
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }
}

/// The Mermaid state of each phase a graph names: `p0`, `p1`, and so on, for its phases in declaration
/// order, then for any other name its edges and phase lists use, in the order they first appear.
nonisolated private struct DiagramStates {
    private(set) var declared: [(phase: String, state: String)] = []
    private var states: [String: String] = [:]

    init(_ graph: StateMachineGraph) {
        for phase in graph.phases { add(phase.id) }
        for phase in [graph.initial] + graph.restorable + graph.terminal { add(phase) }
        for edge in graph.edges {
            add(edge.source)
            add(edge.destination)
        }
    }
    private mutating func add(_ phase: String) {
        guard states[phase] == nil else { return }
        let state = "p\(declared.count)"
        states[phase] = state
        declared.append((phase, state))
    }
    subscript(phase: String) -> String { states[phase]! }
}
