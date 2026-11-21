# Exporting a graph

Read a schema's declared structure as data, and render it as a Mermaid or Graphviz diagram.

Every schema generates a static `graph`, a ``StateMachineGraph`` that describes
exactly the declarations the macro read: its data mode and the owners it
generates, its phases, inputs, named scopes, operations, events, edges, and
routers, in declaration order, with its initial, terminal, and restorable
phases. It holds names and type spellings, never a payload, a ticket, an
observation, or a reference to an owner, so it grants no authority. It is
`Sendable`, `Hashable`, and `Codable`, so it can be compared, encoded, and
rendered anywhere.

The encoded form records ``StateMachineGraph/formatVersion``, which is
``StateMachineGraph/currentFormatVersion`` for every graph the package creates.
Decoding a graph of another version throws `DecodingError.dataCorrupted`, so a
tool that persists graphs never misreads one that another version of the
package wrote. The mode and owners encode as their case names, such as
`"shared"` and `["local", "mainActorHost"]`.

## Render a diagram

`mermaid()` renders the phases and edges as a Mermaid `stateDiagram-v2`, and
`dot()` as a Graphviz `digraph`. Both follow declaration order, so equal graphs
render identical text, and a rendered diagram checked into a repository shows
every structural change in review:

```swift
import StateMachine

func printDiagrams() {
    print(GeneratedProfile.graph.mermaid())
    print(GeneratedProfile.graph.dot())
}
```

`GeneratedProfile` is the profile workflow in the repository's
`Sources/StateMachineExamples`. It loads a profile in `loading`, cancels back
to `idle`, ends a load in `loaded` or `failed`, and retries or refreshes from
those. Its `@Restoration` function can restore `idle`, `loaded`, and `failed`.
`mermaid()` returns:

```text
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
```

Each phase is a Mermaid state named `p0`, `p1`, and so on in declaration order
and labeled with the phase's name, so no name is read as Mermaid syntax, even a
phase named `note` or `end`, words that the diagram language reserves. A label
keeps letters, digits, and `_` and writes every other character as a Mermaid
entity code, such as `#32;` for a space, which Mermaid renders as the character.
The diagram enters the initial phase from `[*]`, enters each other restorable
phase from `[*]` with the label `restored`, labels each edge with its function's
name, and leaves each terminal phase to `[*]`. `GeneratedProfile` has no
terminal phase, because `loaded` and `failed` each have an edge out.

`dot()` returns the same structure for Graphviz. Each phase is a node named
`p0`, `p1`, and so on in declaration order and labeled with the phase's name, so
no name is read as DOT syntax or meets the entry point, a point node named
`entry`, which enters the initial phase, and with a dashed edge labeled
`restored` each other restorable phase. Terminal phases have a double outline,
and each edge is labeled with its function's name. A label escapes a quotation
mark, a backslash, and `&`, one Unicode scalar at a time, and writes every line
ending as a line break, so each renders as itself:

```text
digraph "GeneratedProfile" {
    entry [shape=point];
    p0 [label="idle"];
    p1 [label="loading"];
    p2 [label="loaded"];
    p3 [label="failed"];
    entry -> p0;
    entry -> p2 [label="restored", style=dashed];
    entry -> p3 [label="restored", style=dashed];
    p0 -> p1 [label="begin"];
    p1 -> p0 [label="cancel"];
    p1 -> p2 [label="received"];
    p1 -> p3 [label="failed"];
    p1 -> p1 [label="authenticationChanged"];
    p2 -> p1 [label="refresh"];
    p3 -> p1 [label="retry"];
    p1 -> p1 [label="audit"];
    p1 -> p1 [label="audited"];
    p1 -> p1 [label="auditFailed"];
}
```

Pipe it to `dot -Tsvg` to draw an image, or paste the Mermaid text into any
Markdown renderer that supports Mermaid.

## Read the structure

Identifiers are the names an author writes. A phase is identified by its case
name, an input by its case name, a scope by its `Scope` case name, and an
operation or event by its namespace name. An edge or router is identified by its
source phase and name, `"<phase>.<name>"`, so edges of one name that leave
different phases stay distinct, and an edge declared with
`@Transition(from:on:)` appears once per source phase. Each
``StateMachineGraph/Edge`` records its trigger, the router that chooses it, and
the operations it starts and cancels, the events it emits, and the scopes it
invalidates. Each ``StateMachineGraph/Operation`` records its scope, the phases
where it may run, its admission policy, and its key, input, output, and failure
type spellings, so an alias keeps its own name.
``StateMachineGraph/Operation/canFail`` and
``StateMachineGraph/Operation/canSucceed`` report whether each outcome can
happen, as the macro reads the `Failure` and `Output` through the schema's own
declarations; read them rather than interpreting a spelling.

Each type spelling is the author's text: the tokens of the type as written, in
order, with one space wherever whitespace, a line break, or a comment separated
two of them, and nothing else. `@Initial case draft(Self.Draft)` exports
`Self.Draft`, and `case run((@Sendable () -> Int))` exports
`(@Sendable () -> Int)`. A spelling means what it means where it was written: a
phase's payload inside the schema, an input case's payload inside `Input`, and
an operation's or event's types inside its namespace. A type the namespace omits is spelled through the standard
library's module, `Swift::Void` or `Swift::Never`, which no declaration shadows.

```swift
func describe(_ graph: StateMachineGraph) {
    for edge in graph.edges where !edge.starts.isEmpty {
        print("\(edge.id) starts \(edge.starts.joined(separator: ", "))")
    }
    for operation in graph.operations {
        print("\(operation.id) runs in \(operation.activeIn), admitting \(operation.admission)")
        if operation.canFail { print("\(operation.id) can fail with \(operation.failure)") }
    }
}
```

A path in the graph shows only that an edge is declared. Whether it is taken
depends on the authored functions, which may throw, choose another edge, or
return no effects. The macro's graph checks read the same structure, as
[Satisfy the graph checks](<doc:DeclaringAGraph#Satisfy-the-graph-checks>)
describes, and `GraphCoverage` in `StateMachineTesting` compares it with the
edges that tests actually took.
