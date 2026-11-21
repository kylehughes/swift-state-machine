import StateMachine
import StateMachineExamples
import Testing

// Both renderers write every authored name so that the diagram language reads it as text: each phase is
// a node or state with an internal identifier, labeled with its name, which Mermaid entity-codes and
// Graphviz escapes, a Unicode scalar at a time.

/// Phase and edge names that the diagram languages reserve or that contain their syntax.
private let hostileNames = [
    "note", "end", "state", "direction", "classDef", "click", "default", "direction TB", "a\"b", "x:y",
    "a-->b", "back\\slash", "semi;colon", "hash#tag", "percent%%comment", "café", "日本", "Straße",
    "two\nlines", "[*]", "&amp;", "<b>", "{brace}", "quote\"\u{301}", "back\\\u{301}slash", "*", "p0", "p1",
    "entry", "x\u{5B0}", "carriage\r\nreturn", "lone\rreturn", "line\u{2028}separator",
]

/// A graph whose phases, edges, and name are the hostile names: each phase has an edge to the next,
/// the first is initial and the second restorable, and the last is terminal.
private func hostileGraph() -> StateMachineGraph {
    let phases = hostileNames.map { StateMachineGraph.Phase(id: $0, payload: "Void") }
    let edges = zip(hostileNames, hostileNames.dropFirst())
        .map { source, destination in
            StateMachineGraph.Edge(
                id: "\(source).\(destination)",
                name: destination,
                source: source,
                destination: destination,
                trigger: .direct,
                router: nil,
                starts: [],
                cancels: [],
                emits: [],
                invalidates: []
            )
        }
    return StateMachineGraph(
        name: "Hostile \"graph\" \\",
        mode: .shared,
        owners: [.owned],
        initial: hostileNames[0],
        terminal: [hostileNames[hostileNames.count - 1]],
        restorable: [hostileNames[1]],
        phases: phases,
        inputs: [],
        scopes: [],
        operations: [],
        events: [],
        edges: edges,
        routers: []
    )
}

/// Decodes the decimal entity codes of a Mermaid label, rejecting any other character that is not a
/// letter, a digit, or `_`.
private func decodeMermaidLabel(_ label: Substring) -> String? {
    var decoded = ""
    var scalars = label.unicodeScalars.makeIterator()
    while let scalar = scalars.next() {
        if scalar == "#" {
            var digits = ""
            while let digit = scalars.next(), digit != ";" {
                guard ("0" ... "9").contains(digit) else { return nil }
                digits.unicodeScalars.append(digit)
            }
            guard let value = UInt32(digits), let code = Unicode.Scalar(value) else { return nil }
            decoded.unicodeScalars.append(code)
        } else if scalar == "_" || scalar.properties.isAlphabetic || scalar.properties.numericType == .decimal {
            decoded.unicodeScalars.append(scalar)
        } else {
            return nil
        }
    }
    return decoded
}

/// Reads a DOT quoted string at the start of `text` as Graphviz does, then as its label renders it,
/// returning the rendered text and the rest of `text`.
private func readDOTString(_ text: Substring) -> (String, Substring)? {
    // Graphviz reads bytes, so this reads Unicode scalars, never grapheme clusters.
    let scalars = text.unicodeScalars
    guard scalars.first == "\"" else { return nil }
    var rendered = ""
    var index = scalars.index(after: scalars.startIndex)
    while index < scalars.endIndex {
        let scalar = scalars[index]
        if scalar == "\"" {
            return (rendered.replacingAmpersandEntity(), Substring(scalars[scalars.index(after: index)...]))
        }
        if scalar == "\\" {
            index = scalars.index(after: index)
            guard index < scalars.endIndex else { return nil }
            switch scalars[index] {
            case "n": rendered.unicodeScalars.append("\n")
            case let escaped: rendered.unicodeScalars.append(escaped)
            }
        } else {
            guard scalar != "\n", scalar != "\r" else { return nil }
            rendered.unicodeScalars.append(scalar)
        }
        index = scalars.index(after: index)
    }
    return nil
}

/// How DOT renders `name`: every line ending as one line break.
private func renderedLines(_ name: String) -> String {
    var rendered = ""
    var scalars = name.unicodeScalars.makeIterator()
    var pending = scalars.next()
    while let scalar = pending {
        pending = scalars.next()
        switch scalar {
        case "\r":
            if pending == "\n" { pending = scalars.next() }
            rendered.unicodeScalars.append("\n")
        case "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}": rendered.unicodeScalars.append("\n")
        default: rendered.unicodeScalars.append(scalar)
        }
    }
    return rendered
}

extension String {
    /// Replaces `&amp;`, the only entity the DOT renderer writes, with `&`.
    fileprivate func replacingAmpersandEntity() -> String {
        var result = ""
        var rest = self[...]
        while let range = rest.range(of: "&amp;") {
            result += rest[..<range.lowerBound] + "&"
            rest = rest[range.upperBound...]
        }
        return result + rest
    }
}

@Suite struct GraphRenderingTests {
    // A phase named `note` would start a Mermaid note statement; as a label of an internal state it is
    // only text.
    @Test func mermaidNamesEveryPhaseThroughAnInternalState() {
        let graph = StateMachineGraph(
            name: "Approval",
            mode: .shared,
            owners: [.owned],
            initial: "note",
            terminal: ["approved"],
            restorable: [],
            phases: [.init(id: "note", payload: "Draft"), .init(id: "approved", payload: "Void")],
            inputs: [],
            scopes: [],
            operations: [],
            events: [],
            edges: [
                .init(
                    id: "note.approve",
                    name: "approve",
                    source: "note",
                    destination: "approved",
                    trigger: .direct,
                    router: nil,
                    starts: [],
                    cancels: [],
                    emits: [],
                    invalidates: []
                )
            ],
            routers: []
        )
        #expect(
            graph.mermaid() == """
                stateDiagram-v2
                    state "note" as p0
                    state "approved" as p1
                    [*] --> p0
                    p0 --> p1 : approve
                    p1 --> [*]

                """
        )
    }

    // The export guide shows this rendering of the profile example.
    @Test func mermaidRendersTheProfileExampleAsTheGuideShows() {
        #expect(
            GeneratedProfile.graph.mermaid() == """
                stateDiagram-v2
                    state "idle" as p0
                    state "loading" as p1
                    state "loaded" as p2
                    state "failed" as p3
                    [*] --> p0
                    [*] --> p2 : restored
                    [*] --> p3 : restored
                    p0 --> p1 : begin
                    p1 --> p0 : cancel
                    p1 --> p2 : received
                    p1 --> p3 : failed
                    p1 --> p1 : authenticationChanged
                    p2 --> p1 : refresh
                    p3 --> p1 : retry
                    p1 --> p1 : audit
                    p1 --> p1 : audited
                    p1 --> p1 : auditFailed

                """
        )
    }

    // Every Mermaid line is a state declaration, an entrance, an edge, or an exit over internal state
    // names, and each label holds only letters, digits, `_`, and entity codes, which decode to the name.
    @Test func mermaidLabelsDecodeToEveryHostileName() throws {
        let lines = hostileGraph().mermaid().split(separator: "\n")
        #expect(lines.first == "stateDiagram-v2")
        var labels: [String] = []
        var edgeLabels: [String] = []
        for line in lines.dropFirst() {
            if line.hasPrefix("    state \""), let close = line.dropFirst(11).firstIndex(of: "\"") {
                let label = line[line.index(line.startIndex, offsetBy: 11) ..< close]
                labels.append(try #require(decodeMermaidLabel(label)))
                #expect(line[close...].dropFirst().hasPrefix(" as p"))
                continue
            }
            let parts = line.split(separator: " : ", maxSplits: 1)
            let transition = parts[0].split(separator: " ")
            #expect(transition.count == 3 && transition[1] == "-->", "\(line)")
            for state in [transition[0], transition[2]] {
                #expect(state == "[*]" || (state.first == "p" && state.dropFirst().allSatisfy(\.isNumber)), "\(line)")
            }
            if parts.count == 2 { edgeLabels.append(try #require(decodeMermaidLabel(parts[1]), "\(line)")) }
        }
        #expect(labels == hostileNames)
        #expect(edgeLabels == ["restored"] + hostileNames.dropFirst())
    }

    // Every phase is a node with an internal identifier, labeled with one quoted string that Graphviz
    // reads and renders as the name itself, so a reserved word, a quotation mark or a backslash with a
    // combining scalar attached, a line ending, an entity, and a name equal to `*`, to the entry point's
    // identifier, or to another phase's identifier stay text.
    @Test func dotStringsRenderEveryHostileName() throws {
        let graph = hostileGraph()
        let lines = graph.dot().split(separator: "\n", omittingEmptySubsequences: false)
        let header = try #require(lines.first)
        #expect(header.hasPrefix("digraph "))
        let (name, afterName) = try #require(readDOTString(header.dropFirst(8)))
        #expect(name == graph.name)
        #expect(afterName == " {")
        #expect(lines[1] == "    entry [shape=point];")
        var labels: [String: String] = [:]
        var declared: [String] = []
        var terminal: [String] = []
        var edges: [(String, String, String)] = []
        for line in lines.dropFirst(2).dropLast(2) {
            let body = line.dropFirst(4)
            let identifier = String(body.prefix { $0 != " " && $0 != ";" })
            let rest = body.dropFirst(identifier.count)
            if rest.hasPrefix(" -> ") {
                let target = rest.dropFirst(4)
                let destination = String(target.prefix { $0 != " " && $0 != ";" })
                let attributes = target.dropFirst(destination.count)
                guard attributes.hasPrefix(" [label=") else {
                    #expect(attributes == ";")
                    edges.append((identifier, destination, ""))
                    continue
                }
                let (label, _) = try #require(readDOTString(attributes.dropFirst(8)), "\(line)")
                edges.append((identifier, destination, label))
            } else {
                #expect(identifier.wholeMatch(of: /p[0-9]+/) != nil, "\(line)")
                #expect(rest.hasPrefix(" [label="), "\(line)")
                let (label, after) = try #require(readDOTString(rest.dropFirst(8)), "\(line)")
                #expect(after == "];" || after == ", peripheries=2];", "\(line)")
                if after != "];" { terminal.append(label) }
                #expect(labels[identifier] == nil)
                labels[identifier] = label
                declared.append(label)
            }
        }
        let rendered = hostileNames.map(renderedLines)
        #expect(declared == rendered)
        #expect(Set(labels.keys).count == hostileNames.count)
        #expect(terminal == [rendered[rendered.count - 1]])
        let named = edges.filter { $0.0 != "entry" }
        #expect(named.map(\.2) == Array(rendered.dropFirst()))
        #expect(named.map { labels[$0.0] } == Array(rendered.dropLast()))
        #expect(named.map { labels[$0.1] } == Array(rendered.dropFirst()))
        #expect(edges.filter { $0.0 == "entry" }.map { labels[$0.1] } == Array(rendered.prefix(2)))
        #expect(!labels.keys.contains("entry"))
    }

    // Rendering a graph with many terminal phases finds each phase's outline in a set built once, and
    // keeps declaration order.
    @Test func dotOutlinesEveryTerminalPhaseInDeclarationOrder() {
        let names = (0 ..< 2_000).map { "t\($0)" }
        let graph = StateMachineGraph(
            name: "Terminals",
            mode: .shared,
            owners: [.owned],
            initial: names[0],
            terminal: names,
            restorable: [],
            phases: names.map { StateMachineGraph.Phase(id: $0, payload: "Void") },
            inputs: [],
            scopes: [],
            operations: [],
            events: [],
            edges: [],
            routers: []
        )
        let lines = graph.dot().split(separator: "\n")
        let outlined = lines.filter { $0.hasSuffix(", peripheries=2];") }
        #expect(outlined.count == names.count)
        #expect(outlined.first == "    p0 [label=\"t0\", peripheries=2];")
        #expect(outlined.last == "    p1999 [label=\"t1999\", peripheries=2];")
    }

    // An alphabetic combining scalar stays a letter in a Mermaid label and is written as itself in DOT.
    @Test func anAlphabeticCombiningScalarStaysText() {
        let graph = hostileGraph()
        #expect(graph.mermaid().contains("state \"x\u{5B0}\" as "))
        #expect(graph.dot().unicodeScalars.contains("\u{5B0}"))
    }
}
