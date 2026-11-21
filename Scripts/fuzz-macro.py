#!/usr/bin/env python3
"""Fuzz the @StateMachine macro with rewrites whose meaning Swift decides.

Each case applies rewrites to a valid seed schema and compiles it, alone, through the real macro plugin:

- An equivalence rewrite (parentheses, backticks, aliases, qualification, sugar, trivia, reordering, ...) must leave
  the program's meaning alone: the case compiles, its generated declarations have the same canonical signatures
  (demangled object symbols), its exported graph has the same structure, and it prints what the seed prints. A
  macro diagnostic or a difference passes only when LIMITS, the table of documented limits below, lists it.
- A distinction rewrite renames one declaration so that it collides with another in a normal form the macro might
  use (canonical Unicode equivalence, case, a raw identifier against a path, a confusable letter). Swift reads two
  names, so the case must behave as the seed with that declaration renamed. The guide requires the macro to refuse a
  schema name that is not in Unicode NFC, so such a name must get that diagnostic; accepting it fails as `policy`.
- A breaking rewrite makes the schema invalid under the documented grammar while it stays valid Swift; the macro or
  the compiler must reject it with the documented diagnostic (BREAK_EXPECT) at the site the rewrite changed.
- An unsupported rewrite writes valid Swift the guide calls unsupported (async edges, untyped throws, `inout` sources,
  generic functions, generic enclosing types); the macro itself must diagnose it.
- A variation rewrite changes the program in a way Swift accepts (closure conventions, default isolation, `-O`); the
  case must compile. A safe rewrite writes valid Swift the guide neither supports nor rules out (access levels,
  attributes, a schema in a function body); the case must compile or get a macro diagnostic, never invalid generated
  code.

Each case compiles as the module `Fz`; a harness module that imports it prints every graph, its Mermaid and DOT
renderings, and the seed's report, and a seed's client section compiles in that module, so it sees the schema as
another module does. Beside the comparison above, every compiled case must: link and run to completion; export type
spellings that, compiled exactly as exported in the scope the guide says each is meant in, name the authored types;
render both diagrams so that a strict reader of the subset the library writes reads back exactly its graph; and take
initializer driver and handler labels in its own declaration order. Every seed must pass all of this on its own, and a
domain seed must print the report EXPECTED_REPORTS pins. Every compilation runs under a watchdog that kills its process
tree past `--memory-cap-mb` or `--timeout`, which fails the case. `--self-test` plants a defect for each of these
oracles and checks that each is reported.

--cost compares scaled schemas spelled a base way and rewritten ways: the same outcome at the same size, the macro's
own time within a constant factor, and near-linear growth from the smaller size to the larger.

Every case is compiled in its own process, so one variant's error cannot hide another's. A crash or a timeout of the
plugin or compiler always fails. Failing cases are written to OUTPUT/failures/ as self-contained sources with a
one-line description, after removing the rewrites the failure does not need.
"""
import argparse
import collections
import concurrent.futures
import hashlib
import json
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys
import time
import unicodedata

ROOT = pathlib.Path(os.path.abspath(__file__)).parents[1]
DOC = ROOT / 'Documentation/StateMachine.docc/DeclaringAGraph.md'

# ---------------------------------------------------------------------------------------------------------------------
# Documented limits. A case that the macro diagnoses, or whose generated signatures differ from its seed's, passes only
# when an entry here names its rewrite, what was observed, and a pattern of the message or difference. `doc` quotes the
# sentence of DeclaringAGraph.md that documents the limit; the run checks that the sentence is still there.

#
# A macro diagnostic meets an entry only when its message matches `pattern` and it stands where the case changed the
# schema: on a line a rewrite changed, or on a line that declares a name the message quotes. An entry marked `exact`
# is a refusal a rewrite must meet: the case passes only with that diagnostic, and only when no other diagnostic or
# error accompanies it, other than the generated names the refused expansion leaves undeclared (CASCADE).

LIMITS = [
    dict(id='phase-alias', rewrites=r'^alias-', observed='macro-diagnostic', role='phase',
         pattern=r"Phase '[^']*' needs a distinct nongeneric struct or enum declared directly inside the schema, named with a Swift identifier that needs no backticks; aliases are unsupported|"
                 r"^(Source |Destination )?'[^']*' is not a phase payload type declared in this schema|^Put this construction in a static function that returns",
         doc='Phase aliases, reusing a payload type for several phases, generic schema or phase payload'),
    dict(id='reserved-names', rewrites=r'^(reserved-member|verb-edge-name)$', observed='macro-diagnostic',
         pattern=r'(?i)reserved|shadow|redeclar|collid|distinct name|rename', doc='Generated member names are reserved'),
    dict(id='pinned-failure', rewrites=r'^(throws-any-error|untyped-throws)$', observed='expansion-error',
         pattern=r'cannot be converted to error type',
         doc='The compiler then checks that the router and every throwing candidate throw that type'),
    dict(id='public-default', rewrites=r'^schema-access$', observed='expansion-error', pattern=r'is internal and cannot be referenced from a default argument',
         doc='a public schema needs a public initializer or function'),
    # Refusals a rewrite must meet exactly: the case passes only with this diagnostic.
    dict(id='conditional-members', rewrites=r'^conditional-compilation$', observed='macro-diagnostic',
         pattern=r"Move this '#if' outside the schema or into a function body", exact=True,
         doc='so it refuses `#if` among the members of the schema, `Input`, `Scope`, and each operation and event namespace'),
    dict(id='conditional-attributes', rewrites=r'^conditional-attribute$', observed='macro-diagnostic',
         pattern=r"Move this '#if' out of the declaration's attributes", exact=True,
         doc='and in the attributes of any of those members'),
    dict(id='custom-attribute', rewrites=r'^(declaration-attributes|lowercase-attribute)$', observed='macro-diagnostic',
         pattern=r"Remove '@[^']+': generated code calls this function from nonisolated code and from every owner", exact=True,
         doc='any other attribute, which could isolate it to a global actor such as `@MainActor`, whatever its capitalization, or change how a call to it is checked, is refused'),
    dict(id='function-availability', rewrites=r'^(declaration-attributes|edge-availability)$', observed='macro-diagnostic',
         pattern=r"Remove '@(available|backDeployed)' and give the schema this availability instead", exact=True,
         doc='so it refuses `@available` and `@backDeployed` on the function and asks for them on the schema'),
    dict(id='schema-access', rewrites=r'^schema-access$', observed='macro-diagnostic',
         pattern=r"Declare '[^']*' (public|package): the (public|package) schema '[^']*' generates (public|package) members that name it",
         exact=True, doc='Each declaration of the schema that one of those spellings names, as Swift resolves the spelling where it is written, needs that access too'),
    # Not an allowance: under `reorder-members` the initializers' driver and handler labels must follow the new
    # declaration order, as this documents; every case checks them against its own declaration order.
    dict(id='declaration-order-labels', rewrites=r'^reorder-members$', observed='normalization', pattern=r'$^',
         doc="A managed owner's initializers take one driver per operation, in the order the operations are declared, and then one handler per event, in the order the events are declared"),
    dict(id='size-limit', rewrites=r'^ceilings$', observed='macro-diagnostic', pattern=r'the macro accepts at most \d+', exact=True,
         doc='The macro accepts at most 600 phases, 512 input cases, 256 operations, and 512 effect cases'),
    dict(id='raw-type-names', rewrites=r'^collide-raw$', observed='macro-diagnostic',
         pattern=r'(?i)needs no backticks',
         doc='names are Swift identifiers that need no backticks'),
    # A failure the macro reads without confirming it (a name a nested namespace finds outside itself, a bare `Array` or
    # `Int` the schema does not declare, a `Swift.` the schema does not declare) is not provably the type another
    # function throws, even one spelled `Swift::Int`, so a router's method
    # throws PreparationRejection and its Owned method returns the routed result instead of one shared Advance.
    dict(id='unconfirmed-failure-split', rewrites=r'^(alias-nested|sugar|swift-dot|module-selector)$', observed='interface|client-error',
         pattern=r'PreparationRejection|Route\.\w+Result',
         doc='Every other pair counts as two failures, which keeps the generated code correct'),
    dict(id='outside-alias-failure', rewrites=r'^alias-file$', observed='interface|client-error',
         pattern=r'PreparationRejection|Route\.\w+Result',
         doc='an alias declared outside the schema is invisible to the macro'),
    dict(id='outside-never', rewrites=r'^alias-file$', observed='expansion-error',
         pattern=r'names Never through a declaration the macro cannot read',
         doc='that the macro reads as a type with values without confirming its kind, must not be `Never`'),
    dict(id='nfc-refusal', rewrites=r'^collide-(nfd|kelvin|varia)', observed='macro-diagnostic',
         pattern=r"The name '[^']*' is not in Unicode Normalization Form C",
         doc='The macro therefore refuses a name that is not in that form anywhere it reads one'),
    dict(id='repeated-ownership', rewrites=r'^shared-param$', observed='interface', pattern=r'__shared',
         doc='repeats the payload\'s ownership'),
]

POLICY_NFC = r"The name '[^']*' is not in Unicode Normalization Form C"

# Errors a refused expansion leaves behind: authored code that names a generated type the macro never declared.
CASCADE = re.compile(r"^cannot find (type )?'(Effect|Route|Change|Advance|Restoration|Observed|Owned|Prepared|Snapshot|Phase|"
                     r"\w+Request|\w+Completion|\w+Result)' in scope$|^'(Effect|Route|Change|Advance|Restoration|Observed|Owned|"
                     r"Prepared|Snapshot|Phase|Local|Shared|\w+Request|\w+Completion|\w+Result)' is not a member type|"
                     # Swift's own access errors where an access refusal names the declaration that lacks access.
                     r"uses an? (internal|fileprivate|private|package) type|is (internal|fileprivate|private|package) and cannot be referenced")

# What a breaking rewrite must be rejected with: the macro's documented diagnostic, or Swift's own error where the
# grammar is Swift's. A case rejected any other way, or by a link error, fails.
# The graph checks a breaking rewrite of the graph may meet first: which one fires depends on the order the macro checks
# a graph in, so any of them is the documented rejection of a graph made invalid.
GRAPH_VALIDITY = (r"is unreachable from the initial phase|has no outgoing transitions; mark it '@Terminal'|is never started|"
                  r"can start but never complete|is never accepted|can never fire|can never run|must be eligible in destination|"
                  r"cannot be active in terminal phase|needs a (success|failure) edge or router|has no on(Success|Failure): edge or router|"
                  r"Ambiguous routing from|declare exactly one @Route")

BREAK_EXPECT = {
    'router-returns-void': r'A router with no edge to choose returns Never and throws a typed rejection|A router returns its choice among|'
                           r"The name '[^']*' is not in Unicode Normalization Form C",
    'scope-property': r'Operation metadata must reference declared Scope cases|Write each reference|must reference|Normalization Form C',
    'phase-alias-other': r"Phase '[^']*' needs a distinct nongeneric struct or enum declared directly inside the schema|Normalization Form C|"
                         r"is not a phase payload type declared in this schema|^Put this construction in a static function",
    'drop-request-label': r'labeled request:',
    'terminal-flip': GRAPH_VALIDITY + r"|Terminal phase '[^']*' cannot have an outgoing",
    'redirect-entrance': GRAPH_VALIDITY,
    'router-delete': GRAPH_VALIDITY,
    'router-duplicate': r"Ambiguous routing|declare exactly one @Route|A router returns its choice among|more than one @Route|routes? .* twice|already",
    'operation-drop-start': GRAPH_VALIDITY + r"|This transition starts no operation, cancels no work, and emits no event",
    'operation-drop-success': GRAPH_VALIDITY,
    'operation-drop-failure': GRAPH_VALIDITY,
    'scope-ineligible': GRAPH_VALIDITY,
    'cancel-unkeyed': r'cancel',
    'owner-duplicate': r"List each owner once; '\.[^']*' appears twice",
    'owner-excluded': r"Owner '\.[^']*' is unavailable in \.\w+, which supports",
    'owner-empty': r'List at least one owner, or omit owners:',
    'restoration-duplicate': r'Declare at most one @Restoration function in a schema',
    'restoration-entrance': GRAPH_VALIDITY + r"|List at least one restorable phase in only:",
}

STANDARD = {'Int', 'String', 'Bool', 'Double', 'Never', 'Void', 'Error', 'Int32', 'UInt8', 'Character', 'Sendable',
            'Array', 'Dictionary', 'Optional', 'Result', 'Equatable', 'Hashable'}
KEYWORDS = {'Self', 'Any', 'any', 'some', 'inout', 'borrowing', 'consuming', 'sending', 'throws', 'async', 'let', 'var',
            'func', 'case', 'enum', 'struct', 'class', 'protocol', 'typealias', 'static', 'fileprivate', 'private',
            'public', 'internal', 'nonisolated', 'return', 'throw', 'try', 'self', 'true', 'false', 'nil', 'in', 'where',
            'default', 'switch', 'guard', 'else', 'if', 'for', 'while', 'do', 'catch', 'import', 'copy', 'init', 'Type',
            'Protocol', 'extension', 'mutating', '__owned', '__shared', 'isolated'}

# ---------------------------------------------------------------------------------------------------------------------
# Seeds: the guide's schemas, chosen client fixtures, and schemas written for shapes the others leave out.

FIXTURE_SEEDS = ['GMT-routed-mixed-escaping', 'GCT-restoration-allows', 'GMT-throws-never-candidate',
                 'GMT-initial-qualified-default', 'GMT-route-failure', 'GMT-request-label-spellings', 'GMT-scope-active',
                 'GMT-sugar-failure-key', 'GCT-owners', 'GMT-isolated-sending-payload', 'GMT-tuple-wildcard-label',
                 'GMT-alias-router-failure', 'GMT-input-case-extension']

# A seed may end with a client section after a `// fuzz-client` line: code compiled in a separate module that imports
# the schema's module, so it sees only what the schema exports (or, after `@testable import`, what it declares
# internally). A list of labeled arguments between `/*fuzz-args*/` and `/*end-args*/` is put in the order the case
# declares the operations and events it names, as the guide documents for managed initializers. A line
# `// fuzz-file: Name.swift` starts another source file of the schema's module.
CLIENT_MARKER = '// fuzz-client\n'
FILE_MARKER = re.compile(r'^// fuzz-file: (\w+\.swift)\n', re.M)

# The report each domain seed's `fuzzReport()` must print: a consistently wrong choice of edge, driver, handler, or
# restoration changes it even where every variant agrees with its seed.
EXPECTED_REPORTS = {
    'own-report-local': 'idle.left@1; driver L1; delivery busy.worked; idle.right@3; driver R2; delivery busy.worked; '
                        'idle.finish@5; logged left 1,worked 21,right 2,worked 22; rejected left(3); done; idle.right@1; '
                        'driver R4; delivery busy.worked; 2; refused broken',
}


def chain_seed(limit, length):
    """A `.parallel(limit:)` operation started once whose completions walk a chain of `length` phases: the macro counts
    executions up to 32 and treats a larger limit as unbounded, so the chain is reachable exactly when
    `length <= limit` or `limit > 32`."""
    phases = '\n'.join(f'    struct C{i}: Sendable {{}}' for i in range(length + 1))
    cases = '\n'.join(f'    {"@Terminal " if i == length else ""}case c{i}(C{i})' for i in range(1, length + 1))
    active = ', '.join(f'C{i}.self' for i in range(1, length))
    edges = '\n'.join(f'    @Transition(onSuccess: Work.self)\n    fileprivate static func step{i}(_ source: C{i}, _ value: Int) -> C{i + 1} {{ C{i + 1}() }}'
                      for i in range(1, length))
    return f'''import StateMachine

@StateMachine(mode: .shared, owners: [.local])
nonisolated enum Chain: Sendable {{
{phases}
    @Initial case c0(C0)
{cases}
    enum Input: Sendable {{ case go }}
    @Operation(activeIn: [{active}], admission: .parallel(limit: {limit}))
    enum Work {{ typealias Output = Int }}
    @Transition(on: Input.go, starts: [Work.self])
    fileprivate static func go(_ source: C0) -> Change<C1, Effect.Go> {{ Change(C1(), effects: [.work]) }}
{edges}
}}

func fuzzReport() -> String {{ "\\(Chain.graph.edges.count)" }}
'''

EMBEDDED_SEEDS = {
    'initial-factory': '''
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Brew: Sendable {
    struct Caf\u00e9: Sendable { var value = 1 }
    struct Served: Sendable { let value: Int }
    static func makeCaf\u00e9() -> Caf\u00e9 { Caf\u00e9(value: 42) }
    @Initial case ready(Caf\u00e9 = makeCaf\u00e9())
    @Terminal case served(Served)
    enum Input: Sendable { case serve }
    @Transition(on: Input.serve)
    fileprivate static func serve(_ source: Caf\u00e9) -> Served { Served(value: source.value) }
}

func fuzzReport() -> String {
    "\\(Brew.owned().withValue { $0.value }) \\(Brew.owned().serve().withValue { $0.value })"
}
''',
    'rejecting-routers': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.owned])
nonisolated enum Gate: Sendable {
    struct Open: Sendable {}
    enum Problem: Error, Sendable { case no }
    typealias Nothing = Never
    typealias Fault = Problem
    @Initial case open(Open)
    enum Input: Sendable { case stay, deny, refuse }
    @Transition(on: Input.stay)
    fileprivate static func stay(_ source: Open) -> Open { source }
    @Route(on: Input.deny)
    fileprivate static func deny(_ source: Open) throws(Fault) -> Nothing { throw .no }
    @Route(on: Input.refuse)
    fileprivate static func refuse(_ source: Open) throws(Problem) -> Never { throw .no }
}

func fuzzReport() -> String { "\\(Gate.owned(Gate.Open()).stay().withValue { _ in 1 })" }
''',
    'scoped-invalidation': '''
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Account: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable { let name: String }
    struct Ready: Sendable { let items: [String] }
    @Initial case idle(Idle = Idle())
    case loading(Loading)
    @Terminal case ready(Ready)
    enum Scope {
        @Active(in: [Loading.self])
        case session
        @Active(in: [Loading.self])
        case profile
    }
    enum Input: Sendable { case load(String), switchProfile(String) }
    @Operation(scope: Scope.profile, requires: [Scope.session])
    enum Fetch {
        typealias Input = String
        typealias Output = [String]
    }
    @Transition(on: Input.load, starts: [Fetch.self])
    fileprivate static func begin(_ source: Idle, _ name: String) -> Change<Loading, Effect.Begin> {
        Change(Loading(name: name), effects: [.fetch(name)])
    }
    @Transition(on: Input.switchProfile, invalidates: [Scope.profile], starts: [Fetch.self])
    fileprivate static func switchProfile(_ source: Loading, _ name: String) -> Change<Loading, Effect.SwitchProfile> {
        Change(Loading(name: name), effects: [.fetch(name)])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Loading, _ items: Fetch.Output) -> Ready { Ready(items: items) }
}

func fuzzReport() -> String { "scoped" }
''',
    'composed-failure': '''
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Mix: Sendable {
    enum N { protocol P {} }
    protocol Q {}
    struct Problem<T>: Error, Sendable {}
    struct Start: Sendable {}
    struct Left: Sendable {}
    struct Right: Sendable {}
    @Initial case start(Start)
    @Terminal case left(Left)
    @Terminal case right(Right)
    enum Input: Sendable { case pick(Int) }
    @Transition(on: Input.pick)
    fileprivate static func goLeft(_ source: Start, _ value: Int) throws(Problem<any N.P & Q>) -> Left { Left() }
    @Transition(on: Input.pick)
    fileprivate static func goRight(_ source: Start, _ value: Int) throws(Problem<any Q & N.P>) -> Right { Right() }
    @Route(on: Input.pick)
    fileprivate static func pick(_ source: Start, _ value: Int) throws(Problem<any N.P & Q>) -> Route.Pick {
        value < 10 ? .goLeft : .goRight
    }
}

func pinned(_ start: Mix.Observed<Mix.Start>) -> (Int) throws(Mix.Problem<any Mix.N.P & Mix.Q>) -> Mix.Prepared {
    { value throws(Mix.Problem<any Mix.N.P & Mix.Q>) in try start.pick(value) }
}
''',
    'routed-closure': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.owned])
nonisolated enum Relay: Sendable {
    struct Idle: Sendable {}
    struct Ran: Sendable { let value: Int }
    struct Skipped: Sendable {}
    @Initial case idle(Idle)
    @Terminal case ran(Ran)
    @Terminal case skipped(Skipped)
    enum Input: Sendable { case act(@Sendable () -> Int) }
    @Route(on: Input.act)
    fileprivate static func choose(_ source: Idle, _ work: @Sendable () -> Int) -> Route.Choose { .run }
    @Transition(on: Input.act)
    fileprivate static func run(_ source: Idle, _ work: @Sendable () -> Int) -> Ran { Ran(value: 7) }
    @Transition(on: Input.act)
    fileprivate static func skip(_ source: Idle, _ work: @Sendable () -> Int) -> Skipped { Skipped() }
}

func fuzzReport() -> String {
    switch Relay.owned(Relay.Idle()).choose({ 3 }) {
    case .run(let ran): return "ran \\(ran.withValue { $0.value })"
    case .skip: return "skipped"
    }
}
''',
    'routed-closure-borrowing': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.owned])
nonisolated enum Bench: Sendable {
    typealias Work = @Sendable () -> Int
    struct Idle: Sendable {}
    struct Ran: Sendable { let value: Int }
    struct Kept: Sendable {}
    @Initial case idle(Idle)
    @Terminal case ran(Ran)
    @Terminal case kept(Kept)
    enum Input: Sendable { case offer(Work) }
    @Route(on: Input.offer)
    fileprivate static func choose(_ source: Idle, _ work: borrowing Work) -> Route.Choose { work() < 10 ? .run : .keep }
    @Transition(on: Input.offer)
    fileprivate static func run(_ source: Idle, _ work: borrowing Work) -> Ran { Ran(value: work()) }
    @Transition(on: Input.offer)
    fileprivate static func keep(_ source: Idle, _ work: borrowing Work) -> Kept { Kept() }
}

func fuzzReport() -> String {
    switch Bench.owned(Bench.Idle()).choose({ 3 }) {
    case .run(let ran): return "ran \\(ran.withValue { $0.value })"
    case .keep: return "kept"
    }
}
''',
    'owned-single': '''
import StateMachine

@StateMachine(mode: .ownedOnly)
nonisolated enum Token: ~Copyable {
    struct Ready: ~Copyable { var value = 5 }
    @Initial @Terminal case ready(Ready)
}

func fuzzReport() -> String { "\\(Token.owned(Token.Ready()).withValue { $0.value })" }
''',
    'input-shadow': '''
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Tray: Sendable {
    struct Box: Sendable { let label: String }
    struct Idle: Sendable {}
    struct Held: Sendable { let count: Int }
    @Initial case idle(Idle)
    @Terminal case held(Held)
    enum Input: Sendable {
        struct Box: Sendable { let count: Int }
        case put(Box), take(Self.Box)
    }
    @Transition(on: Input.put)
    fileprivate static func put(_ source: Idle, _ box: Input.Box) -> Held { Held(count: box.count) }
    @Transition(on: Input.take)
    fileprivate static func take(_ source: Idle, _ box: Input.Box) -> Held { Held(count: box.count + 1) }
}

func fuzzReport() -> String { "\\(Tray.owned(Tray.Idle()).put(Tray.Input.Box(count: 2)).withValue { $0.count })" }
''',
    'keyed-completion-router': '''
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Shelf: Sendable {
    struct Browsing: Sendable { var titles: [Int: String] = [:] }
    struct Full: Sendable {}
    enum Missing: Error, Sendable { case gone }
    @Initial case browsing(Browsing = Browsing())
    @Terminal case full(Full)
    enum Input: Sendable { case open(Int) }
    @Operation(activeIn: [Browsing.self], admission: .parallel(limit: 2))
    enum Download {
        typealias Key = Int
        typealias Input = String
        typealias Output = String
        typealias Failure = Missing
    }
    @Transition(on: Input.open, starts: [Download.self])
    fileprivate static func open(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Open> {
        Change(source, effects: [.download(key: id, input: "book")])
    }
    @Transition(onSuccess: Download.self)
    fileprivate static func store(_ source: Browsing, _ title: Download.Output, request: DownloadRequest) -> Browsing {
        var titles = source.titles
        titles[request.key] = title
        return Browsing(titles: titles)
    }
    @Transition(onSuccess: Download.self)
    fileprivate static func fill(_ source: Browsing, _ title: Download.Output, request: DownloadRequest) -> Full { Full() }
    @Route(onSuccess: Download.self)
    fileprivate static func sort(_ source: Browsing, _ title: Download.Output, request: DownloadRequest) -> Route.Sort {
        source.titles.count > 3 ? .fill : .store
    }
    @Transition(onFailure: Download.self)
    fileprivate static func missed(_ source: Browsing, _ failure: Download.Failure) -> Browsing { source }
}

func fuzzReport() -> String {
    let request = Shelf.DownloadRequest(key: 1, input: "x")
    switch Shelf.owned().sort("t", request: request) {
    case .store(let browsing): return "store \\(browsing.withValue { $0.titles.count })"
    case .fill: return "fill"
    }
}
''',
    'event-isolated': '''
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned, .local, .mainActorHost])
nonisolated enum Ledger {
    nonisolated struct Open { var lines: [String] = [] }
    nonisolated struct Closed {}
    @Initial case open(Open = Open())
    @Terminal case closed(Closed)
    enum Input { case add(String), close }
    @Event
    enum Logged { typealias Payload = String }
    @Event
    enum Closing {}
    @Transition(on: Input.add, emits: [Logged.self])
    fileprivate static func add(_ source: Open, _ line: String) -> Change<Open, Effect.Add> {
        Change(Open(lines: source.lines + [line]), effects: [.logged(line)])
    }
    @Transition(on: Input.close, emits: [Closing.self])
    fileprivate static func close(_ source: Open) -> Change<Closed, Effect.Close> {
        Change(Closed(), effects: [.closing])
    }
}

func fuzzReport() -> String { "ledger" }
// fuzz-client
@testable import Fz

@MainActor func fuzzClient() -> Ledger.MainActorHost {
    Ledger.MainActorHost(Ledger.Open(), /*fuzz-args*/onLogged: { (line: Swift::String) in _ = line }, onClosing: { }/*end-args*/)
}
''',
    # Two distinguishable inputs, driver arguments, a managed completion, an event, a refusal, and a restoration,
    # with the report pinned in EXPECTED_REPORTS.
    'report-local': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.local])
nonisolated enum Desk: Sendable {
    struct Idle: Sendable { var log: [String] = [] }
    struct Busy: Sendable { let log: [String] }
    struct Done: Sendable { let log: [String] }
    enum Saved: Sendable { case idle([String]), broken }
    enum Rejected: Error, Sendable { case broken }
    @Initial case idle(Idle = Idle())
    case busy(Busy)
    @Terminal case done(Done)
    enum Input: Sendable { case left(Int), right(Int), finish }
    @Operation(activeIn: [Busy.self])
    enum Work {
        typealias Input = String
        typealias Output = Int
    }
    @Event
    enum Logged { typealias Payload = String }
    @Transition(on: Input.left, starts: [Work.self])
    fileprivate static func left(_ source: Idle, _ n: Int) -> Change<Busy, Effect.Left> {
        Change(Busy(log: source.log + ["left \\(n)"]), effects: [.work("L\\(n)")])
    }
    @Transition(on: Input.right, starts: [Work.self])
    fileprivate static func right(_ source: Idle, _ n: Int) -> Change<Busy, Effect.Right> {
        Change(Busy(log: source.log + ["right \\(n)"]), effects: [.work("R\\(n)")])
    }
    @Transition(onSuccess: Work.self)
    fileprivate static func worked(_ source: Busy, _ value: Int) -> Idle { Idle(log: source.log + ["worked \\(value)"]) }
    @Transition(on: Input.finish, emits: [Logged.self])
    fileprivate static func finish(_ source: Idle) -> Change<Done, Effect.Finish> {
        Change(Done(log: source.log + ["finish"]), effects: [.logged(source.log.joined(separator: ","))])
    }
    @Restoration
    fileprivate static func restore(_ saved: Saved) throws(Rejected) -> Restoration {
        switch saved {
        case .idle(let log): return .idle(Idle(log: log + ["restored"]))
        case .broken: throw .broken
        }
    }
}

func fuzzReport() -> String {
    var out: [String] = []
    var desk = Desk.Local()
    func step(_ input: Desk.Input, _ desk: inout Desk.Local, _ out: inout [String]) {
        do {
            let receipt = try desk.send(input)
            out.append("\\(receipt.edgeID ?? "-")@\\(receipt.snapshot.revision)")
        } catch { out.append("rejected \\(input)") }
        for batch in desk.drainCommands() {
            for command in batch.commands {
                switch command {
                case .work(let work):
                    out.append("driver \\(work.input)")
                    let delivery = desk.deliver(work.succeeded(work.input.count * 10 + (work.input.hasPrefix("L") ? 1 : 2)))
                    out.append("delivery \\(Desk.Local.receipt(of: delivery)?.edgeID ?? "-")")
                    _ = desk.acknowledgeExecution(work.execution)
                case .logged(let line): out.append("logged \\(line)")
                case .cancel: out.append("cancel")
                }
            }
        }
    }
    step(.left(1), &desk, &out)
    step(.right(2), &desk, &out)
    step(.finish, &desk, &out)
    step(.left(3), &desk, &out)
    out.append("\\(Desk.Local.phase(of: desk.snapshot()))")
    do {
        var restored = try Desk.Local(restoring: .idle(["saved"]))
        step(.right(4), &restored, &out)
        out.append("\\(restored.snapshot().revision)")
    } catch { out.append("restore failed") }
    do { _ = try Desk.Local(restoring: .broken); out.append("restored broken") } catch { out.append("refused \\(error)") }
    return out.joined(separator: "; ")
}
''',
    # A shadowed event payload: the payload names the namespace's own `Detail`, and the schema declares another.
    'event-shadow': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.local, .shared])
nonisolated enum Journal: Sendable {
    typealias Detail = Int
    struct Open: Sendable {}
    @Initial case open(Open)
    enum Input: Sendable { case note(String) }
    @Event
    enum Logged {
        struct Detail: Sendable { let text: String }
        typealias Payload = Detail
    }
    @Transition(on: Input.note, emits: [Logged.self])
    fileprivate static func note(_ source: Open, _ text: String) -> Change<Open, Effect.Note> {
        Change(source, effects: [.logged(Logged.Detail(text: text))])
    }
}
''',
    # A public and a package schema whose private helpers share names with the other's public types; the client
    # module uses both through a plain import, including the public default initial value.
    'access-pair': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
public nonisolated enum Approval: Sendable {
    public struct Draft: Sendable {
        public let text: String
        public init(text: String = "draft") { self.text = text }
    }
    public struct Approved: Sendable { public let text: String }
    private enum Archive { struct Pending {}; static let count = 0 }
    @Initial case draft(Draft = Draft())
    @Terminal case approved(Approved)
    public enum Input: Sendable { case approve }
    @Transition(on: Input.approve)
    fileprivate static func approve(_ source: Draft) -> Approved { Approved(text: source.text) }
}

@StateMachine(mode: .shared, owners: [.owned])
package nonisolated enum Review: Sendable {
    package struct Pending: Sendable { package init() {} }
    package struct Done: Sendable {}
    private struct Draft { let unused = 0 }
    @Initial case pending(Pending)
    @Terminal case done(Done)
    package enum Input: Sendable { case finish }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Pending) -> Done { Done() }
}
// fuzz-client
import Fz

func fuzzClient() -> String {
    let approved: Approval.Owned<Approval.Approved> = Approval.owned().approve()
    let done: Review.Owned<Review.Done> = Review.owned(Review.Pending()).finish()
    _ = done
    return approved.withValue { $0.text }
}
''',
    # Isolated mode with the owners it generates by default.
    'isolated-default': '''
import StateMachine

@StateMachine(mode: .isolated)
nonisolated enum Counter {
    nonisolated struct Counting { var value = 0 }
    nonisolated struct Stopped { let value: Int }
    @Initial case counting(Counting = Counting())
    @Terminal case stopped(Stopped)
    enum Input { case add(Int), stop }
    @Transition(on: Input.add)
    fileprivate static func add(_ source: Counting, _ amount: Int) -> Counting { Counting(value: source.value + amount) }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Counting) -> Stopped { Stopped(value: source.value) }
}

func fuzzReport() -> String { "\\(Counter.owned().add(2).add(3).stop().withValue { $0.value })" }
''',
    # A single managed owner.
    'single-managed': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.shared])
nonisolated enum Lamp: Sendable {
    struct Off: Sendable {}
    struct On: Sendable { let level: Int }
    @Initial case off(Off = Off())
    case on(On)
    enum Input: Sendable { case turn(Int), dim }
    @Transition(on: Input.turn)
    fileprivate static func turn(_ source: Off, _ level: Int) -> On { On(level: level) }
    @Transition(on: Input.dim)
    fileprivate static func dim(_ source: On) -> Off { Off() }
}

func fuzzReport() -> String {
    let lamp = Lamp.Shared()
    let first = (try? lamp.send(.turn(3)))?.edgeID ?? "-"
    let second = (try? lamp.send(.turn(4)))?.edgeID ?? "rejected"
    let third = (try? lamp.send(.dim))?.edgeID ?? "-"
    return "\\(first) \\(second) \\(third)"
}
''',
    # Managed owners only: no Owned, no Local.
    'managed-only': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.shared, .actorHost, .mainActorHost, .isolatedHost])
nonisolated enum Queue: Sendable {
    struct Waiting: Sendable {}
    struct Running: Sendable { let job: String }
    @Initial case waiting(Waiting)
    case running(Running)
    enum Input: Sendable { case run(String) }
    @Operation(activeIn: [Running.self])
    enum Job {
        typealias Input = String
        typealias Output = Int
    }
    @Transition(on: Input.run, starts: [Job.self])
    fileprivate static func run(_ source: Waiting, _ job: String) -> Change<Running, Effect.Run> {
        Change(Running(job: job), effects: [.job(job)])
    }
    @Transition(onSuccess: Job.self)
    fileprivate static func finished(_ source: Running, _ count: Int) -> Waiting { Waiting() }
}
// fuzz-client
@testable import Fz

func fuzzClient() -> Queue.Shared {
    Queue.Shared(Queue.Waiting(), /*fuzz-args*/jobDriver: { (job: Swift::String) in job.count }/*end-args*/)
}
''',
    # An Input extension in another file of the module, whose alias shadows the schema's type of that name.
    'cross-file-input': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum Sheet: Sendable {
    struct Note: Sendable { let text: String }
    struct Blank: Sendable {}
    struct Written: Sendable { let count: Int }
    @Initial case blank(Blank)
    @Terminal case written(Written)
    enum Input: Sendable { case write(Note), mark(Self.Note) }
    @Transition(on: Input.write)
    fileprivate static func write(_ source: Blank, _ note: Swift::Int) -> Written { Written(count: note) }
    @Transition(on: Input.mark)
    fileprivate static func mark(_ source: Blank, _ note: Swift::Int) -> Written { Written(count: note + 1) }
}

func fuzzReport() -> String { "\\(Sheet.owned(Sheet.Blank()).write(4).withValue { $0.count })" }
// fuzz-file: InputExtension.swift
extension Sheet.Input {
    typealias Note = Swift::Int
}
''',
    # Router candidates that throw a value-generic failure; the client pins the shared failure type.
    'value-generic-failure': '''
import StateMachine

@available(macOS 26, *)
@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum Gauge: Sendable {
    struct Problem<let N: Int>: Error, Sendable {}
    struct Start: Sendable {}
    struct Low: Sendable {}
    struct High: Sendable {}
    @Initial case start(Start)
    @Terminal case low(Low)
    @Terminal case high(High)
    enum Input: Sendable { case read(Int), batch([2 of Int]) }
    @Transition(on: Input.batch)
    fileprivate static func batch(_ source: Start, _ values: [2 of Int]) -> Low { Low() }
    @Transition(on: Input.read)
    fileprivate static func low(_ source: Start, _ value: Int) throws(Problem<10>) -> Low { Low() }
    @Transition(on: Input.read)
    fileprivate static func high(_ source: Start, _ value: Int) throws(Problem<10>) -> High { High() }
    @Route(on: Input.read)
    fileprivate static func read(_ source: Start, _ value: Int) throws(Problem<10>) -> Route.Read {
        value < 10 ? .low : .high
    }
}

@available(macOS 26, *)
func pinned(_ start: Gauge.Observed<Gauge.Start>) -> (Int) throws(Gauge.Problem<10>) -> Gauge.Prepared {
    { value throws(Gauge.Problem<10>) in try start.read(value) }
}

@available(macOS 26, *)
func fuzzReport() -> String {
    var gauge = Gauge.Local(Gauge.Start())
    let low = (try? gauge.send(.read(3)))?.edgeID ?? "rejected"
    return low
}
''',
    # A schema available above the deployment floor, with its payload types; the edges carry no availability.
    'available-schema': '''
import StateMachine

@available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *)
@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum Kiosk: Sendable {
    struct Ready: Sendable {}
    struct Served: Sendable { let value: Int }
    @Initial case ready(Ready = Ready())
    @Terminal case served(Served)
    enum Input: Sendable { case serve(Int) }
    @Transition(on: Input.serve)
    fileprivate static func serve(_ source: Ready, _ value: Int) -> Served { Served(value: value) }
}

func fuzzReport() -> String {
    if #available(macOS 14, iOS 17, tvOS 17, watchOS 10, visionOS 1, *) {
        return "\\(Kiosk.owned().serve(5).withValue { $0.value })"
    }
    return "unavailable"
}
''',
    # A keyed parallel operation that holds a scope and requires another, crossed with a restoration that admits a
    # phase where the scope is active.
    'keyed-scoped-restoration': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.local, .shared])
nonisolated enum Library: Sendable {
    struct Page: Sendable { let text: String }
    struct Browsing: Sendable {}
    struct Reading: Sendable { let id: Int }
    enum Saved: Sendable { case browsing, reading(Int) }
    @Initial case browsing(Browsing = Browsing())
    case reading(Reading)
    enum Scope {
        @Active(in: [Browsing.self, Reading.self])
        case session
        @Active(in: [Reading.self])
        case book
    }
    enum Input: Sendable { case open(Int), close }
    @Operation(scope: Scope.book, requires: [Scope.session], admission: .parallel(limit: 2))
    enum Fetch {
        typealias Key = Int
        typealias Output = Page
    }
    @Transition(on: Input.open, starts: [Fetch.self])
    fileprivate static func open(_ source: Browsing, _ id: Int) -> Change<Reading, Effect.Open> {
        Change(Reading(id: id), effects: [.fetch(key: id)])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func fetched(_ source: Reading, _ page: Fetch.Output, request: FetchRequest) -> Reading { source }
    @Transition(on: Input.close, invalidates: [Scope.book])
    fileprivate static func close(_ source: Reading) -> Browsing { Browsing() }
    @Restoration(allows: [Reading.self])
    fileprivate static func restore(_ saved: Saved) -> Restoration {
        switch saved {
        case .browsing: return .browsing(Browsing())
        case .reading(let id): return .reading(Reading(id: id))
        }
    }
}

func fuzzReport() -> String {
    var library = Library.Local()
    var out: [String] = []
    out.append((try? library.send(.open(7)))?.edgeID ?? "rejected")
    for batch in library.drainCommands() {
        for command in batch.commands {
            if case .fetch(let work) = command {
                out.append("fetch \\(work.key)")
                out.append(Library.Local.receipt(of: library.deliver(work.succeeded(Library.Page(text: "p"))))?.edgeID ?? "-")
            }
        }
    }
    out.append((try? library.send(.close))?.edgeID ?? "rejected")
    let restored = Library.Local(restoring: .reading(3))
    out.append(Library.Local.phase(of: restored.snapshot()))
    return out.joined(separator: " ")
}
''',
    # Function types with two attributes, which `function-attribute-order` swaps, in an alias, an event payload, and
    # the failures router candidates compare.
    'function-attributes': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum Panel: Sendable {
    typealias Action = @Sendable @MainActor () -> Int
    struct Problem<T>: Error, Sendable {}
    struct Start: Sendable {}
    struct Left: Sendable {}
    struct Right: Sendable {}
    @Initial case start(Start)
    @Terminal case left(Left)
    @Terminal case right(Right)
    enum Input: Sendable { case pick(Int), act(Action) }
    @Event
    enum Clicked { typealias Payload = @Sendable @MainActor () -> Void }
    @Transition(on: Input.pick)
    fileprivate static func goLeft(_ source: Start, _ value: Int) throws(Problem<@Sendable @MainActor () -> Int>) -> Left { Left() }
    @Transition(on: Input.pick)
    fileprivate static func goRight(_ source: Start, _ value: Int) throws(Problem<@MainActor @Sendable () -> Int>) -> Right { Right() }
    @Route(on: Input.pick)
    fileprivate static func pick(_ source: Start, _ value: Int) throws(Problem<@Sendable @MainActor () -> Int>) -> Route.Pick {
        value < 10 ? .goLeft : .goRight
    }
    @Transition(on: Input.act, emits: [Clicked.self])
    fileprivate static func act(_ source: Start, _ action: @escaping Action) -> Change<Start, Effect.Act> {
        Change(source, effects: [.clicked({ })])
    }
}

func pinned(_ start: Panel.Observed<Panel.Start>) -> (Int) throws(Panel.Problem<@Sendable @MainActor () -> Int>) -> Panel.Prepared {
    { value throws(Panel.Problem<@Sendable @MainActor () -> Int>) in try start.pick(value) }
}
''',
    # A lowercase global actor, which `lowercase-attribute` puts on an edge.
    'lowercase-actor': '''
import StateMachine

@globalActor actor uiActor { static let shared = uiActor() }

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum Toggle: Sendable {
    struct Off: Sendable {}
    struct On: Sendable {}
    @Initial case off(Off)
    case on(On)
    enum Input: Sendable { case flip }
    @Transition(on: Input.flip)
    fileprivate static func on(_ source: Off) -> On { On() }
    @Transition(on: Input.flip)
    fileprivate static func off(_ source: On) -> Off { Off() }
}

func fuzzReport() -> String { "\\(Toggle.owned(Toggle.Off()).on().off().withValue { _ in 1 })" }
''',
    # Metatype failures of a protocol, and optional closure failures: router candidates whose failures the guide
    # calls one type, which `existential-metatype` respells and `metatype-split` makes distinct.
    'metatype-failure': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum Probe: Sendable {
    protocol Failure {}
    struct Problem<T>: Error, Sendable {}
    struct Start: Sendable {}
    struct Left: Sendable {}
    struct Right: Sendable {}
    @Initial case start(Start)
    @Terminal case left(Left)
    @Terminal case right(Right)
    enum Input: Sendable { case pick(Int) }
    @Transition(on: Input.pick)
    fileprivate static func goLeft(_ source: Start, _ value: Int) throws(Problem<Failure.Type>) -> Left { Left() }
    @Transition(on: Input.pick)
    fileprivate static func goRight(_ source: Start, _ value: Int) throws(Problem<any Failure.Type>) -> Right { Right() }
    @Route(on: Input.pick)
    fileprivate static func pick(_ source: Start, _ value: Int) throws(Problem<Failure.Type>) -> Route.Pick {
        value < 10 ? .goLeft : .goRight
    }
}

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum Hook: Sendable {
    struct Problem<T>: Error, Sendable {}
    struct Start: Sendable {}
    struct Left: Sendable {}
    struct Right: Sendable {}
    @Initial case start(Start)
    @Terminal case left(Left)
    @Terminal case right(Right)
    enum Input: Sendable { case pick(Int) }
    @Transition(on: Input.pick)
    fileprivate static func goLeft(_ source: Start, _ value: Int) throws(Problem<(() -> Int)?>) -> Left { Left() }
    @Transition(on: Input.pick)
    fileprivate static func goRight(_ source: Start, _ value: Int) throws(Problem<(() -> Int)?>) -> Right { Right() }
    @Route(on: Input.pick)
    fileprivate static func pick(_ source: Start, _ value: Int) throws(Problem<(() -> Int)?>) -> Route.Pick {
        value < 10 ? .goLeft : .goRight
    }
}

// Two global actors of one basename in two namespaces: `@Actors.Main` and `@Others.Main` name two types.
@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum Stage: Sendable {
    enum Actors { @globalActor actor Main { static let shared = Main() } }
    enum Others { @globalActor actor Main { static let shared = Main() } }
    struct Problem<T>: Error, Sendable {}
    struct Start: Sendable {}
    struct Left: Sendable {}
    struct Right: Sendable {}
    @Initial case start(Start)
    @Terminal case left(Left)
    @Terminal case right(Right)
    enum Input: Sendable { case pick(Int) }
    @Transition(on: Input.pick)
    fileprivate static func goLeft(_ source: Start, _ value: Int) throws(Problem<@Actors.Main () -> Int>) -> Left { Left() }
    @Transition(on: Input.pick)
    fileprivate static func goRight(_ source: Start, _ value: Int) throws(Problem<@Actors.Main () -> Int>) -> Right { Right() }
    @Route(on: Input.pick)
    fileprivate static func pick(_ source: Start, _ value: Int) throws(Problem<@Actors.Main () -> Int>) -> Route.Pick {
        value < 10 ? .goLeft : .goRight
    }
}

func pinned(_ start: Probe.Observed<Probe.Start>) -> (Int) throws(Probe.Problem<any Probe.Failure.Type>) -> Probe.Prepared {
    { value throws(Probe.Problem<any Probe.Failure.Type>) in try start.pick(value) }
}

func pinnedStage(_ start: Stage.Observed<Stage.Start>) -> (Int) throws(Stage.Problem<@Stage.Actors.Main () -> Int>) -> Stage.Prepared {
    { value throws(Stage.Problem<@Stage.Actors.Main () -> Int>) in try start.pick(value) }
}

func pinnedHook(_ start: Hook.Observed<Hook.Start>) -> (Int) throws(Hook.Problem<(() -> Int)?>) -> Hook.Prepared {
    { value throws(Hook.Problem<(() -> Int)?>) in try start.pick(value) }
}
''',
    'parallel-32': chain_seed(32, 33),
    'parallel-33': chain_seed(33, 34),
}

# A seed whose name is in this set has its own fuzzReport; every seed's graphs are printed.


def doc_seeds():
    seeds = {}
    for index, block in enumerate(re.findall(r'```swift\n(.*?)```', DOC.read_text(), re.S)):
        # A block that declares a schema once per platform under `#if` compiles one clause; a rewrite of the other changes
        # nothing the compiler reads.
        if '@StateMachine(' not in block or re.search(r'^\s*#if', block, re.M):
            continue
        name = re.search(r'enum (\w+)', block).group(1)
        text = block if 'import StateMachine' in block else 'import StateMachine\n\n' + block
        seeds[f'doc-{name}'] = text
    return seeds


def all_seeds():
    seeds = doc_seeds()
    for identifier in FIXTURE_SEEDS:
        path = ROOT / 'ClientFixtures' / identifier / 'positive.swift'
        if path.exists() and 'StateMachineExamples' not in path.read_text():
            seeds[f'fx-{identifier}'] = path.read_text()
    for name, text in EMBEDDED_SEEDS.items():
        seeds[f'own-{name}'] = text.lstrip('\n')
    return seeds


# ---------------------------------------------------------------------------------------------------------------------
# Reading a seed: type sites, declared names, schema members. Seeds are formatted Swift, so a balanced scanner suffices.

def scan_type_end(text, start, stops):
    depth, index = 0, start
    while index < len(text):
        if text.startswith('->', index):
            index += 2
            continue
        char = text[index]
        if char in '([<':
            depth += 1
        elif char in ')]>':
            if depth == 0:
                break
            depth -= 1
        elif depth == 0 and (char in stops or (char == '{' and '{' in stops)):
            break
        elif depth == 0 and char == '}':
            break
        index += 1
    end = index
    while end > start and text[end - 1] in ' \t\n':
        end -= 1
    return end


def code_mask(text):
    """True for each character outside comments and string literals."""
    mask = [True] * len(text)
    for match in re.finditer(r'//[^\n]*|/\*.*?\*/|"(?:[^"\\\n]|\\\((?:[^()]|\([^()]*\))*\)|\\.)*"', text, re.S):
        for index in range(match.start(), match.end()):
            mask[index] = False
        # Code interpolated into a string literal is code.
        if match.group(0).startswith('"'):
            for inner in re.finditer(r'\\\(((?:[^()]|\((?:[^()]|\([^()]*\))*\))*)\)', match.group(0)):
                for index in range(match.start() + inner.start(1), match.start() + inner.end(1)):
                    mask[index] = True
    return mask


class Site:
    def __init__(self, start, end, kind, text, context):
        self.start, self.end, self.kind, self.text, self.context = start, end, kind, text, context

    def __repr__(self):
        return f'{self.kind}:{self.text}'


MODIFIERS = r'(?:(?:borrowing|consuming|__owned|__shared|sending|inout|isolated)\s+|@escaping\s+|@autoclosure\s+)*'


def schema_names(text):
    return re.findall(r'@StateMachine\([^)]*\)\s*(?:@\w+(?:\([^)]*\))?\s*)*(?:\w+\s+)*enum\s+`?(\w+)`?', text)


def phase_payloads(text):
    names = set()
    for match in re.finditer(r'^    (?:@[\w.]+(?:\([^)\n]*\))?\s+)*case\s+`?\w+`?\((.*)\)\s*$', text, re.M):
        payload = match.group(1).split('=')[0].strip()
        names.add(core_name(payload))
    return names


def core_name(spelling):
    spelling = spelling.strip()
    while spelling.startswith('(') and spelling.endswith(')'):
        spelling = spelling[1:-1].strip()
    spelling = spelling.replace('`', '')
    return spelling.split('.')[-1].split('<')[0].strip()


def type_sites(text):
    """Type spellings in function signatures, aliases, and case payloads, with nested generic arguments."""
    mask = code_mask(text)
    sites = []

    def add(start, end, kind, context):
        if end <= start or not mask[start]:
            return
        spelling = text[start:end]
        if re.fullmatch(r'\s*-?\d[\w]*\s*', spelling):
            # An integer argument of a value generic is a value, not a type.
            return
        sites.append(Site(start, end, kind, spelling, context))
        # Generic arguments of a nominal spelling are sites of their own.
        head = re.match(r'[\w.`:]+<', spelling)
        if head:
            index = start + head.end()
            while index < end - 1:
                arg_end = scan_type_end(text, index, ',')
                if arg_end > end - 1:
                    break
                lead = len(text[index:arg_end]) - len(text[index:arg_end].lstrip())
                add(index + lead, arg_end, kind + '-arg', context)
                index = arg_end
                while index < end and text[index] in ', ':
                    index += 1
                if text[index:index + 1] == '>' or index >= end - 1:
                    break

    for match in re.finditer(r'static func\s+`?\w+`?\s*\(', text):
        if not mask[match.start()]:
            continue
        index = match.end()
        context = 'edge' if re.search(r'@(Transition|Route|Restoration)', text[max(0, match.start() - 300):match.start()].split('\n\n')[-1]) else 'function'
        depth_end = index
        depth = 1
        while depth and depth_end < len(text):
            if text[depth_end] == '(':
                depth += 1
            elif text[depth_end] == ')':
                depth -= 1
            depth_end += 1
        params = text[index:depth_end - 1]
        offset = index
        for param in re.finditer(r'(?:^|,)\s*(?:`?\w+`?\s+)?`?\w+`?\s*:\s*' + MODIFIERS, params):
            type_start = offset + param.end()
            type_end = scan_type_end(text, type_start, ',=')
            add(type_start, type_end, 'param', context)
        rest = depth_end
        throws = re.match(r'\s*(?:async\s+)?throws\(', text[rest:])
        if throws:
            type_start = rest + throws.end()
            type_end = scan_type_end(text, type_start, '')
            add(type_start, type_end, 'throws', context)
            rest = type_end + 1
        arrow = re.match(r'\s*(?:throws\s*)?->\s*', text[rest:])
        if arrow:
            type_start = rest + arrow.end()
            type_end = scan_type_end(text, type_start, '{\n')
            add(type_start, type_end, 'return', context)
    for match in re.finditer(r'typealias\s+`?\w+`?(?:<[^>=]*>)?\s*=\s*', text):
        type_end = scan_type_end(text, match.end(), ';\n')
        indent = text.rfind('\n', 0, match.start())
        nested = text[indent + 1:match.start()].startswith('        ') or text[indent + 1:match.start()].lstrip().startswith(('enum', '@'))
        add(match.end(), type_end, 'alias', 'nested' if nested else ('file' if text[indent + 1:match.start()] == '' else 'schema'))
    for match in re.finditer(r'\bcase\s+`?\w+`?\(', text):
        if not mask[match.start()]:
            continue
        type_end = scan_type_end(text, match.end(), ',=')
        line_start = text.rfind('\n', 0, match.start()) + 1
        phase = re.match(r'    (?:@[\w.]+(?:\([^)\n]*\))?\s+)*case', text[line_start:])
        add(match.end(), type_end, 'phase-case' if phase and text[line_start:].startswith('    ') and not text[line_start:].startswith('     ') else 'case', 'case')
    sites.sort(key=lambda site: (site.start, -site.end))
    unique = []
    seen = set()
    for site in sites:
        if (site.start, site.end) not in seen and site.text.strip():
            seen.add((site.start, site.end))
            unique.append(site)
    return unique


def schema_body_start(text):
    match = re.search(r'@StateMachine\([^)]*\)\s*\n?\s*(?:nonisolated\s+)?enum\s+\w+[^{]*\{\n', text)
    return match.end() if match else None


def site_role(text, site):
    """`phase` for a phase payload, `shape` for the result shape of an edge (its `Change`, `Advance`, or router choice
    and what they name), else `value`."""
    if site.kind in ('phase-case',):
        return 'phase'
    if core_name(site.text) in phase_payloads(text) and site.kind in ('param', 'return', 'return-arg', 'phase-case'):
        return 'phase'
    if site.context == 'edge' and (site.kind == 'return-arg' or (site.kind == 'return' and re.match(r'\s*(Self\.|\w+\.)?(Route|Change|Advance)\b', site.text))):
        return 'shape'
    if core_name(site.text) in phase_payloads(text) and site.kind in ('param', 'return', 'return-arg', 'phase-case'):
        return 'phase'
    return 'value'


def is_simple_name(spelling):
    return re.fullmatch(r'`?[A-Za-z_]\w*`?', spelling.strip()) is not None


def declared_types(text):
    return set(re.findall(r'(?:struct|enum|class|protocol|actor)\s+`?(\w+)`?', text))


def schema_types(text):
    """Types declared inside a schema's body, which `Self.` and the schema's name can qualify."""
    names = set()
    for start, end in schema_lines(text):
        body = '\n'.join(text.split('\n')[start:end - 1])
        names |= declared_types(body)
    return names


# ---------------------------------------------------------------------------------------------------------------------
# Rewrites. Each yields candidate mutations of a text; a mutation is (new text, info). `info` carries the rewrite's
# kind, the site it changed, and, for a distinction rewrite, the renaming that maps the control onto the variant.

class Rewrite:
    def __init__(self, name, kind, function, doc):
        # A mutation whose insertion found no place to go produces no candidate.
        self.name, self.kind, self.doc = name, kind, doc
        self.function = lambda text, rng: [m for m in function(text, rng) if m and m[0]]


REWRITES = []


def rewrite(name, kind, doc):
    def register(function):
        REWRITES.append(Rewrite(name, kind, function, doc))
        return function
    return register


def at_sites(text, predicate, transform, extra=None):
    """Mutations replacing one site each; `transform` returns the new spelling or None."""
    results = []
    for site in type_sites(text):
        if not predicate(site):
            continue
        spelling = transform(site)
        if spelling is None or spelling == site.text:
            continue
        new = text[:site.start] + spelling + text[site.end:]
        if extra:
            new = extra(new, site)
        results.append((new, dict(site=repr(site), role=site_role(text, site))))
    return results


def insert_in_schema(text, declaration, position=None):
    """Inserts a member at the top of the schema that contains `position`, or of the first schema."""
    starts = [m.end() for m in re.finditer(r'@StateMachine\([^)]*\)\s*(?:@\w+(?:\([^)]*\))?\s*)*(?:\w+\s+)*enum\s+`?\w+`?[^{]*\{\n', text)]
    if not starts:
        return None
    start = starts[0]
    if position is not None:
        start = max((s for s in starts if s <= position), default=starts[0])
    return text[:start] + '    ' + declaration + '\n' + text[start:]


def available_above_floor(text, declaration):
    """A file-scope declaration with the availability of a schema declared above the deployment floor."""
    versions = [v for v in re.findall(r'@available\(macOS (\d+(?:\.\d+)?)', text) if float(v) > 13]
    if versions and re.match(r'(typealias|extension)\b', declaration):
        return f'@available(macOS {max(versions, key=float)}, *)\n' + declaration
    return declaration


def insert_at_file_scope(text, declaration):
    declaration = available_above_floor(text, declaration)
    match = re.search(r'^import StateMachine\n', text, re.M)
    index = match.end() if match else 0
    return text[:index] + declaration + '\n' + text[index:]


def schema_of(text, site_start):
    best = None
    for match in re.finditer(r'@StateMachine\([^)]*\)\s*\n?\s*(?:\w+\s+)*enum\s+`?(\w+)`?', text):
        if match.start() < site_start:
            best = match.group(1)
    return best


def within_schema(text, site):
    """Whether a site lies in a schema's body: an extension after the schema is outside it, and cannot see its members."""
    line = text.count('\n', 0, site.start) + 1
    return site.context != 'file' and any(a <= line <= b for a, b in schema_lines(text))


not_generated = lambda site: not re.match(r'(Self\.)?(Route|Effect|Change|Advance|Restoration)\b', site.text.strip()) and not re.search(r'Request\b', site.text)


@rewrite('paren', 'eq', 'Parentheses change nothing')
def _(text, rng):
    return at_sites(text, lambda s: s.kind not in ('phase-case',) or True, lambda s: f'({s.text})')


@rewrite('paren2', 'eq', 'Parentheses change nothing')
def _(text, rng):
    return at_sites(text, lambda s: True, lambda s: f'(({s.text}))')


def backtick_last(spelling):
    names = list(re.finditer(r'(?<![`\w.])([A-Za-z_]\w*)(?![`\w])', spelling))
    names = [m for m in names if m.group(1) not in KEYWORDS and not spelling[m.end():].lstrip().startswith(':')]
    if not names:
        return None
    m = names[-1]
    return spelling[:m.start()] + f'`{m.group(1)}`' + spelling[m.end():]


@rewrite('paren-base', 'eq', '`(Self).Draft` are the payload `Draft`')
def _(text, rng):
    """Parenthesizes the base of a member type: `(Self).Draft`, `(Route).Choose`, `(Effect).Begin`, `(Fetch).Output`."""
    def transform(site):
        match = re.match(r'(\s*)(`?[A-Za-z_]\w*`?)(\.\S)', site.text)
        if not match or match.group(2) in ('Swift', 'StateMachine'):
            return None
        return site.text[:match.start(2)] + f'({match.group(2)})' + site.text[match.end(2):]
    return at_sites(text, lambda s: True, transform)


@rewrite('backtick-type', 'eq', 'backticks change no name')
def _(text, rng):
    return at_sites(text, lambda s: True, lambda s: backtick_last(s.text))


@rewrite('self-qualify', 'eq', 'may be written `Draft`, `Self.Draft`, or `Approval.Draft`')
def _(text, rng):
    def transform(site):
        if not is_simple_name(site.text) or core_name(site.text) not in schema_types(text) or site.context in ('nested',):
            return None
        return 'Self.' + site.text.strip()
    return at_sites(text, lambda s: within_schema(text, s) and s.kind != 'case', transform)


@rewrite('schema-qualify', 'eq', 'may be written `Draft`, `Self.Draft`, or `Approval.Draft`')
def _(text, rng):
    def transform(site):
        if not is_simple_name(site.text) or core_name(site.text) not in schema_types(text):
            return None
        schema = schema_of(text, site.start)
        return f'{schema}.{site.text.strip()}' if schema else None
    return at_sites(text, lambda s: within_schema(text, s), transform)


def alias_rewrite(text, make, predicate=lambda s: True, phases=False):
    """Mutations that spell one site through an alias. A phase payload spelled through an alias is a documented limit,
    so only `alias-local` tries those sites."""
    results = []
    for site in type_sites(text):
        if not within_schema(text, site) or not predicate(site) or not not_generated(site):
            continue
        if not phases and site_role(text, site) == 'phase':
            continue
        made = make(text, site)
        if made is None:
            continue
        spelling, declaration, scope = made
        # A helper name an earlier rewrite already declared gets a fresh suffix, so applying a rewrite twice declares
        # two helpers rather than one twice.
        taken = identifier_tokens(text)
        # Only the helpers this declaration declares; a name an earlier rewrite declared stays as it is.
        for helper in sorted(set(re.findall(r'\b(?:enum|struct|typealias)\s+(Fuzz\w+)', declaration)), key=len, reverse=True):
            if helper in taken:
                fresh = next(f'{helper}{n}' for n in range(2, 1000) if f'{helper}{n}' not in taken)
                declaration = re.sub(r'\b' + helper + r'\b', fresh, declaration)
                spelling = re.sub(r'\b' + helper + r'\b', fresh, spelling)
        # A site inside `Input` or an operation's namespace reads that namespace's own types first; the alias, declared
        # at the schema's scope or outside it, must name them through the namespace.
        schema = schema_of(text, site.start)
        for namespace in re.finditer(r'^    (?:@\w+(?:\([^\n]*\))?\s+)?enum\s+(\w+)[^{\n]*\{', text, re.M):
            body = body_of(text, namespace)
            if namespace.end() <= site.start < namespace.end() + len(body):
                members = scope_members(text, schema, namespace.group(1)) if schema else set()
                qualified = qualify_in(site.text, members, namespace.group(1))
                if qualified != site.text:
                    declaration = declaration.replace(site.text, qualified if scope == 'schema' else f'{schema}.{qualified}')
        new = text[:site.start] + spelling + text[site.end:]
        new = insert_in_schema(new, declaration, site.start) if scope == 'schema' else insert_at_file_scope(new, declaration)
        if new:
            results.append((new, dict(site=repr(site), role=site_role(text, site))))
    return results


def qualify_for_file_scope(text, site):
    schema = schema_of(text, site.start)
    body = '\n'.join('\n'.join(text.split('\n')[a:b - 1]) for a, b in schema_lines(text))
    members = schema_types(text) | set(re.findall(r'typealias\s+(\w+)', body))
    def qualify(match):
        name = match.group(1)
        before = site.text[:match.start()]
        if before.endswith('.') or name not in members or name in STANDARD:
            return match.group(0)
        return f'{schema}.{name}'
    return re.sub(r'(?<![\w`.])([A-Za-z_]\w*)', qualify, site.text)


@rewrite('alias-local', 'eq', 'With `typealias Unit = Void` in the schema')
def _(text, rng):
    return alias_rewrite(text, lambda t, s: ('FuzzAlias', f'typealias FuzzAlias = {s.text}', 'schema'), phases=True)


@rewrite('alias-generic', 'eq', 'A generic alias the schema declares reads with its arguments')
def _(text, rng):
    return alias_rewrite(text, lambda t, s: (f'FuzzIdentity<{s.text}>', 'typealias FuzzIdentity<FuzzT: ~Copyable> = FuzzT', 'schema'))


@rewrite('alias-chain', 'eq', 'An alias chain of any length reads through to the type it names')
def _(text, rng):
    return alias_rewrite(text, lambda t, s: ('FuzzChain0', f'typealias FuzzChain0 = FuzzChain1\n    typealias FuzzChain1 = FuzzChain2\n    typealias FuzzChain2 = {s.text}', 'schema'))


@rewrite('alias-nested', 'eq', 'inside the nongeneric types the schema declares')
def _(text, rng):
    return alias_rewrite(text, lambda t, s: ('FuzzSpace.Alias', f'enum FuzzSpace {{ typealias Alias = {s.text} }}', 'schema'))


@rewrite('alias-file', 'eq', 'an alias declared outside the schema is invisible to the macro')
def _(text, rng):
    def make(t, s):
        # A site inside `Input` or an operation's namespace reads that namespace's members first, an extension's
        # among them; at file scope the alias names them through the namespace.
        spelled = s.text
        schema = schema_of(t, s.start)
        for namespace in re.finditer(r'^    (?:@\w+(?:\([^\n]*\))?\s+)?enum\s+(\w+)[^{\n]*\{', t, re.M):
            if schema and namespace.end() <= s.start < namespace.end() + len(body_of(t, namespace)):
                spelled = qualify_in(spelled, scope_members(t, schema, namespace.group(1)), namespace.group(1))
        return ('FuzzOutside', f'typealias FuzzOutside = {qualify_for_file_scope(t, Site(s.start, s.end, s.kind, spelled, s.context))}', 'file')
    return alias_rewrite(text, make)


@rewrite('alias-base', 'eq', 'An alias that names a type by a path of names')
def _(text, rng):
    def make(t, s):
        match = re.fullmatch(r'(`?[A-Za-z_]\w*`?)\.(`?\w+`?)', s.text.strip())
        if not match or match.group(1) in ('Self', 'Swift', 'Route', 'Effect') or core_name(match.group(1)) not in declared_types(t) | {'Input'}:
            return None
        return (f'FuzzBase.{match.group(2)}', f'typealias FuzzBase = {match.group(1)}', 'schema')
    return alias_rewrite(text, make)


@rewrite('alias-base-paren', 'eq', '`(Namespace)`, or another such alias')
def _(text, rng):
    def make(t, s):
        match = re.fullmatch(r'(`?[A-Za-z_]\w*`?)\.(`?\w+`?)', s.text.strip())
        if not match or match.group(1) in ('Self', 'Swift', 'Route', 'Effect') or core_name(match.group(1)) not in declared_types(t) | {'Input'}:
            return None
        return (f'FuzzBase.{match.group(2)}', f'typealias FuzzBase = ({match.group(1)})', 'schema')
    return alias_rewrite(text, make)


def replace_standard(spelling, template):
    def replace(match):
        name = match.group(1)
        before = spelling[:match.start()]
        if before.endswith(('.', ':')) or name not in STANDARD or name in ('Sendable', 'Error', 'Equatable', 'Hashable'):
            return match.group(0)
        return template.format(name)
    return re.sub(r'(?<![\w`.:])([A-Za-z_]\w*)(?![\w`])', replace, spelling)


@rewrite('module-selector', 'eq', '`Swift::Int` and `Swift::Array<Swift::Int>` have values')
def _(text, rng):
    return at_sites(text, lambda s: True, lambda s: replace_standard(s.text, 'Swift::{}'))


@rewrite('swift-dot', 'eq', 'a name read through a `Swift` the schema does not declare')
def _(text, rng):
    return at_sites(text, lambda s: True, lambda s: replace_standard(s.text, 'Swift.{}'))


def desugar(spelling):
    stripped = spelling.strip()
    match = re.fullmatch(r'\[([^\[\]:]+)\]', stripped)
    if match and not re.search(r'\sof\s', match.group(1)):
        return f'Array<{match.group(1).strip()}>'
    match = re.fullmatch(r'\[([^\[\]:]+):([^\[\]]+)\]', stripped)
    if match:
        return f'Dictionary<{match.group(1).strip()}, {match.group(2).strip()}>'
    match = re.fullmatch(r'([\w.`]+)\?', stripped)
    if match:
        return f'Optional<{match.group(1)}>'
    match = re.fullmatch(r'Array<(.+)>', stripped)
    if match:
        return f'[{match.group(1)}]'
    return None


@rewrite('sugar', 'eq', '`[Detail]` and `Swift::Array<Detail>` are one type')
def _(text, rng):
    return at_sites(text, lambda s: True, lambda s: desugar(s.text))


@rewrite('void-spelling', 'eq', '`()`, `Swift::Void`, and `Swift::Never` always name the standard library')
def _(text, rng):
    swap = {'Void': '()', '()': 'Swift::Void', 'Swift::Void': 'Void'}
    return at_sites(text, lambda s: s.text.strip() in swap, lambda s: swap[s.text.strip()])


@rewrite('tuple-wildcard', 'eq', "A tuple element's `_` is no label")
def _(text, rng):
    def transform(site):
        stripped = site.text.strip()
        if stripped == '()':
            return '(_: ())'
        if stripped.startswith('(') and stripped.endswith(')') and ',' in stripped and ':' not in stripped and '->' not in stripped:
            return '(_: ' + stripped[1:]
        return None
    return at_sites(text, lambda s: True, transform)


@rewrite('function-attribute-order', 'eq', '`@Sendable @MainActor () -> Int` and `@MainActor @Sendable () -> Int`')
def _(text, rng):
    def transform(site):
        match = re.match(r'(\s*)(@\w+)\s+(@\w+)\s+\(', site.text)
        if not match:
            if re.match(r'\s*@Sendable\s+\(', site.text):
                return site.text.replace('@Sendable', '@Sendable @Sendable', 1) if False else None
            return None
        return site.text[:match.start(2)] + match.group(3) + ' ' + match.group(2) + site.text[match.end(3):]
    return at_sites(text, lambda s: True, transform)


@rewrite('composition-order', 'eq', '`A & B` and `B & A`')
def _(text, rng):
    def transform(site):
        stripped = site.text.strip()
        match = re.fullmatch(r'(any\s+)?([^&<>()]+(?:&[^&<>()]+)+)', stripped)
        if not match:
            return None
        members = [member.strip() for member in match.group(2).split('&')]
        return (match.group(1) or '') + ' & '.join(reversed(members))
    return at_sites(text, lambda s: True, transform)


@rewrite('trivia', 'eq', 'apart from comments, spacing, redundant backticks')
def _(text, rng):
    def transform(site):
        spelling = site.text.replace('<', '< /* fuzz */ ').replace(', ', ' /* fuzz */ ,\n        ')
        return f'/* fuzz */ {spelling} /* fuzz */'
    return at_sites(text, lambda s: True, transform)


@rewrite('attribute-trivia', 'eq', 'Write each reference in an attribute exactly as shown')
def _(text, rng):
    results = []
    for match in re.finditer(r'@(Transition|Route|Operation|Restoration|Active|StateMachine)\(([^()\n]*(?:\([^()\n]*\)[^()\n]*)*)\)', text):
        arguments = match.group(2)
        spaced = re.sub(r':\s*', ': /* fuzz */ ', arguments).replace(', ', ' /* fuzz */ ,\n        ')
        new = text[:match.start(2)] + '\n        ' + spaced + '\n    ' + text[match.end(2):]
        results.append((new, dict(site=match.group(0), role='attribute')))
    return results


@rewrite('module-attribute', 'eq', 'An attribute may include its module name, as in `@StateMachine.Transition`')
def _(text, rng):
    results = []
    for match in re.finditer(r'@(Transition|Route|Operation|Restoration|Active|Initial|Terminal|Event)\b', text):
        new = text[:match.start()] + '@StateMachine.' + match.group(1) + text[match.end():]
        results.append((new, dict(site=match.group(0), role='attribute')))
    return results


def member_blocks(text):
    """The schema body's member declarations, each with its attributes and comments, as lists of lines."""
    start = schema_body_start(text)
    if start is None:
        return None, None, []
    close = re.search(r'^\}', text[start:], re.M)
    end = start + close.start()
    blocks, current, pending = [], None, []
    open_attribute = 0
    for line in text[start:end].split('\n'):
        if not line.strip():
            continue
        if open_attribute:
            pending.append(line)
            open_attribute += line.count('(') - line.count(')')
            continue
        top = line.startswith('    ') and not line.startswith('     ')
        stripped = line.strip()
        if top and (stripped.startswith((')', '}', ']')) or stripped.startswith('->')):
            current.append(line)
        elif top and (stripped.startswith('//') or re.fullmatch(r'@[\w.]+(\(.*\))?', stripped)):
            pending.append(line)
        elif top and re.match(r'@[\w.]+\(', stripped) and stripped.count('(') > stripped.count(')'):
            pending.append(line)
            open_attribute = stripped.count('(') - stripped.count(')')
        elif top:
            current = pending + [line]
            pending = []
            blocks.append(current)
        elif current is not None:
            current.append(line)
    return start, end, blocks


@rewrite('reorder-members', 'eq', 'Swift: member order does not change a type')
def _(text, rng):
    start, end, blocks = member_blocks(text)
    if len(blocks) < 2:
        return []
    pieces = ['\n'.join(block) for block in blocks]
    results = []
    for order in (list(reversed(pieces)), pieces[1:] + pieces[:1]):
        new = text[:start] + '\n\n'.join(order) + '\n' + text[end:]
        results.append((new, dict(site='members', role='value')))
    return results


@rewrite('reorder-cases', 'eq', 'Every input case in declaration order')
def _(text, rng):
    '''Reverses the cases of `Input` and of `Scope`, in one `case` list or across several.'''
    results = []
    for name in ('Input', 'Scope'):
        opened = re.search(r'enum\s+' + name + r'\b[^{]*\{', text)
        if not opened:
            continue
        body = body_of(text, opened)
        lines = [l for l in re.findall(r'\bcase\s+([^\n;}]+)', body)]
        if len(lines) == 1:
            items = [i.strip() for i in split_top(lines[0])]
            if len(items) < 2:
                continue
            new_body = body.replace(lines[0].rstrip(), ', '.join(reversed(items)), 1)
        else:
            # Each case line with the attributes before it, reversed as blocks.
            blocks = re.findall(r'((?:[ \t]*@[^\n]*\n)*[ \t]*case [^\n]*\n?)', body)
            if len(blocks) < 2:
                continue
            joined = ''.join(blocks)
            if joined not in body:
                continue
            new_body = body.replace(joined, ''.join(b if b.endswith('\n') else b + '\n' for b in reversed(blocks)), 1)
        new = text[:opened.end()] + new_body + text[opened.end() + len(body):]
        results.append((new, dict(site=f'{name} cases reversed', role='value')))
    return results


@rewrite('reorder-lists', 'eq', 'attribute lists name sets of declarations')
def _(text, rng):
    '''Reverses the list an attribute argument spells, as `starts: [A.self, B.self]`.'''
    results = []
    for match in re.finditer(r'\b(starts|emits|cancels|invalidates|requires|activeIn|allows|only|from|in):\s*\[([^\[\]]+)\]', text):
        items = [i.strip() for i in match.group(2).split(',')]
        if len(items) < 2:
            continue
        new = text[:match.start(2)] + ', '.join(reversed(items)) + text[match.end(2):]
        results.append((new, dict(site=f'{match.group(1)} reversed', role='value')))
    return results


@rewrite('unrelated-declarations', 'eq', 'Swift: an unused member changes no other declaration')
def _(text, rng):
    results = []
    for declaration in ('private static func fuzzHelper() -> Int { 0 }', 'typealias FuzzUnused = [Swift::Int]',
                        'struct FuzzUnrelated: Sendable { let value = 0 }', '// fuzz: a comment between members'):
        new = insert_in_schema(text, declaration)
        if new:
            results.append((new, dict(site=declaration, role='value')))
    return results


def shared_parameters(text, source):
    results = []
    for site in type_sites(text):
        if site.kind != 'param' or site.context != 'edge':
            continue
        opening = text.rfind('(', 0, site.start)
        first = not text[opening + 1:site.start].count(',')
        if first != source or (source and site_role(text, site) != 'phase'):
            continue
        before = text[:site.start]
        if re.search(r'(borrowing|consuming|__owned|__shared|sending|@escaping|inout)\s+$', before):
            continue
        new = before + '__shared ' + text[site.start:]
        results.append((new, dict(site=repr(site), role=site_role(text, site))))
    return results


@rewrite('shared-param', 'eq', "repeats the payload's ownership")
def _(text, rng):
    return shared_parameters(text, source=False)


@rewrite('shared-source', 'eq', 'with the passing convention it needs')
def _(text, rng):
    return shared_parameters(text, source=True)


@rewrite('backtick-declaration', 'eq', 'redundant backticks are allowed and change no name')
def _(text, rng):
    results = []
    for match in re.finditer(r'\b(case|static func|struct|enum|typealias)\s+([A-Za-z_]\w*)\b', text):
        if match.group(2) in KEYWORDS or match.group(2) in ('Input', 'Scope'):
            continue
        new = text[:match.start(2)] + f'`{match.group(2)}`' + text[match.end(2):]
        results.append((new, dict(site=match.group(0), role='value')))
    return results


@rewrite('explicit-defaults', 'eq', 'The macro declares the omitted aliases as `Void`')
def _(text, rng):
    results = []
    for match in re.finditer(r'(@Operation\([^\n]*\)\s*\n\s*enum\s+\w+\s*)\{([^{}]*)\}', text):
        body = match.group(2)
        for alias, value in (('Output', 'Void'), ('Failure', 'Never'), ('Input', 'Void')):
            if re.search(rf'typealias\s+{alias}\b', body):
                continue
            new = text[:match.end(1)] + '{ typealias ' + alias + ' = ' + value + ('; ' if body.strip() else '') + body.strip() + ' }' + text[match.end():]
            results.append((new, dict(site=f'{alias} = {value}', role='value')))
    for match in re.finditer(r'(@Event\s*\n\s*enum\s+\w+\s*)\{\s*\}', text):
        new = text[:match.end(1)] + '{ typealias Payload = Void }' + text[match.end():]
        results.append((new, dict(site='Payload = Void', role='value')))
    return results


@rewrite('initial-default-spelling', 'eq', 'the call may name it any of those ways')
def _(text, rng):
    results = []
    for match in re.finditer(r'@Initial(?:\s+@Terminal)?\s+case\s+\w+\(([^=()]+?)\s*=\s*([\w.]+)\(\)\)', text):
        payload, call = match.group(1).strip(), match.group(2)
        schema = schema_of(text, match.start())
        bare = core_name(payload)
        callee = call.split('.')[-1]
        for new_call in (f'Self.{callee}', f'{schema}.{callee}', callee):
            if new_call == call:
                continue
            new = text[:match.start(2)] + new_call + text[match.end(2):]
            results.append((new, dict(site=f'default {new_call}()', role='value')))
        if callee == bare:
            # A public or package schema's default needs a factory of its access, as the guide says.
            access = re.search(r'@StateMachine\([^)]*\)\s*(?:@\w+(?:\([^)]*\))?\s*)*(public|package)\s', text[:match.start()])
            factory = f'{access.group(1) + " " if access else ""}static func fuzzMake{bare}() -> {bare} {{ {bare}() }}'
            new = text[:match.start(2)] + f'fuzzMake{bare}' + text[match.end(2):]
            new = insert_in_schema(new, factory, match.start())
            results.append((new, dict(site='factory default', role='value')))
    return results


# --- Distinction rewrites ---------------------------------------------------------------------------------------------

def identifier_tokens(text):
    mask = code_mask(text)
    return {m.group(1) for m in re.finditer(r'(?<![\w`])`?([^\W\d]\w*)`?', text) if mask[m.start()]}


def rename(text, old, new):
    """Renames the identifier `old` everywhere outside comments and string literals."""
    mask = code_mask(text)
    pieces, last = [], 0
    for match in re.finditer(r'(?<![\w`])(`?)' + re.escape(old) + r'\1(?![\w`])', text):
        if not mask[match.start()]:
            continue
        pieces.append(text[last:match.start()])
        pieces.append(new if not match.group(1) or new.startswith('`') else f'`{new}`')
        last = match.end()
    pieces.append(text[last:])
    return ''.join(pieces)


def declared_inside_schema(text, name):
    """Whether the declaration of `name` lies in a schema's body, where the guide requires names in NFC."""
    spans = schema_lines(text)
    for match in re.finditer(r'\b(?:struct|enum|class|protocol|typealias|func|case|var|let)\s+`?' + re.escape(name) + r'\b', text):
        line = text.count('\n', 0, match.start()) + 1
        if any(a <= line <= b for a, b in spans):
            return True
    return False


def renamable(text):
    """Declared names whose generated derivatives never appear in client code: types other than operations, events,
    Input, and Scope; aliases other than an operation's or event's; static functions no attribute marks."""
    names = []
    operations = set(re.findall(r'@(?:Operation|Event)[^\n]*\n\s*enum\s+`?(\w+)', text))
    for match in re.finditer(r'\b(struct|enum|class|protocol)\s+`?(\w+)`?', text):
        name = match.group(2)
        if name in operations or name in ('Input', 'Scope', 'Route', 'Effect') or name in schema_names(text):
            continue
        names.append(('type', name))
    for match in re.finditer(r'typealias\s+`?(\w+)`?', text):
        if match.group(1) not in ('Input', 'Output', 'Failure', 'Key', 'Payload'):
            names.append(('alias', match.group(1)))
    for match in re.finditer(r'(@\w+[^\n]*\n\s*)?(?:fileprivate\s+|private\s+)?static func\s+`?(\w+)`?', text):
        if not match.group(1):
            names.append(('function', match.group(2)))
    seen, unique = set(), []
    for kind, name in names:
        if name not in seen and not name.startswith('Fuzz') and not name.startswith('fuzz'):
            seen.add(name)
            unique.append((kind, name))
    return unique


CYRILLIC = {'a': '\u0430', 'e': '\u0435', 'o': '\u043e', 'p': '\u0440', 'c': '\u0441', 'x': '\u0445', 'y': '\u0443',
            'K': '\u041a', 'M': '\u041c', 'H': '\u041d', 'T': '\u0422', 'B': '\u0412', 'C': '\u0421', 'A': '\u0410',
            'E': '\u0415', 'O': '\u041e', 'P': '\u0420'}


def hash_index(text, count):
    return int(hashlib.sha256(text.encode()).hexdigest(), 16) % count


def collide_targets(flavor, a):
    """(name A is first renamed to, the colliding spelling for B), or None."""
    if flavor == 'nfd':
        return a + '\u00e9', a + 'e\u0301'
    if flavor == 'kelvin':
        return a + 'K', a + '\u212a'
    if flavor == 'varia':
        return a, '\u1fef' + a
    if flavor == 'cyrillic':
        for index, char in enumerate(a):
            if char in CYRILLIC:
                return a, a[:index] + CYRILLIC[char] + a[index + 1:]
        return None
    if flavor == 'case':
        flipped = a[0].swapcase() + a[1:]
        return (a, flipped) if flipped != a else None
    if flavor == 'raw':
        return a, f'`{a}.Fuzz`'
    return None


def make_collide(flavor):
    def function(text, rng):
        names = renamable(text)
        tokens = identifier_tokens(text)
        paths = sorted(set(re.findall(r'(?<![\w.`])([A-Z]\w*\.[A-Z]\w*)(?![\w`])', text)))
        results = []
        for kind_b, b in names:
            for kind_a, a in names:
                if a == b:
                    continue
                if flavor == 'raw':
                    # A raw identifier spelled as a path the schema also reads as a path to one of its members:
                    # B is renamed to the raw identifier `N.P` beside the nested N.P (A plays no part but its turn).
                    members = declared_types(text) - set(schema_names(text))
                    usable = [p for p in paths if p.split('.')[0] in members and b not in p.split('.')]
                    if not usable or kind_b not in ('type', 'alias') or b in phase_payloads(text):
                        continue
                    targets = (a, f'`{usable[hash_index(a, len(usable))]}`')
                else:
                    targets = collide_targets(flavor, a)
                if not targets:
                    continue
                a_name, b_name = targets
                if b_name.strip('`') in tokens or (a_name != a and a_name in tokens):
                    continue
                control = rename(text, a, a_name) if a_name != a else text
                variant = rename(control, b, b_name)
                results.append(((kind_a, kind_b), (variant, dict(site=f'{kind_b} {b} -> {b_name!r} beside {kind_a} {a_name!r}', role='value',
                                              control=control, mapping={b: b_name.strip('`')},
                                              inside=declared_inside_schema(text, b)))))
        # Every pairing of kinds first, then the rest, in an order fixed by the case's seed.
        rng.shuffle(results)
        firsts, rest, seen_kinds = [], [], set()
        for kinds, mutation in results:
            (rest if kinds in seen_kinds else firsts).append(mutation)
            seen_kinds.add(kinds)
        return (firsts + rest)[:12]
    return function


# Swift tells two names apart by their bytes; each flavor makes B collide with A in another normal form.
for _flavor, _doc in [('nfd', 'canonical equivalence: an accented letter as one character and as a letter and a combining mark'),
                      ('kelvin', 'compatibility: the Kelvin sign, which NFC maps to K'),
                      ('varia', 'U+1FEF GREEK VARIA, which NFC maps to a backtick'),
                      ('cyrillic', 'a confusable letter of another script, distinct in every normal form'),
                      ('case', 'names differing only in case'),
                      ('raw', 'a raw identifier spelled like a path the schema also reads, `N.P` against N.P')]:
    REWRITES.append(Rewrite(f'collide-{_flavor}', 'dist', make_collide(_flavor), _doc))


@rewrite('rename-raw', 'dist', 'a raw identifier names a type as any other identifier does')
def _(text, rng):
    """Renames a type or alias to a raw identifier that contains a period, as `N.P` written in backticks."""
    results = []
    for kind, name in renamable(text):
        if kind not in ('type', 'alias') or name in phase_payloads(text):
            continue
        raw = f'{name}.Raw'
        control = text
        variant = rename(text, name, f'`{raw}`')
        results.append((variant, dict(site=f'{kind} {name} -> `{raw}`', role='value', control=control, mapping={name: raw},
                                      inside=declared_inside_schema(text, name))))
    return results


@rewrite('shadow-alias', 'dist', 'A spelling means what it means where it is written')
def _(text, rng):
    """An operation's `Output` alias that names a schema type, shadowed by a type of that name nested in the namespace:
    the alias names the nested type, as the control spells it through another name."""
    results = []
    for match in re.finditer(r'(@Operation\([^\n]*\)\s*\n\s*enum\s+\w+\s*\{)([^{}]*)\}', text):
        body = match.group(2)
        alias = re.search(r'typealias\s+Output\s*=\s*(\w+)\s*(?=[;\n}])', body)
        if not alias or alias.group(1) in STANDARD:
            continue
        name = alias.group(1)
        variant_body = f'\n        struct {name}: Sendable {{}}' + body
        control_body = f'\n        struct FuzzShadow: Sendable {{}}' + body[:alias.start()] + 'typealias Output = FuzzShadow' + body[alias.end():]
        # Client code builds the schema's type of that name, which neither program's output takes any more.
        variant = schema_only(text[:match.start(2)] + variant_body + text[match.end(2):])
        control = schema_only(text[:match.start(2)] + control_body + text[match.end(2):])
        results.append((variant, dict(site=alias.group(0), role='value', control=control, mapping={'FuzzShadow': name}, behaviour=False)))
    return results


# --- Breaking rewrites -------------------------------------------------------------------------------------------------

@rewrite('router-returns-void', 'break', 'A router with no candidate edge returns `Never` and must throw')
def _(text, rng):
    results = []
    aliases = re.findall(r'typealias\s+(\w+)\s*=\s*(?:Swift::)?Never\b', text)
    routers = list(re.finditer(r'(@Route\([^\n]*\)\s*\n\s*fileprivate static func \w+\([^)]*\)\s*throws\([^)]*\)\s*->\s*)(\w+)', text))
    for match in routers:
        if match.group(2) != 'Never' and match.group(2) not in aliases:
            continue
        for alias_name, scope in [('FuzzVoid', 'schema'), ('FuzzVoid', 'file')]:
            new = text[:match.start(2)] + alias_name + text[match.end(2):]
            new = insert_in_schema(new, f'typealias {alias_name} = Void') if scope == 'schema' else insert_at_file_scope(new, f'typealias {alias_name} = Void')
            results.append((new, dict(site=f'{match.group(2)} -> {alias_name} ({scope})', role='value')))
    # Two rejecting routers: the first returns a file-scope alias of Never, the second a file-scope alias of Void whose
    # name differs from the first's only in encoding (and, as a control, by another name).
    never = [m for m in routers if m.group(2) == 'Never' or m.group(2) in aliases]
    if len(never) >= 2:
        first, second = never[0], never[1]
        for void_name in ('Nade\u0301', 'Other'):
            new = text[:second.start(2)] + void_name + text[second.end(2):]
            new = new[:first.start(2)] + 'Nad\u00e9' + new[first.end(2):]
            new = insert_at_file_scope(new, f'typealias Nad\u00e9 = Never\ntypealias {void_name} = Void')
            results.append((new, dict(site=f'first -> file alias of Never, second -> file alias {void_name!r} of Void', role='value')))
    return results


@rewrite('scope-property', 'break', 'Write each reference in an attribute exactly as shown: `Input.approve`, `Scope.account`')
def _(text, rng):
    results = []
    scope = re.search(r'enum Scope\s*\{', text)
    if not scope:
        return results
    cases = re.findall(r'case\s+(\w+)', text[scope.end():text.find('\n    }', scope.end())])
    references = list(re.finditer(r'(invalidates:|requires:|scope:)\s*\[?\s*Scope\.(\w+)', text))
    for number, match in enumerate(references):
        for target in cases:
            for flavor in ('fresh', 'nfd', 'case'):
                base, chosen = text, target
                if flavor == 'nfd':
                    # The case spelled with a precomposed letter, the property with a letter and a combining mark.
                    chosen = target + '\u00e9'
                    base = rename(text, target, chosen)
                    name = target + 'e\u0301'
                elif flavor == 'case':
                    name = target[0].upper() + target[1:]
                else:
                    name = 'fuzzAlias'
                if name in identifier_tokens(base):
                    continue
                spot = list(re.finditer(r'(invalidates:|requires:|scope:)\s*\[?\s*Scope\.(\w+)', base))[number]
                new = base[:spot.start(2)] + name + base[spot.end(2):]
                opened = re.search(r'enum Scope\s*\{', new)
                new = new[:opened.end()] + f'\n        static var {name}: Scope {{ .{chosen} }}' + new[opened.end():]
                results.append((new, dict(site=f'{match.group(1)} Scope.{name!r} for .{chosen!r}', role='value')))
    return results


@rewrite('phase-alias-other', 'break', 'whose distinct struct or enum is declared directly inside the schema')
def _(text, rng):
    results = []
    payloads = [m.group(2) for m in re.finditer(r'^(    (?:@[\w.]+\s+)*case\s+\w+\()(\w+)', text, re.M)]
    for number, name in enumerate(payloads):
        for flavor in ('nfd', 'fresh'):
            base, alias = text, 'FuzzPhase'
            if flavor == 'nfd':
                # The struct spelled with a precomposed letter; the alias the case names with a combining mark.
                base = rename(text, name, name + '\u00e9')
                alias = name + 'e\u0301'
            line = list(re.finditer(r'^(    (?:@[\w.]+\s+)*case\s+\w+\()(\w+)', base, re.M))[number]
            new = base[:line.start(2)] + alias + base[line.end(2):]
            new = insert_in_schema(new, f'typealias {alias} = Swift.Int')
            results.append((new, dict(site=f'case payload {name} -> alias {alias!r} of Int', role='value')))
    return results[:6]


@rewrite('drop-request-label', 'break', 'The request is the parameter labeled `request:`')
def _(text, rng):
    return [(text[:m.start()] + '_ request:' + text[m.end():], dict(site='request:', role='value')) for m in re.finditer(r'\brequest:(?=\s*\w+Request)', text)]


@rewrite('terminal-flip', 'break', 'a phase that no edge leaves must say so')
def _(text, rng):
    results = []
    for match in re.finditer(r'@Terminal\s+', text):
        line = text[text.rfind('\n', 0, match.start()) + 1:text.find('\n', match.start())]
        if '@Initial' in line:
            continue
        results.append((text[:match.start()] + text[match.end():], dict(site='remove @Terminal', role='value')))
    for match in re.finditer(r'^    @Initial\s+case', text, re.M):
        if '@Terminal' in text[match.start():text.find('\n', match.start())]:
            continue
        results.append((text[:match.start()] + '    @Initial @Terminal case' + text[match.end():], dict(site='add @Terminal to initial', role='value')))
    return results


# --- Variation rewrites ------------------------------------------------------------------------------------------------

@rewrite('closure-convention', 'valid', 'The router and its edges may each take the closure escaping or not, with any ownership')
def _(text, rng):
    results = []
    for site in type_sites(text):
        if site.kind != 'param' or site.context != 'edge' or not re.search(r'->|Work\b', site.text):
            continue
        before = text[:site.start]
        modifiers = re.search(MODIFIERS + r'$', before)
        head = before[:modifiers.start()] if modifiers and modifiers.group(0) else before
        for spelling in ('+@escaping ', '@escaping ', 'borrowing ', 'borrowing @escaping ', 'sending ', '__owned ', '__shared ', 'sending @escaping ', 'consuming @escaping '):
            # A leading + keeps the parameter's own modifiers and adds the rest.
            new = (before + spelling[1:] if spelling.startswith('+') else head + spelling) + text[site.start:]
            results.append((new, dict(site=f'{spelling.strip()} {site.text}', role='value')))
    return results



# --- Where the macro derives a name or decides a role ------------------------------------------------------------------

def authored_functions_at(text):
    """Each static function an attribute marks: (attribute, name, index of its name, index after its parameters, the
    text between the parameters and `{`)."""
    found = []
    for match in re.finditer(r'@(?:StateMachine\.)?(Transition|Route|Restoration)\b[^\n]*\n\s*((?:\w+\s+)*)static func\s+`?(\w+)`?\s*\(', text):
        depth, index = 1, match.end()
        while depth and index < len(text):
            depth += {'(': 1, ')': -1}.get(text[index], 0)
            index += 1
        brace = text.find('{', index)
        found.append(dict(attribute=match.group(1), modifiers=match.group(2), name=match.group(3), name_at=match.start(3),
                          func_at=text.rfind('static func', 0, match.start(3)), after=index, effects=text[index:brace]))
    return found


GENERATED_NAMES = ['Owned', 'Observed', 'Snapshot', 'Prepared', 'Effect', 'Route', 'Change', 'Advance', 'Phase', 'Local',
                   'Shared', 'ActorHost', 'MainActorHost', 'IsolatedHost', 'PreparationRejection', 'Restoration',
                   'Completion', 'PendingCompletion', 'Configuration', 'CompletionPolicy', 'Outcome', 'Rejection',
                   '_StateMachineSchema', '_StateMachineGraph', '_StateMachineEngine', '_StateMachineScopeID', '_StateMachineKey']


@rewrite('reserved-member', 'eq', 'Generated member names are reserved')
def _(text, rng):
    """An unused member named as something the macro generates for this schema, or for another one."""
    names = list(GENERATED_NAMES)
    for operation in re.findall(r'@Operation\([^\n]*\)\s*\n\s*enum\s+(\w+)', text):
        names += [f'{operation}Request', f'{operation}Work', f'{operation}Completion', f'_{operation}Work']
    for router in re.findall(r'@Route\([^\n]*\)\s*\n\s*(?:\w+\s+)*static func\s+(\w+)', text):
        names.append(router[0].upper() + router[1:] + 'Result')
    results = []
    for name in names:
        if name in identifier_tokens(text):
            continue
        new = insert_in_schema(text, f'struct {name}: Sendable {{}}')
        if new:
            results.append((new, dict(site=f'struct {name}', role='value')))
    new = insert_in_schema(text, 'static let graph = 0')
    results = [(t, dict(i, added=[rf'^(static )?Fz\.(\w+\.)*{i["site"].split()[-1]}\.']) ) for t, i in results]
    if new and not re.search(r'\bgraph\b', text):
        results.append((new, dict(site='static let graph', role='value')))
    return results


OWNER_VERBS = ['send', 'commit', 'deliver', 'snapshot', 'observe', 'reset', 'withValue', 'takeValue', 'value', 'revision',
               'consume', 'cancel', 'reconcile', 'discardPending', 'shutdown', 'graph', 'effect', 'owned', 'restore']


@rewrite('verb-edge-name', 'dist', 'an edge or router may share one with a member of the phase wrappers, unless its generated method would redeclare that member')
def _(text, rng):
    """An edge or router renamed as an owner's or wrapper's verb, with the effect and choice types named after it."""
    results = []
    tokens = identifier_tokens(text)
    # An edge named as an operation's or event's effect case shares that case's spelling; renaming one renames both.
    effect_cases = {n[0].lower() + n[1:] for n in re.findall(r'@(?:Operation|Event)[^\n]*\n\s*enum\s+(\w+)', text)}
    for function in authored_functions_at(text):
        old = function['name']
        if function['attribute'] == 'Restoration' or old in effect_cases or (old[0].upper() + old[1:]) in declared_types(text):
            continue
        for verb in OWNER_VERBS:
            if verb in tokens:
                continue
            variant = rename(text, old, verb)
            capital, new_capital = old[0].upper() + old[1:], verb[0].upper() + verb[1:]
            # `(Effect).Add`, which `paren-base` writes, names the same effect.
            variant = re.sub(r'(\(?\b(?:Effect|Route)\)?)\.((?:\w+\.)?)' + capital + r'(Result)?(?![\w.])', lambda m: f'{m.group(1)}.{m.group(2)}{new_capital}{m.group(3) or ""}', variant)
            results.append((variant, dict(site=f'{function["attribute"]} {old} -> {verb}', role='value', control=text,
                                          mapping={old: verb, capital: new_capital, capital + 'Result': new_capital + 'Result'},
                                          behaviour=False, verb=verb)))
    return results


SHADOWED = ['Int', 'String', 'Bool', 'Error', 'Result', 'Optional', 'Array', 'Dictionary', 'Never', 'Void', 'Sendable',
            'Equatable', 'Hashable', 'Identifiable', 'CaseIterable', 'Codable', 'Hasher', 'Swift', 'StateMachine', 'Task']


@rewrite('shadow-standard', 'eq', 'a schema may declare its own types of those names, such as `Result` or `Error`, and even types named `Swift` or `StateMachine`')
def _(text, rng):
    """Spells every use of a standard name through its module, then declares a type of that name in the schema or at
    file scope: the program means the same, and generated code must not be captured by the new type."""
    results = []
    mask = code_mask(text)
    for name in SHADOWED:
        module = 'StateMachine' if name == 'StateMachine' else 'Swift'
        pieces, last, used = [], 0, False
        for match in re.finditer(r'(?<![\w.:`@])' + re.escape(name) + r'(?![\w`]|::)', text):
            if not mask[match.start()] or text[:match.start()].rstrip().endswith(('struct', 'enum', 'class', 'protocol', 'typealias', 'case', 'func', 'import')):
                continue
            pieces.append(text[last:match.start()] + (f'{module}::{name}' if name not in ('Swift', 'StateMachine') else name))
            last, used = match.end(), True
        spelled = ''.join(pieces) + text[last:]
        if name in ('Swift', 'StateMachine') and re.search(r'\b' + name + r'\.', spelled):
            continue
        for scope in ('schema', 'file'):
            declaration = f'enum {name} {{}}' if name in ('Swift', 'StateMachine', 'Never') else f'struct {name} {{}}'
            new = insert_in_schema(spelled, declaration) if scope == 'schema' else insert_at_file_scope(spelled, declaration)
            if new:
                results.append((new, dict(site=f'{declaration} at {scope} scope' + ('' if used else ' (unused name)'), role='value',
                                          added=[rf'^(static )?Fz\.(\w+\.)*{name}\.(init|__|deinit)', rf'^Fz\.(\w+\.)*{name}$'])))
    return results


def schema_span(text):
    lines = text.split('\n')
    spans = schema_lines(text)
    return spans[0] if spans else None


def nest_schema(text, opener, closer, prefix, extra=''):
    """Wraps the first schema in `opener \u2026 closer` and names it `prefix.<Schema>` outside its body."""
    span = schema_span(text)
    if not span or '// fuzz-outer:' in text or 'fuzzLocalSchema' in text:
        return None
    lines = text.split('\n')
    start, end = span[0] - 1, span[1] - 1
    schema = schema_names('\n'.join(lines[start:end + 1]))[0]
    outside = '\n'.join(lines[:start]), '\n'.join(lines[end + 1:])
    qualify = lambda chunk: re.sub(r'(?<![\w.`])' + re.escape(schema) + r'\b', f'{prefix}.{schema}', chunk)
    body = '\n'.join(lines[start:end + 1])
    return (qualify(outside[0]) + f'\n// fuzz-outer: {prefix}\n{opener}\n' + body + f'\n{closer}\n{extra}' + qualify(outside[1])), schema


@rewrite('nest-schema', 'eq', 'a schema nested in a nongeneric type, an extension, a class, or an actor means the same')
def _(text, rng):
    results = []
    access = re.search(r'@StateMachine\([^)]*\)\s*(?:@\w+(?:\([^)]*\))?\s*)*(public|package)\s', text)
    level = f'{access.group(1)} ' if access else ''
    for opener, closer, extra, label in [(f'{level}nonisolated enum FuzzOuter {{', '}', '', 'enum'),
                                         (f'{level}nonisolated struct FuzzOuter {{', '}', '', 'struct'),
                                         ('extension FuzzOuter {', '}', f'{level}nonisolated enum FuzzOuter {{}}\n', 'extension'),
                                         (f'{level}final class FuzzOuter {{', '}', '', 'class'),
                                         (f'{level}actor FuzzOuter {{', '}', '', 'actor')]:
        nested = nest_schema(text, opener, closer, 'FuzzOuter', extra)
        if nested:
            new, schema = nested
            results.append((new, dict(site=f'inside {label} FuzzOuter', role='value', mapping={schema: f'FuzzOuter.{schema}'},
                                      run_mapping={}, added=[rf'^(static )?Fz\.FuzzOuter\.(?!{schema}\b)', r'^Fz\.FuzzOuter$'])))
    return results


@rewrite('nest-generic', 'diag', 'generic schema or phase payload declarations')
def _(text, rng):
    nested = nest_schema(text, 'nonisolated enum FuzzOuter<FuzzT> {', '}', 'FuzzOuter<Int>')
    return [(nested[0], dict(site='inside a generic type', role='value'))] if nested else []


@rewrite('nest-local', 'safe', 'a schema declared in a function body')
def _(text, rng):
    span = schema_span(text)
    if not span or re.search(r'^(public|package)\s', text, re.M):
        # Swift allows no access modifier on a declaration in a function body.
        return []
    lines = text.split('\n')
    body = '\n'.join(lines[span[0] - 1:span[1]])
    rest = '\n'.join(lines[:span[0] - 1] + lines[span[1]:])
    # Declarations outside the schema that name it, such as an extension, cannot follow it into a function body.
    schema = schema_names(body)[0]
    if re.search(r'(?<![\w.])' + re.escape(schema) + r'\b', schema_only(rest)):
        return []
    return [(append_to_module(rest, 'func fuzzLocalSchema() {\n' + body + '\n}'), dict(site='inside a function body', role='value', schema_only=True))]


@rewrite('schema-access', 'safe', 'a public schema needs a public initializer or function')
def _(text, rng):
    results = []
    for match in re.finditer(r'^(nonisolated\s+)(enum\s+\w+)', text, re.M):
        # Another file of the module cannot extend a fileprivate or private schema.
        for level in ('public', 'package', 'internal') + (() if FILE_MARKER.search(text) else ('fileprivate', 'private')):
            # A public or package schema generates members of that access that name its payloads, which are internal.
            expect = 'schema-access' if level in ('public', 'package') else None
            results.append((text[:match.start()] + f'{level} ' + text[match.start():], dict(site=f'{level} schema', role='value', expect=expect)))
        public_members = re.sub(r'^(\s+)(nonisolated\s+)?(struct|enum|typealias|protocol)\b', lambda m: f'{m.group(1)}public {m.group(2) or ""}{m.group(3)}', text, flags=re.M)
        public_members = re.sub(r'([{;]\s*)typealias\b', r'\1public typealias', public_members)
        results.append((public_members[:match.start()] + 'public ' + public_members[match.start():], dict(site='public schema and payloads', role='value')))
        break
    return results


@rewrite('declaration-attributes', 'safe', 'attributes Swift accepts on a schema or a function the macro reads')
def _(text, rng):
    results = []
    for match in re.finditer(r'^(nonisolated\s+enum\s+\w+)', text, re.M):
        results.append((text[:match.start()] + '@available(macOS 13, iOS 16, *)\n' + text[match.start():], dict(site='@available schema', role='value')))
        break
    for function in authored_functions_at(text)[:3]:
        at = function['func_at']
        line_start = text.rfind('\n', 0, at) + 1
        indent = len(text[line_start:]) - len(text[line_start:].lstrip())
        for attribute in ('@available(macOS 13, *)', '@inline(__always)', '@discardableResult', '@MainActor', 'nonisolated'):
            if attribute.startswith('@'):
                new = text[:line_start + indent] + attribute + ' ' + text[line_start + indent:]
            else:
                new = text[:at] + attribute + ' ' + text[at:]
            expect = {'@MainActor': 'custom-attribute', '@available(macOS 13, *)': 'function-availability'}.get(attribute)
            results.append((new, dict(site=f'{attribute} on {function["name"]}', role='value', expect=expect)))
    return results


@rewrite('conditional-compilation', 'safe', 'so it refuses `#if` among the members of the schema')
def _(text, rng):
    start, end, blocks = member_blocks(text)
    if not blocks:
        return []
    results = []
    for index in sorted({0, len(blocks) // 2, len(blocks) - 1}):
        pieces = ['\n'.join(block) for block in blocks]
        pieces[index] = '    #if true\n' + pieces[index] + '\n    #endif'
        results.append((text[:start] + '\n'.join(pieces) + '\n' + text[end:], dict(site=f'#if true around member {index}', role='value', expect='conditional-members')))
    dead = insert_in_schema(text, '#if false\n    struct FuzzNever: Sendable {}\n    static func fuzzNever() -> Int { 0 }\n    #endif')
    if dead:
        results.append((dead, dict(site='#if false member', role='value', expect='conditional-members')))
    return results


@rewrite('isolation-mainactor', 'valid', 'every client fixture compiles in both default isolations')
def _(text, rng):
    return [(text, dict(site='-default-isolation MainActor', role='value', flags=['-default-isolation=MainActor']))]


@rewrite('optimize', 'valid', 'an optimized build compiles what an unoptimized one does')
def _(text, rng):
    return [(text, dict(site='-O', role='value', flags=['-O']))]


def function_effects(text, transform, label, only=lambda f: True):
    results = []
    for function in authored_functions_at(text):
        if not only(function):
            continue
        effects = function['effects']
        changed = transform(effects, function)
        if changed is None or changed == effects:
            continue
        new = text[:function['after']] + changed + text[function['after'] + len(effects):]
        results.append((new, dict(site=f'{label} on {function["attribute"]} {function["name"]}', role='value')))
    return results


@rewrite('async-function', 'diag', 'async edges')
def _(text, rng):
    return function_effects(text, lambda e, f: ' async' + e if 'async' not in e else None, 'async')


@rewrite('untyped-throws', 'diag', 'untyped throws')
def _(text, rng):
    return function_effects(text, lambda e, f: ' throws' + e if 'throws' not in e else None, 'throws',
                            only=lambda f: True)


@rewrite('throws-never', 'eq', 'A function that throws `Never`, spelled directly or through an alias the schema declares, does not throw')
def _(text, rng):
    results = function_effects(text, lambda e, f: ' throws(Never)' + e if 'throws' not in e else None, 'throws(Never)')
    results += function_effects(text, lambda e, f: ' throws(Swift::Never)' + e if 'throws' not in e else None, 'throws(Swift::Never)')
    return results


@rewrite('throws-any-error', 'safe', 'a function type that throws `any Error` keys as an untyped throw')
def _(text, rng):
    return function_effects(text, lambda e, f: ' throws(any Error)' + e if 'throws' not in e else None, 'throws(any Error)')


@rewrite('generic-function', 'diag', 'generic edge functions are unsupported')
def _(text, rng):
    results = []
    for function in authored_functions_at(text):
        at = function['name_at'] + len(function['name'])
        if text[at] == '`':
            at += 1
        results.append((text[:at] + '<FuzzT>' + text[at:], dict(site=f'generic {function["name"]}', role='value')))
    return results


@rewrite('inout-source', 'diag', '`inout` sources')
def _(text, rng):
    results = []
    for function in authored_functions_at(text):
        segment = text[function['name_at']:function['after']]
        match = re.search(r'\(\s*_\s+(\w+)\s*:\s*(?:borrowing\s+|consuming\s+)?', segment)
        if match and function['attribute'] != 'Restoration':
            at = function['name_at'] + match.end()
            prefix_at = function['name_at'] + match.start()
            new = text[:prefix_at] + segment[match.start():match.end()].replace('borrowing ', '').replace('consuming ', '') + 'inout ' + text[at:]
            results.append((new, dict(site=f'inout source of {function["name"]}', role='value')))
    return results


# --- Spelling, declaration and owner-selection families ---------------------------------------------------------------

def integer_spellings(value):
    """Other Swift spellings of a decimal integer literal's value."""
    digits = str(value)
    # Not a leading zero: Swift 6.4 reads `[02 of Int]` as a type other than `[2 of Int]`.
    spellings = [hex(value), '0o' + format(value, 'o'), '0b' + format(value, 'b')]
    if len(digits) > 1:
        spellings.insert(0, digits[0] + '_' + digits[1:])
    return [s for s in spellings if s != digits]


@rewrite('integer-spelling', 'eq', 'an integer argument compares by its value, so `Problem<10>`, `Problem<1_0>`, and `Problem<0xA>` are one type')
def _(text, rng):
    """An admission limit or a value-generic argument spelled as another integer literal of the same value."""
    results = []
    mask = code_mask(text)
    for match in re.finditer(r'\.parallel\(limit:\s*(\d+)\)|(?<=[<,])\s*(\d+)\s*(?=[,>])|\[\s*(\d+)\s+of\b', text):
        group = next(g for g in (1, 2, 3) if match.group(g) is not None)
        if not mask[match.start(group)]:
            continue
        value = int(match.group(group))
        for spelling in integer_spellings(value):
            new = text[:match.start(group)] + spelling + text[match.end(group):]
            results.append((new, dict(site=f'{match.group(group)} -> {spelling}', role='value')))
    return results


def public_types(text):
    return re.findall(r'^\s*(?:public|package)\s+(?:nonisolated\s+)?(?:struct|enum|class)\s+(\w+)', text, re.M)


@rewrite('helper-basename', 'eq', 'a helper that none of them names may keep less, even when it shares a name with one that does')
def _(text, rng):
    """An unused private helper whose member shares its basename with a public phase type of the schema."""
    results = []
    names = [n for n in public_types(text) if n not in ('Input', 'Scope') and n not in schema_names(text)] or sorted(phase_payloads(text))
    for name in names[:4]:
        for declaration in (f'private enum FuzzNotes {{ struct {name} {{}} }}', f'private struct FuzzNotes {{ typealias {name} = Swift::Int }}'):
            new = insert_in_schema(text, declaration)
            if new:
                results.append((new, dict(site=declaration, role='value', added=[r'Fz\.(\w+\.)*FuzzNotes\b'])))
    return results


@rewrite('alias-to-extension', 'eq', 'With `typealias Detail = String` in the schema and `typealias Detail = Int` in an extension of `Input`')
def _(text, rng):
    """An Input case's payload spelled through an alias declared in an extension of that Input, at file scope,
    which Swift finds at the case constructor and the macro cannot see."""
    results = []
    for schema in schema_names(text):
        phases, inputs = authored_payloads(text, schema)
        members = scope_members(text, schema, 'Input')
        for case, payload in inputs.items():
            if not payload or ':' in payload or 'FuzzMoved' in payload:
                continue
            # This schema's own Input, not the first one the file declares.
            schema_at, schema_end = schema_opening(text, schema)
            input_at = member_opening(text, schema_at, schema_end, 'Input') if schema_at is not None else None
            if input_at is None:
                continue
            body = body_of(text, re.compile(r'\{').match(text, input_at - 1))
            spot = re.search(r'\b' + re.escape(case) + r'\(\s*' + re.escape(payload) + r'\s*\)', body)
            if not spot:
                continue
            start = input_at + spot.start()
            new = text[:start] + f'{case}(FuzzMoved)' + text[start + len(spot.group(0)):]
            # The alias reads at file scope inside an extension of Input: Input's members (an extension's among
            # them), then file scope, so the schema's own members need the schema's name.
            inside = re.sub(r'(?<![\w.`])Self\.', '', payload)
            outer = schema_types(text) | set(re.findall(r'typealias\s+(\w+)', text))
            spelled = re.sub(r'(?<![\w.`])([A-Za-z_]\w*)', lambda m: m.group(1) if m.group(1) in members or m.group(1) in STANDARD
                             or m.group(1) not in outer or inside[:m.start()].rstrip().endswith('.') else f'{schema}.{m.group(1)}', inside)
            path = schema_paths(text).get(schema, schema)
            new = append_to_module(new, f'extension {path}.Input {{\n    typealias FuzzMoved = {spelled}\n}}')
            results.append((new, dict(site=f'input {case}({payload}) through an Input extension', role='value')))
    return results


@rewrite('binding-shadow', 'eq', 'A spelling means what it means where it is written')
def _(text, rng):
    """Declarations that give a payload's basename another binding where no spelling of the schema looks: a
    sibling namespace in the schema, an extension of the schema, and an extension of an operation or event namespace,
    with the declaration kind varied."""
    results = []
    names = sorted(phase_payloads(text))[:3]
    namespaces = re.findall(r'@(?:Operation|Event)\b[^\n]*\n\s*enum\s+(\w+)', text)
    for schema in schema_names(text)[:1]:
        path = schema_paths(text).get(schema, schema)
        for name in names:
            for scope, declaration in (('schema', f'enum FuzzSibling {{ struct {name} {{}}; typealias {name}s = Swift::Never }}'),
                                       ('file', f'extension {path} {{ enum FuzzElsewhere {{ typealias {name} = Swift::Int }} }}'),
                                       ('file', f'extension {path}.FuzzSibling2 {{ }}\nextension {path} {{ enum FuzzSibling2 {{ enum {name} {{}} }} }}')):
                new = insert_in_schema(text, declaration) if scope == 'schema' else append_to_module(text, declaration)
                if new:
                    results.append((new, dict(site=declaration.split('\n')[-1], role='value', added=[r'Fz\.(\w+\.)*Fuzz(Sibling2?|Elsewhere)\b'])))
        for namespace in namespaces[:2]:
            for name in names[:1]:
                new = append_to_module(text, f'extension {path}.{namespace} {{ struct {name} {{}} }}')
                results.append((new, dict(site=f'struct {name} in an extension of {namespace}', role='value',
                                          added=[rf'Fz\.(\w+\.)*{namespace}\.{name}\b'])))
    return results


def append_to_module(text, declaration):
    """Appends a file-scope declaration to the schema's module, before any client section."""
    declaration = '\n'.join(available_above_floor(text, d) if d.startswith(('typealias', 'extension')) else d for d in declaration.split('\n'))
    if CLIENT_MARKER in text:
        module, client = text.split(CLIENT_MARKER, 1)
        return module.rstrip('\n') + '\n' + declaration + '\n' + CLIENT_MARKER + client
    return text.rstrip('\n') + '\n' + declaration + '\n'


MERMAID_WORDS = ['note', 'state', 'style', 'click', 'scale', 'href', 'classDef', 'stateDiagram']


def phase_cases(text):
    return [m.group(1) for m in re.finditer(r'^    (?:@[\w.]+(?:\([^)\n]*\))?\s+)*case\s+`?(\w+)`?\(', text, re.M)]


@rewrite('reserved-phase', 'dist', 'so no name is ever read as Mermaid syntax, even one such as `note` or `end` that the diagram language reserves')
def _(text, rng):
    """A phase case renamed to a word a diagram language reserves."""
    results = []
    tokens = identifier_tokens(text)
    for case in phase_cases(text):
        if re.search(r'\b' + re.escape(case) + r'\s*:', text) or case in KEYWORDS:
            # The name is also an argument label (`on:`), which a renaming must not touch.
            continue
        for word in MERMAID_WORDS:
            if word in tokens:
                continue
            variant = rename(text, case, word)
            # The report may print the old name as text of its own, so the renaming maps the printed graphs only.
            results.append((variant, dict(site=f'phase {case} -> {word}', role='value', control=text, mapping={case: word},
                                          inside=True, graphs_only=True)))
    rng.shuffle(results)
    return results[:6]


@rewrite('edge-availability', 'safe', 'so it refuses `@available` and `@backDeployed` on the function and asks for them on the schema')
def _(text, rng):
    """Availability on an authored function above the client's deployment target, or none at all."""
    results = []
    for function in authored_functions_at(text)[:3]:
        at = function['func_at']
        line_start = text.rfind('\n', 0, at) + 1
        indent = len(text[line_start:]) - len(text[line_start:].lstrip())
        for attribute in ('@available(macOS 14, *)', '@available(*, unavailable)', '@available(macOS, deprecated: 13)',
                          '@backDeployed(before: macOS 14)'):
            new = text[:line_start + indent] + attribute + ' ' + text[line_start + indent:]
            results.append((new, dict(site=f'{attribute} on {function["name"]}', role='value', expect='function-availability')))
    return results


@rewrite('lowercase-attribute', 'safe', 'such as `@MainActor`, whatever its capitalization')
def _(text, rng):
    """A lowercase global actor on an authored function."""
    results = []
    actor = re.search(r'@globalActor\s+actor\s+([a-z]\w*)', text)
    name = actor.group(1) if actor else 'fuzzActor'
    base = text if actor else insert_at_file_scope(text, '@globalActor actor fuzzActor { static let shared = fuzzActor() }')
    for function in authored_functions_at(base)[:3]:
        at = function['func_at']
        line_start = base.rfind('\n', 0, at) + 1
        indent = len(base[line_start:]) - len(base[line_start:].lstrip())
        new = base[:line_start + indent] + f'@{name} ' + base[line_start + indent:]
        results.append((new, dict(site=f'@{name} on {function["name"]}', role='value', expect='custom-attribute')))
    return results


@rewrite('conditional-attribute', 'safe', 'and in the attributes of any of those members')
def _(text, rng):
    """An attribute inside a conditional attribute list on an authored function."""
    results = []
    for function in authored_functions_at(text)[:2]:
        at = function['func_at']
        marker = text.rfind('\n    @', 0, at)
        if marker < 0:
            continue
        new = text[:marker + 1] + '    #if true\n    @discardableResult\n    #endif\n' + text[marker + 1:]
        results.append((new, dict(site=f'#if attribute on {function["name"]}', role='value', expect='conditional-attributes')))
    return results


def protocol_names(text):
    return re.findall(r'\bprotocol\s+(\w+)', text)


@rewrite('existential-metatype', 'eq', "A protocol's `Failure.Type`, spelled bare, in parentheses, or through an alias of the protocol, is the existential `any Failure.Type`")
def _(text, rng):
    """`P.Type` and `any P.Type`; `P.Protocol` and `(any P).Type`."""
    protocols = set(protocol_names(text))

    def transform(site):
        spelling = site.text.strip()
        for pattern, replacement in ((r'^(?:any\s+)?(\w+)\.Type$', None), (r'^(\w+)\.Protocol$', r'(any \1).Type'), (r'^\(any (\w+)\)\.Type$', r'\1.Protocol')):
            match = re.match(pattern, spelling)
            if match and match.group(1) in protocols:
                if replacement is None:
                    return spelling[4:].strip() if spelling.startswith('any ') else f'any {spelling}'
                return re.sub(pattern, replacement, spelling)
        return None
    return at_sites(text, lambda s: True, transform)


@rewrite('composition-flatten', 'eq', '`PQ & R` and `P & Q & R` for `typealias PQ = P & Q`, `P & P` and `P`')
def _(text, rng):
    """A composition spelled through an alias of part of it, or with a member repeated."""
    results = []
    for site in type_sites(text):
        match = re.fullmatch(r'(any\s+)?([^&<>()]+(?:&[^&<>()]+)+)', site.text.strip())
        if not match or not within_schema(text, site):
            continue
        members = [m.strip() for m in match.group(2).split('&')]
        prefix = match.group(1) or ''
        repeated = text[:site.start] + prefix + ' & '.join(members + members[:1]) + text[site.end:]
        results.append((repeated, dict(site=f'{site.text} with {members[0]} twice', role=site_role(text, site))))
        aliased = text[:site.start] + prefix + ' & '.join(['FuzzPair'] + members[2:]) + text[site.end:]
        aliased = insert_in_schema(aliased, f'typealias FuzzPair = {members[0]} & {members[1]}', site.start)
        results.append((aliased, dict(site=f'{site.text} through FuzzPair', role=site_role(text, site))))
    return results


@rewrite('inline-array', 'eq', '`[2 of Item]` and `Swift::InlineArray<2, Item>`')
def _(text, rng):
    """Inline-array sugar and its standard spelling."""
    def transform(site):
        spelling = site.text.strip()
        match = re.fullmatch(r'\[\s*(\w+)\s+of\s+(.+)\]', spelling)
        if match:
            return f'Swift::InlineArray<{match.group(1)}, {match.group(2)}>'
        match = re.fullmatch(r'(?:Swift::)?InlineArray<\s*(\w+)\s*,\s*(.+)>', spelling)
        if match:
            return f'[{match.group(1)} of {match.group(2)}]'
        return None
    return at_sites(text, lambda s: True, transform)


DEFAULT_OWNERS = {'.shared': ['.owned', '.local', '.shared', '.actorHost', '.mainActorHost', '.isolatedHost'],
                  '.isolated': ['.owned', '.local', '.mainActorHost', '.isolatedHost'], '.ownedOnly': ['.owned']}


@rewrite('owner-selection', 'eq', 'omit owners: to generate every owner')
def _(text, rng):
    """An explicit owner list reversed, or the owners a mode generates by default spelled out."""
    results = []
    for match in re.finditer(r'@StateMachine\(mode: (\.\w+)(?:, owners: \[([^\]]*)\])?\)', text):
        mode, owners = match.group(1), match.group(2)
        if owners is None:
            spelled = ', '.join(DEFAULT_OWNERS.get(mode, []))
            if spelled:
                results.append((text[:match.end(1)] + f', owners: [{spelled}]' + text[match.end(1):], dict(site=f'default owners of {mode} spelled out', role='value')))
        else:
            items = [o.strip() for o in owners.split(',') if o.strip()]
            if len(items) > 1:
                results.append((text[:match.start(2)] + ', '.join(reversed(items)) + text[match.end(2):], dict(site='owners reversed', role='value')))
            if sorted(items) == sorted(DEFAULT_OWNERS.get(mode, [])):
                results.append((text[:match.end(1)] + text[match.end(2) + 1:], dict(site='owners omitted', role='value')))
    return results


@rewrite('metatype-split', 'valid', 'candidates that throw `Problem<Failure.Type>` and `Problem<(any Failure).Type>` do not')
def _(text, rng):
    """One router candidate's failure changed to the type a near spelling names, which the macro must count as a
    second failure: the router's prepared method then throws `PreparationRejection`."""
    results = []
    for function in authored_functions_at(text):
        if function['attribute'] != 'Transition':
            continue
        effects = function['effects']
        throws = re.search(r'throws\((.*)\)', effects)
        if not throws:
            continue
        failure = throws.group(1)
        for pattern, replacement in ((r'(?<!any )\b(\w+)\.Type\b', r'(any \1).Type'), (r'\(\(\) -> (\w+)\)\?', r'() -> \1?'),
                                     (r'@(Actors)\.Main\b', r'@Others.Main')):
            changed = re.sub(pattern, replacement, failure, count=1)
            if changed != failure and (not pattern.startswith(r'(?<!any )') or re.search(pattern, failure).group(1) in protocol_names(text)):
                new = text[:function['after']] + effects.replace(failure, changed, 1) + text[function['after'] + len(effects):]
                # The router of the changed candidate's own schema throws that schema's PreparationRejection.
                schema = schema_of(text, function['func_at'])
                router = re.compile(r'@Route\(on: ([\w.]+)\)\s*\n\s*(?:\w+\s+)*static func (\w+)').search(text, text.find(f'enum {schema}'))
                results.append((schema_only(new), dict(site=f'{function["name"]} throws {changed}', role='value',
                                                       signature=rf'Fz\.(\w+\.)*{schema}\.Observed\b[^ (]*\.{router.group(2) if router else ""}(< where [^>]*>)?\(.*\) throws\(Fz\.(\w+\.)*{schema}\.PreparationRejection\)')))
    return results


# --- Graph-validity families: valid Swift, an invalid graph -----------------------------------------------------------

def edge_destinations(text):
    """Each transition with the phase payload its result names: (function, destination type, span of that name)."""
    found = []
    payload_types = phase_payloads(text)
    for function in authored_functions_at(text):
        if function['attribute'] != 'Transition':
            continue
        effects = function['effects']
        match = re.search(r'->\s*(?:Change<\s*|Advance<\s*\w+\s*,\s*)?(\w+)', effects)
        if match and match.group(1) in payload_types:
            found.append((function, match.group(1), (function['after'] + match.start(1), function['after'] + match.end(1))))
    return found


def phase_of_type(text, payload):
    for match in re.finditer(r'^    (?:@[\w.]+(?:\([^)\n]*\))?\s+)*case\s+`?(\w+)`?\((\w+)', text, re.M):
        if match.group(2) == payload:
            return match.group(1)
    return None


@rewrite('redirect-entrance', 'break', 'every phase must be reachable from the initial phase')
def _(text, rng):
    """The sole transition into a phase leads to another phase instead; the body becomes `fatalError()`."""
    if '@Restoration' in text:
        return []
    results = []
    destinations = edge_destinations(text)
    initial = re.search(r'@Initial\b[^\n]*case\s+\w+\((\w+)', text)
    spans = [(a, b) for a, b in schema_lines(text)]
    schema_at = lambda index: next((s for s in spans if s[0] <= text.count('\n', 0, index) + 1 <= s[1]), None)
    for function, destination, (start, end) in destinations:
        if sum(1 for _, d, _ in destinations if d == destination) != 1 or (initial and initial.group(1) == destination):
            continue
        others = [d for f, d, _ in destinations if d != destination and schema_at(f['func_at']) == schema_at(function['func_at'])]
        if not others:
            continue
        other = others[0]
        brace = text.find('{', function['after'])
        body = body_of(text, re.compile(r'\{').match(text, brace))
        new = text[:start] + other + text[end:brace] + '{ fatalError() }' + text[brace + len(body) + 2:]
        results.append((new, dict(site=f'{function["name"]} into {other} instead of {destination}', role='value')))
    return results


def route_blocks(text):
    """Each router: (start of its attribute line, end of its body, name)."""
    found = []
    for match in re.finditer(r'^    @(?:StateMachine\.)?Route\([^\n]*\)\s*\n\s*(?:\w+\s+)*static func\s+(\w+)', text, re.M):
        brace = text.find('{', match.end())
        body = body_of(text, re.compile(r'\{').match(text, brace))
        found.append((match.start(), brace + len(body) + 2, match.group(1)))
    return found


@rewrite('router-delete', 'break', 'declare exactly one @Route when multiple edges match')
def _(text, rng):
    """The only router for two matching candidates removed."""
    # Only a router that chooses among candidates; one that only rejects leaves a valid graph when removed.
    return [(text[:start] + text[end + 1:], dict(site=f'router {name} removed', role='value'))
            for start, end, name in route_blocks(text) if re.search(r'->\s*(Self\.)?Route\.', text[start:end].split('{')[0])]


@rewrite('router-duplicate', 'break', 'declare exactly one @Route when multiple edges match')
def _(text, rng):
    """A second router for the same phase and trigger."""
    results = []
    for start, end, name in route_blocks(text):
        copy = re.sub(r'\bstatic func\s+' + name + r'\b', f'static func {name}Again', text[start:end], count=1)
        copy = re.sub(r'\bRoute\.' + name[0].upper() + name[1:] + r'\b', f'Route.{name[0].upper() + name[1:]}Again', copy)
        results.append((text[:end] + '\n' + copy + text[end:], dict(site=f'router {name} twice', role='value')))
    return results


def operation_names(text):
    return re.findall(r'@(?:StateMachine\.)?Operation\b[^\n]*\n\s*enum\s+(\w+)', text)


def function_block(text, function):
    """(start of the function's first attribute line, end of its body)."""
    start = text.rfind('\n    @', 0, function['func_at']) + 1
    brace = text.find('{', function['after'])
    body = body_of(text, re.compile(r'\{').match(text, brace))
    return start, brace + len(body) + 2


@rewrite('operation-drop', 'break', 'each operation started and accepted by a completion edge')
def _(text, rng):
    """The last start, success, or failure of an operation removed, the other two kept."""
    results = []
    functions = authored_functions_at(text)
    for operation in operation_names(text):
        starts = [m for m in re.finditer(r'starts:\s*\[([^\]]*)\]', text) if re.search(r'\b' + operation + r'\.self\b', m.group(1))]
        if len(starts) == 1:
            match = starts[0]
            items = [i.strip() for i in match.group(1).split(',') if i.strip() and i.strip() != f'{operation}.self']
            new = text[:match.start()] + (f'starts: [{", ".join(items)}]' if items else 'starts: []') + text[match.end():]
            results.append((new, dict(site=f'start of {operation} removed', role='value', breaking='operation-drop-start')))
        for outcome in ('Success', 'Failure'):
            handlers = [f for f in functions if re.search(rf'@(?:StateMachine\.)?(?:Transition|Route)\(on{outcome}:\s*{operation}\.self', text[f['func_at'] - 200:f['func_at']].split('\n\n')[-1])]
            handlers = [f for f in handlers if re.search(rf'on{outcome}:\s*{operation}\.self', text[text.rfind(chr(10) + '    @', 0, f['func_at']):f['func_at']])]
            if len(handlers) == 1:
                start, end = function_block(text, handlers[0])
                results.append((text[:start] + text[end + 1:], dict(site=f'on{outcome} of {operation} removed', role='value',
                                                                    breaking=f'operation-drop-{outcome.lower()}')))
    return results


@rewrite('scope-ineligible', 'break', 'Started operation and every required scope must be eligible in destination')
def _(text, rng):
    """A scope the operation holds loses the destination of the transition that starts the operation, so only
    the path that starts it breaks."""
    results = []
    payload_case = {payload: case for case, payload in re.findall(r'^    (?:@[\w.]+(?:\([^)\n]*\))?\s+)*case\s+`?(\w+)`?\((\w+)', text, re.M)}
    for operation in re.finditer(r'@Operation\(([^\n]*)\)\s*\n\s*enum\s+(\w+)', text):
        held = re.findall(r'Scope\.(\w+)', operation.group(1))
        for function, destination, _ in edge_destinations(text):
            attribute = text[text.rfind('\n    @', 0, function['func_at']):function['func_at']]
            if not re.search(r'starts:\s*\[[^\]]*\b' + operation.group(2) + r'\.self', attribute):
                continue
            for scope in held:
                active = re.search(r'@Active\(in:\s*\[([^\]]+)\]\)\s*\n?\s*case\s+' + scope + r'\b', text)
                if not active:
                    continue
                items = [i.strip() for i in active.group(1).split(',')]
                if f'{destination}.self' not in items or len(items) < 2:
                    continue
                kept = [i for i in items if i != f'{destination}.self']
                new = text[:active.start(1)] + ', '.join(kept) + text[active.end(1):]
                results.append((new, dict(site=f'{scope} not active in {destination}', role='value')))
    return results


@rewrite('cancel-unkeyed', 'break', 'cancels: names keyed operations')
def _(text, rng):
    """An unkeyed operation added to `cancels:`."""
    results = []
    for operation in operation_names(text):
        body = re.search(r'enum\s+' + operation + r'\s*\{([^{}]*)\}', text)
        if body and re.search(r'typealias\s+Key\b', body.group(1)):
            continue
        for function in authored_functions_at(text)[:2]:
            attribute = text.rfind('@Transition(', 0, function['func_at'])
            if attribute < 0 or text.find(')', attribute) > function['func_at'] or 'cancels:' in text[attribute:function['func_at']]:
                continue
            close = text.find(')\n', attribute)
            new = text[:close] + f', cancels: [{operation}.self]' + text[close:]
            results.append((new, dict(site=f'{function["name"]} cancels {operation}', role='value')))
    return results


@rewrite('owner-invalid', 'break', 'List each owner once')
def _(text, rng):
    """An owner listed twice, one the mode excludes, or `owners: []`."""
    results = []
    for match in re.finditer(r'@StateMachine\(mode: (\.\w+)(?:, owners: \[([^\]]*)\])?\)', text):
        mode = match.group(1)
        owners = [o.strip() for o in (match.group(2) or '').split(',') if o.strip()] or DEFAULT_OWNERS.get(mode, ['.owned'])
        head = text[:match.end(1)]
        tail = text[match.end():]
        results.append((head + f', owners: [{", ".join(owners + owners[:1])}])' + tail, dict(site='an owner twice', role='value', breaking='owner-duplicate')))
        excluded = {'.isolated': '.shared', '.ownedOnly': '.local', '.shared': None}.get(mode)
        if excluded:
            results.append((head + f', owners: [{", ".join(owners + [excluded])}])' + tail, dict(site=f'{excluded} in {mode}', role='value', breaking='owner-excluded')))
        results.append((head + ', owners: [])' + tail, dict(site='owners: []', role='value', breaking='owner-empty')))
    return results


@rewrite('restoration-invalid', 'break', 'Declare at most one @Restoration function in a schema')
def _(text, rng):
    """A second restoration function, or restoration entrances that admit no phase."""
    results = []
    for function in authored_functions_at(text):
        if function['attribute'] != 'Restoration':
            continue
        start, end = function_block(text, function)
        copy = re.sub(r'\bstatic func\s+' + function['name'] + r'\b', f'static func {function["name"]}Again', text[start:end], count=1)
        results.append((text[:end] + '\n' + copy + text[end:], dict(site='a second @Restoration', role='value', breaking='restoration-duplicate')))
        attribute = re.compile(r'@Restoration(\([^)]*\))?').search(text, start)
        if attribute and attribute.start() < function['func_at']:
            results.append((text[:attribute.start()] + '@Restoration(only: [])' + text[attribute.end():], dict(site='@Restoration(only: [])', role='value', breaking='restoration-entrance')))
    return results


REWRITE_BY_NAME = {r.name: r for r in REWRITES}

# ---------------------------------------------------------------------------------------------------------------------
# Compiling one case.

# The graph fields that echo an authored type spelling, by the list that holds the record. Only these leave the
# structural comparison (the spelling probes compare what they mean); every other field, each trigger among them, is
# compared as it is. A field keeps its presence, so a keyed operation never compares equal to an unkeyed one.
GRAPH_SPELLED_FIELDS = {'phases': ('payload',), 'inputs': ('payload',), 'operations': ('key', 'input', 'output', 'failure'),
                        'events': ('payload',)}


def schema_paths(text):
    """Each schema's name as file-scope code spells it: `FuzzOuter.Flow` for one a rewrite nested, none for one declared
    in a function body."""
    paths = {}
    for match in re.finditer(r'(?:// fuzz-outer: (\S+)\n[^\n]*\n)?(?:@available\([^)]*\)\s*\n)?@StateMachine\([^)]*\)\s*(?:@\w+(?:\([^)]*\))?\s*)*(?:\w+\s+)*enum\s+`?(\w+)`?', text):
        paths[match.group(2)] = f'{match.group(1)}.{match.group(2)}' if match.group(1) else match.group(2)
    if 'func fuzzLocalSchema()' in text:
        return {}
    return paths


def split_case(text):
    """The schema module's source files, by name, and the client section, or None."""
    module, client = text.split(CLIENT_MARKER, 1) if CLIENT_MARKER in text else (text, None)
    parts = FILE_MARKER.split(module)
    files = {'Case.swift': parts[0]}
    for index in range(1, len(parts), 2):
        files[parts[index]] = parts[index + 1]
    return files, client


def declaration_order(text):
    """The operations and the events a text declares, each in declaration order."""
    operations = re.findall(r'@(?:StateMachine\.)?Operation\b[^\n]*\n\s*(?:\w+\s+)*enum\s+`?(\w+)', text)
    events = re.findall(r'@(?:StateMachine\.)?Event\b[^\n]*\n?\s*(?:\w+\s+)*enum\s+`?(\w+)', text)
    return operations, events


def lower_first(name):
    return name[:1].lower() + name[1:]


def expected_labels(text):
    """The driver and handler labels a managed initializer takes, in the order the guide documents."""
    operations, events = declaration_order(text)
    return [f'{lower_first(o)}Driver' for o in operations] + [f'on{e}' for e in events]


def order_client_arguments(client, module):
    """Puts each `/*fuzz-args*/ … /*end-args*/` list in the declaration order of `module`."""
    order = expected_labels(module)

    def arrange(match):
        arguments = [a.strip() for a in split_top(match.group(1), braces=True) if a.strip()]
        rank = lambda a: order.index(a.split(':')[0].strip()) if a.split(':')[0].strip() in order else len(order)
        return ', '.join(sorted(arguments, key=rank))
    return re.sub(r'/\*fuzz-args\*/(.*?)/\*end-args\*/', arrange, client, flags=re.S)


def availability_guard(text):
    """The `#available` condition the harness needs to name a schema declared available above the floor, or None."""
    versions = re.findall(r'@available\(macOS (\d+(?:\.\d+)?)', text)
    above = [v for v in versions if float(v) > 13]
    if not above:
        return None
    return f'macOS {max(above, key=float)}, *'


HARNESS_MARKER = '// fuzz-harness: the graphs of the schemas this file declares\n'


def graph_accessor(text):
    """A function the schema's own file declares, so it reaches a schema of any access, returning every graph."""
    graphs = ', '.join(f'{schema}.graph' for schema in schema_paths(text).values())
    guard = availability_guard(text)
    body = f'if #available({guard}) {{ return [{graphs}] }}; return []' if guard and graphs else f'[{graphs}]'
    return '\n' + HARNESS_MARKER + f'func fuzzGraphs() -> [StateMachine::StateMachineGraph] {{ {body} }}\n'


def harness(text):
    """A main, in its own module, that prints every schema's graph and both renderings, and the seed's report."""
    body = ['        for graph in Fz::fuzzGraphs() { fuzzPrint(graph) }']
    if re.search(r'^func fuzzReport\(\)', text, re.M):
        body.append('        Swift::print("report:", Fz::fuzzReport())')
    guard = availability_guard(text)
    if guard:
        body = [f'        if #available({guard}) {{'] + ['    ' + line for line in body] + ['        }']
    return '\n'.join(['@testable import Fz', 'import StateMachine', 'import Foundation', '',
                      '@main struct FuzzMain {', '    @MainActor static func main() {'] + body + ['    }', '}', '',
                      'func fuzzPrint(_ graph: StateMachine::StateMachineGraph) {',
                      '    let encoder = Foundation::JSONEncoder()',
                      '    encoder.outputFormatting = [.sortedKeys]',
                      '    Swift::print("graph:", Swift::String(decoding: try! encoder.encode(graph), as: Swift::UTF8.self))',
                      '    Swift::print("mermaid:", Swift::String(decoding: try! encoder.encode(graph.mermaid()), as: Swift::UTF8.self))',
                      '    Swift::print("dot:", Swift::String(decoding: try! encoder.encode(graph.dot()), as: Swift::UTF8.self))',
                      '}']) + '\n'


class Toolchain:
    def __init__(self, plugin, modules, link, jobs, timeout, run):
        self.swiftc = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
        self.sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        self.plugin, self.modules, self.link, self.timeout, self.run = plugin, modules, link, timeout, run
        self.spelling_scope = 'written'

    def base(self, module='Fz'):
        return [self.swiftc, '-swift-version', '6', '-strict-concurrency=complete', '-warnings-as-errors',
                '-default-isolation', 'nonisolated', '-target', 'arm64-apple-macosx13.0', '-sdk', self.sdk, '-Onone',
                '-I', str(self.modules), '-module-name', module, '-package-name', 'FuzzPackage', '-parse-as-library']

    def command(self, source, output, link, flags=(), module_directory=None):
        """Compiles the schema module. `source` is one path or a list; with `module_directory`, the compilation also
        emits the module, built for testing so the harness can read its internal schemas."""
        # A timing proxy is a script, which the compiler's plugin sandbox would not let run.
        sandbox = ['-disable-sandbox'] if str(self.plugin).endswith('.py') else []
        command = self.base()[:1] + sandbox + self.base()[1:] + [
            '-load-plugin-executable', f'{self.plugin}#StateMachineMacros', '-Xfrontend', '-dump-macro-expansions']
        for flag in flags:
            # A flag replaces the default it overrides: `-default-isolation=MainActor`, `-O`.
            if flag.startswith('-default-isolation='):
                command[command.index('-default-isolation') + 1] = flag.split('=', 1)[1]
            elif flag == '-O':
                command[command.index('-Onone')] = '-O'
            else:
                command.append(flag)
        sources = [str(s) for s in (source if isinstance(source, (list, tuple)) else [source])]
        if module_directory is not None:
            command += ['-wmo', '-enable-testing', '-emit-module', '-emit-module-path', str(module_directory / 'Fz.swiftmodule')]
        if link:
            return command + sources + self.link + ['-o', str(output)]
        return command + ['-c'] + sources + ['-o', str(output)]


MEMORY_CAP_MB = 3000


class Watched:
    def __init__(self, output, returncode, verdict, peak_mb, seconds):
        self.stdout, self.stderr, self.returncode, self.verdict, self.peak_mb, self.seconds = output, '', returncode, verdict, peak_mb, seconds


def tree_rss_mb(root):
    """Resident memory of a process and all its descendants, in megabytes."""
    table = subprocess.run(['ps', '-axo', 'pid=,ppid=,rss='], text=True, capture_output=True).stdout.split('\n')
    children, rss = {}, {}
    for line in table:
        parts = line.split()
        if len(parts) == 3:
            pid, ppid, kilobytes = map(int, parts)
            children.setdefault(ppid, []).append(pid)
            rss[pid] = kilobytes
    total, stack = 0, [root]
    while stack:
        pid = stack.pop()
        total += rss.get(pid, 0)
        stack += children.get(pid, [])
    return total / 1024


def watched(command, timeout, input_text=None, cap_mb=None):
    """Runs a command in its own process group, polling the whole tree's memory every second; kills the group when it
    passes the memory cap ("memory") or the wall-time limit ("timeout"). A command that cannot start is "launch"."""
    cap_mb = MEMORY_CAP_MB if cap_mb is None else cap_mb
    import signal, tempfile
    with tempfile.TemporaryFile('w+') as sink:
        try:
            process = subprocess.Popen(command, stdout=sink, stderr=subprocess.STDOUT, text=True, start_new_session=True,
                                       stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL)
        except OSError as error:
            return Watched(f'cannot launch {command[0]}: {error}', None, 'launch', 0, 0.0)
        if input_text is not None:
            process.stdin.write(input_text)
            process.stdin.close()
        started, peak, verdict = time.monotonic(), 0.0, 'ok'
        while process.poll() is None:
            peak = max(peak, tree_rss_mb(process.pid))
            elapsed = time.monotonic() - started
            if peak > cap_mb or elapsed > timeout:
                verdict = 'memory' if peak > cap_mb else 'timeout'
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()
                break
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                pass
        sink.seek(0)
        return Watched(sink.read(), process.returncode, verdict, round(peak), round(time.monotonic() - started, 2))


ERROR = re.compile(r'^(.*?):(\d+):(\d+): error: (.*)$', re.M)
CRASH = re.compile(r'Stack dump:|Please submit a bug report|Segmentation fault|compile command failed due to signal|no such module|'
                   r'Assertion failed|failed to communicate with external macro|plugin (?:process )?(?:crashed|terminated|exited)|'
                   r'could not be found in executable plugin')


def demangled_fingerprint(objects, authored):
    names = subprocess.run(['nm', '-j'] + [str(o) for o in objects], text=True, capture_output=True).stdout.split()
    symbols = sorted({name[1:] for name in names if name.startswith('_$s')})
    if not symbols:
        return []
    demangled = subprocess.run(['xcrun', 'swift-demangle'], input='\n'.join(symbols), text=True, capture_output=True).stdout.splitlines()
    keep = set()
    skip = re.compile(r'closure #|thunk|outlined|metadata|descriptor|lazy cache|value witness|witness table|conformance|'
                      r'FuzzMain|fuzzPrint|fuzzReport|fuzzClient|fuzzGraphs|fuzzHelper|FuzzUnrelated|implicit closure|globalinit|one-time initialization|'
                      r'unsafeMutableAddressor|default argument|variable initialization expression|__derived|hashValue|hash\(into')
    for line in demangled:
        # Underscored members are the expansion's private checks and witnesses, which follow how a spelling reads
        # (a confirmed `Never` needs no check); the interface is everything else.
        if skip.search(line) or re.search(r'(?<![\w])_[A-Za-z]\w*', line):
            continue
        # Specializations of the runtime's and the standard library's generics are theirs, not the schema's. Members
        # of an extension print an `(extension in Fz):` context, which says nothing about the member, so it goes first.
        line = line.replace('(extension in Fz):', '')
        if not re.match(r'(static )?Fz\.', re.sub(r'^\(\d+\) suspend resume partial function for ', '', line)):
            continue
        line = re.sub(r'\((\S+) in _[0-9A-F]+\)', r'\1', line).replace('`', '')
        # An async function's entry and its partial functions name one declaration; which of them a compilation
        # emits varies, so each counts as the declaration.
        line = re.sub(r'^\(\d+\) suspend resume partial function for ', '', line)
        line = re.sub(r'\(extension in Fz\):', '', line)
        # A member's context prints its extension's generic signature, as `Owned< where A: ~Swift.Copyable>.begin`, or
        # not, depending on how deeply the schema is nested (inside an extension it is left out); the member's own
        # signature follows, so the context's is dropped.
        line = re.sub(r'(\w)< where [^<>]*(?:<[^<>]*>[^<>]*)*>\.', r'\1.', line)
        # So is a member's own restatement of a suppressed requirement of its type's parameters (depth 0: `A`, `B`).
        line = re.sub(r'(?<=[ <])[A-Z]: ~Swift\.(?:Copyable|Escapable)(?:, )?', '', line)
        line = re.sub(r'(, )?\s*where\s*>', '>', line).replace('< where >', '').replace('<>', '').replace(', >', '>')
        # The authored static functions themselves, on the schema (nested in FuzzOuter or not), are not generated.
        if re.match(r'static Fz\.(?:FuzzOuter\.)?\w+\.(' + '|'.join(map(re.escape, authored)) + r')\(', line) if authored else False:
            continue
        keep.add(line)
    return sorted(keep)


def authored_functions(text):
    return sorted({m.group(1) for m in re.finditer(r'static func\s+`?([^\s(`<]+)`?', text)})


def schema_lines(text):
    """Line ranges of the schemas' declarations in a source."""
    spans, lines = [], text.split('\n')
    for index, line in enumerate(lines):
        if line.startswith('@StateMachine('):
            end = next((j for j in range(index, len(lines)) if lines[j].startswith('}')), len(lines) - 1)
            spans.append((index + 1, end + 1))
    return spans


def classify_located(text, spans=(), case_file='Case.swift'):
    """Errors with where they arise: the macro's diagnostics, its expansion, the schema's own declarations, or client
    code outside the schema, which an equivalent rewrite can break only by changing what the macro generates. Each is
    (place, message, file name, line)."""
    errors = []
    for path, line, column, message in ERROR.findall(text):
        macro = '(from macro' in message
        message = re.sub(r'\s*\(from macro \'\w+\'\)', '', message).strip()
        name = os.path.basename(path)
        place = 'macro' if macro else ('expansion' if '@__swiftmacro' in path or 'macro expansion' in path else 'authored')
        if place == 'authored' and (name != case_file or (spans and not any(a <= int(line) <= b for a, b in spans))):
            place = 'client'
        if name in ('Main.swift',) and place == 'client':
            place = 'harness'
        error = (place, message, name, int(line))
        if error not in errors:
            errors.append(error)
    return errors


def classify(text, spans=()):
    unique = []
    for place, message, _, _ in classify_located(text, spans):
        if (place, message) not in unique:
            unique.append((place, message))
    return unique


# Statuses of a case that compiled but did not run to completion, and of one whose compilation never finished.
RUN_FAILURES = {'run-failed', 'run-timeout', 'run-memory', 'link-error', 'harness-error'}
RESOURCE_FAILURES = {'crash', 'timeout', 'memory', 'launch'}


def compile_case(toolchain, directory, text, probe=True, flags=()):
    """Compiles the schema module, then the harness and any client section in a module that imports it, links, and
    runs. Returns the outcome."""
    directory.mkdir(parents=True, exist_ok=True)
    files, client = split_case(text)
    harness_from = None
    if toolchain.run:
        harness_from = files['Case.swift'].count('\n') + 2
        files['Case.swift'] = files['Case.swift'] + graph_accessor(files['Case.swift'])
    sources = []
    for name, content in files.items():
        (directory / name).write_text(content)
        sources.append(directory / name)
    module_directory = directory / 'module'
    module_directory.mkdir(exist_ok=True)
    started = time.monotonic()
    output = directory / 'Case.o'
    command = toolchain.command(sources, output, link=False, flags=flags, module_directory=module_directory)
    result = watched(command, toolchain.timeout)
    log, code = result.stdout, result.returncode
    if result.verdict != 'ok':
        log, code = log + f'\n{result.verdict} after {result.seconds}s at {result.peak_mb} MB', result.verdict
    elapsed = time.monotonic() - started
    (directory / 'compile.log').write_text(log)
    case_text = files['Case.swift']
    spans = schema_lines(case_text)
    located = [(('harness' if harness_from and name == 'Case.swift' and line >= harness_from else place), message, name, line)
               for place, message, name, line in classify_located(log, spans)]
    outcome = dict(seconds=round(elapsed, 2), errors=[(p, m) for p, m, _, _ in located], located=located, command=command,
                   peak_mb=result.peak_mb,
                   client_lines=sorted({line for place, _, name, line in located if place == 'client' and name == 'Case.swift'}))
    if code in ('timeout', 'memory', 'launch'):
        outcome['status'] = code
        outcome['crash'] = {'memory': 'over memory cap', 'timeout': 'timeout', 'launch': 'cannot launch'}[code] + f' ({result.peak_mb} MB, {result.seconds}s)'
        return outcome
    if CRASH.search(log) or (isinstance(code, int) and code < 0):
        outcome['status'] = 'crash'
        outcome['crash'] = (CRASH.search(log) or re.search('.*', log)).group(0)[:200]
        return outcome
    if code != 0:
        places = {place for place, _ in outcome['errors']}
        outcome['status'] = ('macro-diagnostic' if 'macro' in places else 'expansion-error' if 'expansion' in places
                             else 'client-error' if 'client' in places else 'harness-error' if places == {'harness'}
                             else 'authored-error')
        return outcome
    outcome['status'] = 'ok'
    outcome['fingerprint'] = demangled_fingerprint([output], authored_functions(text))
    outcome['label_problems'] = label_order_problems(outcome['fingerprint'], text)
    if toolchain.run:
        # The harness and the client section form a module of their own that imports the schema's module, so the
        # client sees the schema as another module does.
        (directory / 'Main.swift').write_text(harness(text))
        mains = [directory / 'Main.swift']
        if client is not None:
            (directory / 'Client.swift').write_text(order_client_arguments(client, text.split(CLIENT_MARKER, 1)[0]))
            mains.append(directory / 'Client.swift')
        linker = toolchain.base('FzMain') + ['-I', str(module_directory)] + [str(m) for m in mains] + [str(output)] + toolchain.link + ['-o', str(directory / 'case')]
        linked = watched(linker, toolchain.timeout)
        if linked.verdict != 'ok' or linked.returncode != 0:
            located = classify_located(linked.stdout)
            outcome['located'] = outcome['located'] + located
            outcome['errors'] = [(p, m) for p, m, _, _ in located] or [('link', linked.stdout[-300:])]
            if linked.verdict != 'ok':
                outcome['status'], outcome['crash'] = 'run-timeout', f'harness compilation {linked.verdict} ({linked.seconds}s)'
            elif any(p == 'client' for p, _, _, _ in located):
                outcome['status'] = 'client-error'
            elif any(p == 'harness' for p, _, _, _ in located):
                outcome['status'] = 'harness-error'
            else:
                outcome['status'] = 'link-error'
            (directory / 'harness.log').write_text(linked.stdout)
            return outcome
        ran = watched([str(directory / 'case')], 60)
        (directory / 'case').unlink(missing_ok=True)
        if ran.verdict != 'ok' or ran.returncode != 0:
            outcome['status'] = {'timeout': 'run-timeout', 'memory': 'run-memory'}.get(ran.verdict, 'run-failed')
            outcome['crash'] = f'the program {ran.verdict if ran.verdict != "ok" else "exited " + str(ran.returncode)}: {ran.stdout[-300:]}'
            outcome['errors'] = [('run', outcome['crash'])]
            return outcome
        graphs = raw_graphs(ran.stdout)
        outcome['run'] = normalize_run(ran.stdout)
        outcome['report'] = next((line[len('report: '):] for line in ran.stdout.splitlines() if line.startswith('report: ')), None)
        outcome['spellings'] = sorted({json.dumps(g, sort_keys=True) for g in graphs})
        outcome['diagram_problems'] = diagram_problems(ran.stdout)
        if probe is True or (callable(probe) and probe(outcome['spellings'], text)):
            outcome['spelling_problems'] = check_spellings(toolchain, directory, text, graphs)
    output.unlink(missing_ok=True)
    return outcome


def raw_graphs(stdout):
    return [json.loads(line[len('graph: '):]) for line in stdout.splitlines() if line.startswith('graph: ')]


def body_of(text, opening):
    """The text between the brace that `opening` (a match ending at `{`) opens and its matching brace."""
    depth, index = 1, opening.end()
    while index < len(text) and depth:
        depth += {'{': 1, '}': -1}.get(text[index], 0)
        index += 1
    return text[opening.end():index - 1]


def split_top(text, braces=False):
    """Splits on commas outside brackets (and braces, with `braces`)."""
    parts, depth, current = [], 0, ''
    opening, closing = ('([<{', ')]>}') if braces else ('([<', ')]>')
    for index, char in enumerate(text):
        if char == '>' and text[index - 1:index] == '-':
            current += char
            continue
        depth += char in opening and 1 or (char in closing and -1 or 0)
        if char == ',' and depth == 0:
            parts.append(current)
            current = ''
        else:
            current += char
    return parts + [current]


def authored_payloads(text, schema):
    """The authored payload spellings of a schema's phases and Input cases, by case name."""
    opening = re.search(r'enum\s+`?' + re.escape(schema) + r'`?[^{]*\{', text)
    if not opening:
        return {}, {}
    body = body_of(text, opening)
    phases = {}
    for match in re.finditer(r'^\s*(?:@[\w.]+(?:\([^)\n]*\))?\s+)*case\s+`?(\w+)`?\((.*)\)\s*$', strip_comments(body), re.M):
        phases.setdefault(match.group(1), split_top(match.group(2))[0].split('=')[0].strip())
    inputs = {}
    opened = re.search(r'enum\s+Input\b[^{]*\{', body)
    if opened:
        for case in re.finditer(r'\bcase\s+([^\n;}]+)', strip_comments(body_of(body, opened))):
            for item in split_top(case.group(1)):
                item = item.strip()
                named = re.match(r'`?(\w+)`?\s*\((.*)\)\s*$', item, re.S)
                if named:
                    inputs[named.group(1)] = named.group(2).strip()
    return phases, inputs


def strip_comments(text):
    return re.sub(r'/\*.*?\*/', ' ', re.sub(r'//[^\n]*', '', text), flags=re.S)


def scope_members(text, schema, scope):
    """Names declared directly in a namespace of the schema (`Input`, or an operation), which a spelling written there
    finds before the schema's own members."""
    opening = re.search(r'enum\s+`?' + re.escape(schema) + r'`?[^{]*\{', text)
    if not opening:
        return set()
    inner = re.search(r'enum\s+`?' + re.escape(scope) + r'`?\s*(?::[^{]*)?\{', body_of(text, opening))
    if not inner:
        return set()
    bodies = [body_of(body_of(text, opening), inner)]
    # Members an extension of the namespace declares are members too.
    for extension in re.finditer(r'extension\s+(?:\w+\.)*' + re.escape(schema) + r'\.' + re.escape(scope) + r'\b[^{]*\{', text):
        bodies.append(body_of(text, extension))
    return {name for body in bodies for name in re.findall(r'(?:struct|enum|class|typealias|protocol)\s+`?([^\s`<:=({]+)`?', body)}


def qualify_in(spelling, members, prefix):
    """Spells at schema scope what `spelling` means inside the namespace `prefix` declaring `members`."""
    spelling = re.sub(r'(?<![\w.`])Self\.', prefix + '.', spelling)
    def replace(match):
        name = match.group(2) or match.group(3)
        if spelling[:match.start()].rstrip().endswith('.') or name not in members:
            return match.group(0)
        return f'{prefix}.{match.group(0)}'
    return re.sub(r'(?<![\w.`])(`([^`]+)`|([^\W\d]\w*))', replace, spelling)


def member_opening(text, start, end, name):
    """The index just past the `{` of the enum `name` declared directly in text[start:end], or None."""
    mask = code_mask(text)
    depth = 0
    index = start
    pattern = re.compile(r'\benum\s+(?:`' + re.escape(name) + r'`|' + re.escape(name) + r'(?![\w`.]))[^{;]*\{')
    while index < end:
        char = text[index]
        if mask[index] and char == '{':
            depth += 1
        elif mask[index] and char == '}':
            depth -= 1
        elif mask[index] and depth == 0 and char == 'e':
            match = pattern.match(text, index)
            if match and (index == 0 or not (text[index - 1].isalnum() or text[index - 1] == '_')):
                return match.end()
        index += 1
    return None


def schema_opening(text, schema):
    """The index just past the `{` of the schema's body, and the index of its closing brace."""
    for match in re.finditer(r'@StateMachine\([^)]*\)\s*(?:@\w+(?:\([^)]*\))?\s*)*(?:\w+\s+)*enum\s+`?' + re.escape(schema) + r'`?[^{]*\{', text):
        return match.end(), match.end() + len(body_of(text, match))
    return None, None


def spelling_probes(text, graphs, scope='written'):
    """Probes that read each type spelling a graph exports, exactly as exported, in the scope the guide says it is
    meant in, beside the authored type read where it is declared. Returns the probe source, their labels, and the
    records no probe could be made for. With `scope='schema'`, every exported spelling is read at the schema's scope
    instead: the contract the macro documented before exported spellings followed the scope they are written in."""
    insertions, labels, missing = [], [], []
    for graph in graphs:
        schema = graph.get('name')
        if not schema:
            continue
        opened, closed = schema_opening(text, schema)
        if opened is None:
            missing.append(f'{schema}: no schema declaration to probe')
            continue
        phases, inputs = authored_payloads(text, schema)

        def add(site, exported, exported_at, authored, authored_at):
            if exported_at is None or authored_at is None:
                missing.append(f'{site}: no scope to read it in')
                return
            index = len(labels)
            labels.append(dict(site=site, exported=exported))
            insertions.append((exported_at if scope == 'written' else opened, f'static func _fuzzSpell{index}e(_: ({exported}).Type) {{}}'))
            insertions.append((authored_at, f'static func _fuzzSpell{index}a(_: ({authored}).Type) {{}}'))

        input_at = member_opening(text, opened, closed, 'Input')
        for phase in graph.get('phases', []):
            if phase['id'] not in phases:
                missing.append(f"{schema} phase {phase['id']} payload: no authored payload found")
                continue
            add(f"{schema} phase {phase['id']} payload", phase['payload'], opened, phases[phase['id']], opened)
        for case in graph.get('inputs', []):
            if case.get('payload') is None:
                continue
            if case['id'] not in inputs:
                missing.append(f"{schema} input {case['id']} payload: no authored payload found")
                continue
            add(f"{schema} input {case['id']} payload", case['payload'], input_at, inputs[case['id']], input_at)
        for operation in graph.get('operations', []):
            at = member_opening(text, opened, closed, operation['id'])
            members = scope_members(text, schema, operation['id'])
            for field, alias, default in (('input', 'Input', 'Swift::Void'), ('output', 'Output', 'Swift::Void'),
                                          ('failure', 'Failure', 'Swift::Never'), ('key', 'Key', None)):
                if operation.get(field) is None:
                    if field == 'key' and 'Key' in members:
                        missing.append(f"{schema} operation {operation['id']} key: the namespace declares a Key the graph leaves out")
                    continue
                authored = alias if alias in members else default
                if authored is None:
                    missing.append(f"{schema} operation {operation['id']} {field}: no authored Key")
                    continue
                add(f"{schema} operation {operation['id']} {field}", operation[field], at, authored, at)
        for event in graph.get('events', []):
            at = member_opening(text, opened, closed, event['id'])
            authored = 'Payload' if 'Payload' in scope_members(text, schema, event['id']) else 'Swift::Void'
            add(f"{schema} event {event['id']} payload", event['payload'], at, authored, at)
    expected = sum(len(g.get('phases', [])) + sum(1 for c in g.get('inputs', []) if c.get('payload') is not None)
                   + sum(3 + (o.get('key') is not None) for o in g.get('operations', [])) + len(g.get('events', []))
                   for g in graphs)
    if len(labels) + len(missing) < expected:
        missing.append(f'graph records: {expected} spelled fields, {len(labels)} probed')
    source = text
    for at, probe in sorted(insertions, key=lambda item: -item[0]):
        source = source[:at] + '\n        ' + probe + '\n' + source[at:]
    return source, labels, missing


def check_spellings(toolchain, directory, text, graphs):
    """Compiles the case with spelling probes; returns problems, each `site: detail`: a spelling that names another
    type, one that names none, a probe that is missing, or probes that do not compile."""
    files, _ = split_case(text)
    probed, labels, missing = spelling_probes(files['Case.swift'], graphs, toolchain.spelling_scope)
    problems = list(missing)
    if not labels:
        return problems
    sources = []
    for name, content in files.items():
        (directory / f'Probe-{name}').write_text(probed if name == 'Case.swift' else content)
        sources.append(directory / f'Probe-{name}')
    plain = Toolchain.__new__(Toolchain)
    plain.__dict__.update(toolchain.__dict__)
    command = plain.command(sources, directory / 'Spellings.o', link=False)
    command.remove('-dump-macro-expansions')
    command.remove('-Xfrontend')
    command.insert(command.index('-c'), '-wmo')
    result = watched(command, toolchain.timeout)
    if result.verdict != 'ok':
        return problems + [f'spelling probes: the compilation {result.verdict} ({result.seconds}s, {result.peak_mb} MB)']
    lines = probed.split('\n')
    if result.returncode != 0:
        named = []
        for path, line, column, message in ERROR.findall(result.stdout):
            source_line = lines[int(line) - 1] if path.endswith('Probe-Case.swift') and int(line) <= len(lines) else ''
            probe = re.search(r'_fuzzSpell(\d+)([ea])', source_line)
            if probe and int(probe.group(1)) < len(labels):
                label = labels[int(probe.group(1))]
                side = 'exported' if probe.group(2) == 'e' else 'authored'
                named.append(f"{label['site']}: the {side} spelling {label['exported']!r} does not resolve where it is meant: {message}")
        return problems + (sorted(set(named)) or [f'spelling probes: do not compile: {describe(dict(status="error", errors=classify(result.stdout)))}'])
    names = subprocess.run(['nm', '-j', str(directory / 'Spellings.o')], text=True, capture_output=True).stdout.split()
    probe_symbols = [n[1:] for n in names if '_fuzzSpell' in n and n.startswith('_$s')]
    demangled = subprocess.run(['xcrun', 'swift-demangle'], input='\n'.join(probe_symbols), text=True, capture_output=True).stdout.splitlines()
    types = {}
    for line in demangled:
        match = re.search(r'_fuzzSpell(\d+)([ea])\((.*)\) -> \(\)$', line)
        if match:
            types[(int(match.group(1)), match.group(2))] = match.group(3)
    (directory / 'Spellings.o').unlink(missing_ok=True)
    return problems + compare_probe_types(labels, types)


def normalize_run(stdout):
    lines = []
    for line in stdout.splitlines():
        if line.startswith('graph: '):
            graph = json.loads(line[len('graph: '):])
            lines.append('graph: ' + json.dumps(strip_spellings(graph), sort_keys=True, ensure_ascii=False))
        elif not line.startswith(('mermaid: ', 'dot: ')):
            # The renderings follow the graph; they are checked against it by themselves.
            lines.append(line)
    return lines


def strip_spellings(graph):
    """A graph's structure with the type spellings it echoes from the source replaced by a marker, at exactly the
    fields that hold them; its lists in their order."""
    graph = json.loads(json.dumps(graph))
    for list_name, fields in GRAPH_SPELLED_FIELDS.items():
        for record in graph.get(list_name, None) or []:
            for field in fields:
                if record.get(field) is not None:
                    record[field] = '<spelling>'
    return graph


# --- Diagram renderings --------------------------------------------------------------------------------------------
# No Mermaid or Graphviz parser ships with the toolchain, so each rendering is read by a strict reader of the subset
# the library writes, and must describe exactly the graph it renders: every state, entry, edge, and exit, in order.
# Mermaid's state-diagram lexer (`stateDiagram.jison` of Mermaid 11.12, `%options case-insensitive`) reads these words,
# followed by whitespace, as the start of a statement wherever a state identifier may stand, so none of them, in any
# case, may be a bare state identifier; the words were confirmed against that grammar, and words it reads as plain
# identifiers there (`end`, `left`, `empty`, `direction`, `accTitle`, `fork`, `TB`, ...) are not listed.
MERMAID_RESERVED = {'class', 'classdef', 'click', 'default', 'href', 'note', 'scale', 'state', 'statediagram', 'style'}
DOT_KEYWORDS = {'node', 'edge', 'graph', 'digraph', 'subgraph', 'strict'}


def mermaid_label(text):
    """Decodes a label the reader accepts (letters, digits, `_`, and decimal entity codes), or None."""
    # Mermaid's own placeholders for entity codes are `ß` and `ﬂ`, so a label holds them only as codes.
    if not re.fullmatch(r'(?:[^\W]|#\d+;)*', text) or re.search('[\u00df\ufb02]', text):
        return None
    return re.sub(r'#(\d+);', lambda m: chr(int(m.group(1))), text)


def read_mermaid(text):
    """(state labels by identifier, transitions as (source, destination, label)) or a problem string."""
    if not text.endswith('\n'):
        return 'mermaid: the rendering does not end with a line break'
    lines = text[:-1].split('\n')
    if lines[0] != 'stateDiagram-v2':
        return f'mermaid: first line {lines[0]!r}'
    states, transitions = {}, []

    def node(token):
        if token == '[*]':
            return token
        # The lexer's identifier is `[^:\n\s\-\{]+`; `#` and `%%` start comments.
        if not re.fullmatch(r'[^:\s\-{#%]+', token):
            raise ValueError(f'state identifier {token!r} is not a plain identifier')
        if token.lower() in MERMAID_RESERVED:
            raise ValueError(f'state identifier {token!r} is a Mermaid keyword')
        return token
    for number, line in enumerate(lines[1:], 2):
        try:
            declared = re.fullmatch(r'    state "([^"]*)" as (\S+)', line)
            if declared:
                label = mermaid_label(declared.group(1))
                if label is None:
                    raise ValueError(f'state label {declared.group(1)!r} has characters Mermaid reads')
                if declared.group(2) in states:
                    raise ValueError(f'state {declared.group(2)!r} declared twice')
                states[node(declared.group(2))] = label
                continue
            arrow = re.fullmatch(r'    (\S+) --> (\S+)(?: : (.*))?', line)
            if not arrow:
                raise ValueError(f'unreadable line {line!r}')
            label = None
            if arrow.group(3) is not None:
                label = mermaid_label(arrow.group(3))
                if label is None:
                    raise ValueError(f'transition label {arrow.group(3)!r} has characters Mermaid reads')
            transitions.append((node(arrow.group(1)), node(arrow.group(2)), label))
        except ValueError as error:
            return f'mermaid line {number}: {error}'
    return states, transitions


DOT_STRING = r'"((?:[^"\\]|\\.)*)"'


def dot_string(text):
    """A DOT quoted string's text as Graphviz renders it, or None for an escape it would not read as itself."""
    out, index = [], 0
    while index < len(text):
        if text[index] == '\\':
            following = text[index + 1:index + 2]
            if following not in ('"', '\\', 'n', 'r'):
                return None
            out.append({'"': '"', '\\': '\\', 'n': '\n', 'r': '\r'}[following])
            index += 2
        else:
            out.append(text[index])
            index += 1
    return ''.join(out).replace('&amp;', '&')


def read_dot(text):
    """(name, nodes as (name, terminal), edges as (source, destination, label, dashed)) or a problem string."""
    if not text.endswith('\n'):
        return 'dot: the rendering does not end with a line break'
    lines = text[:-1].split('\n')
    head = re.fullmatch(r'digraph ' + DOT_STRING + r' \{', lines[0])
    if not head or lines[-1] != '}' or lines[1] != '    "*" [shape=point];':
        return f'dot: unreadable frame {lines[0]!r} … {lines[-1]!r}'
    name, nodes, edges = dot_string(head.group(1)), [], []
    for number, line in enumerate(lines[2:-1], 3):
        match = re.fullmatch(r'    ' + DOT_STRING + r'( \[peripheries=2\])?;', line)
        if match:
            nodes.append((dot_string(match.group(1)), bool(match.group(2))))
            continue
        match = re.fullmatch(r'    ' + DOT_STRING + r' -> ' + DOT_STRING + r'(?: \[label=' + DOT_STRING + r'(, style=dashed)?\])?;', line)
        if not match:
            return f'dot line {number}: unreadable line {line!r}'
        edges.append((dot_string(match.group(1)), dot_string(match.group(2)),
                      dot_string(match.group(3)) if match.group(3) is not None else None, bool(match.group(4))))
    if None in [name] + [n for n, _ in nodes] + [x for e in edges for x in e[:3] if x is not None]:
        return 'dot: a quoted string with an escape Graphviz does not read as itself'
    return name, nodes, edges


def diagram_expectation(graph):
    entries = [(None, graph['initial'], None)] + [(None, p, 'restored') for p in graph.get('restorable', []) if p != graph['initial']]
    edges = [(e['source'], e['destination'], e['name']) for e in graph.get('edges', [])]
    exits = [(p, None, None) for p in graph.get('terminal', [])]
    return entries + edges + exits


def check_diagrams(graph, mermaid, dot):
    """Problems, each `site: detail`, of one graph's two renderings."""
    problems, name = [], graph.get('name', '?')
    expected = diagram_expectation(graph)
    read = read_mermaid(mermaid)
    if isinstance(read, str):
        problems.append(f'{name} {read}')
    else:
        states, transitions = read
        label = lambda token: None if token == '[*]' else states.get(token, token)
        got = [(label(a), label(b), l) for a, b, l in transitions]
        if got != expected:
            problems.append(f'{name} mermaid: describes {got[:6]} …, the graph {expected[:6]} …')
        if states and sorted(states.values()) != sorted(set(p['id'] for p in graph['phases']) | {x for t in expected for x in t[:2] if x}):
            problems.append(f'{name} mermaid: declares the states {sorted(states.values())}')
    read = read_dot(dot)
    if isinstance(read, str):
        problems.append(f'{name} {read}')
    else:
        title, nodes, edges = read
        got = [(None if a == '*' else a, b, l if not (a == '*' and l is None) else None) for a, b, l, _ in edges]
        want = [(a, b, l) for a, b, l in expected if b is not None]
        if title != name or nodes != [(p['id'], p['id'] in graph.get('terminal', [])) for p in graph['phases']] or got != want:
            problems.append(f'{name} dot: describes {title!r} {nodes[:4]} {got[:4]} …, the graph {want[:4]} …')
    return problems


def diagram_problems(stdout):
    lines = stdout.splitlines()
    problems = []
    for index, line in enumerate(lines):
        if line.startswith('graph: ') and index + 2 < len(lines) and lines[index + 1].startswith('mermaid: ') and lines[index + 2].startswith('dot: '):
            problems += check_diagrams(json.loads(line[7:]), json.loads(lines[index + 1][9:]), json.loads(lines[index + 2][5:]))
        elif line.startswith('graph: '):
            problems.append('renderings: a graph printed without its renderings')
    return problems


# --- Initializer labels --------------------------------------------------------------------------------------------

def init_arguments(line):
    match = re.match(r'(.*?init\()(.*)(\) -> .*)$', line)
    if not match:
        return None
    return match.group(1), [a.strip() for a in split_top(match.group(2))], match.group(3)


def movable_labels(line, text):
    """The driver and handler arguments of an initializer line: in a `Drivers` bundle every argument, labeled after its
    operation; elsewhere the `<op>Driver:` and `on<Event>:` arguments of the declared operations and events."""
    parsed = init_arguments(line)
    if not parsed:
        return None, []
    operations, events = declaration_order(text)
    bundle = re.search(r'Drivers\.(__allocating_)?init\(', line) is not None
    order = [lower_first(o) for o in operations] if bundle else expected_labels(text)
    labels = [re.match(r'(\w+):', a).group(1) if re.match(r'(\w+):', a) else '_' for a in parsed[1]]
    return order, [(i, l) for i, l in enumerate(labels) if l in order]


def label_order_problems(fingerprint, text):
    """Each initializer whose driver and handler labels are not in the order the guide documents: one driver per
    operation, in the order the operations are declared, then one handler per event, in theirs."""
    problems = []
    for line in fingerprint:
        order, movable = movable_labels(line, text)
        if movable and [l for _, l in movable] != [l for l in order if l in {m for _, m in movable}]:
            problems.append(f"labels {line.split('(')[0]}: {[l for _, l in movable]}, declared {[l for l in order if l in {m for _, m in movable}]}")
    return problems


def reorder_labels(line, text):
    """The initializer line with its driver and handler arguments in `text`'s declaration order."""
    parsed = init_arguments(line)
    order, movable = movable_labels(line, text)
    if not parsed or not movable:
        return line
    head, arguments, tail = parsed
    slots = [i for i, _ in movable]
    ranked = sorted((arguments[i] for i in slots), key=lambda a: order.index(re.match(r'(\w+):', a).group(1)))
    for slot, argument in zip(slots, ranked):
        arguments[slot] = argument
    return head + ', '.join(arguments) + tail


# The graph lists the guide and `StateMachineGraph` document as following declaration order: a rewrite that reorders
# declarations may permute these, and only these.
DECLARATION_ORDERED = {'members': {'terminal', 'restorable', 'phases', 'inputs', 'scopes', 'operations', 'events', 'edges',
                                   'routers', 'candidates', 'activeIn'},
                       'cases': {'inputs', 'scopes', 'terminal', 'restorable', 'phases'},
                       # One transition `from:` several phases is an edge per phase, in the order the list writes.
                       'lists': {'starts', 'emits', 'cancels', 'invalidates', 'requires', 'activeIn', 'restorable', 'edges'}}


def unorder(value, keys, key=None):
    """`value` with the lists under `keys` sorted, every other list kept in order."""
    if isinstance(value, dict):
        return {k: unorder(v, keys, k) for k, v in value.items()}
    if isinstance(value, list):
        items = [unorder(v, keys) for v in value]
        return sorted(items, key=lambda v: json.dumps(v, sort_keys=True)) if key in keys else items
    return value


def run_lines(lines, keys):
    if not keys:
        return lines
    out = []
    for line in lines:
        if line.startswith('graph: '):
            line = 'graph: ' + json.dumps(unorder(json.loads(line[7:]), keys), sort_keys=True, ensure_ascii=False)
        out.append(line)
    return out


# ---------------------------------------------------------------------------------------------------------------------
# Oracles.

def quoted_names(message):
    return [n.lstrip('@.') for n in re.findall(r"'([^']+)'", message)]


def declaration_span(lines, line):
    """The lines of the member declaration a diagnostic at `line` belongs to: its attributes, its declaration, and its
    body. A diagnostic the macro anchors at the enclosing function or member, rather than at the token a rewrite
    changed, stands at the site when that member holds the change."""
    indent = lambda text: len(text) - len(text.lstrip())
    first = line
    # Up to the member's first line: a line at most as indented as the diagnostic's that starts a declaration.
    while first > 1 and not re.match(r'\s*(@|case\b|(\w+\s+)*(func|struct|enum|class|actor|protocol|typealias|var|let|init)\b)', lines[first - 1]):
        first -= 1
    if re.match(r'\s*(@StateMachine\(|(\w+\s+)*enum\s+\S+[^{]*\{\s*$)', lines[first - 1]) and indent(lines[first - 1]) == 0:
        # The schema itself is no member: a diagnostic there is one of the whole graph.
        return {line}
    base = indent(lines[first - 1])
    while first > 1 and re.match(r'\s*(@|#if|#endif)', lines[first - 2]) and indent(lines[first - 2]) == base:
        first -= 1
    last = line
    while last < len(lines) and re.match(r'\s*(@[\w.]+(\(.*\))?\s*$|#if|#endif)', lines[last - 1]):
        last += 1
    while last < len(lines) and lines[last].strip() and (indent(lines[last]) > base or (indent(lines[last]) == base and lines[last].strip().startswith(('}', ')')))):
        last += 1
    return set(range(first, last + 1))


ANCHORS = collections.Counter()


def at_site(case, line, message, name='Case.swift'):
    """Whether a diagnostic stands where the case changed its schema: on a changed line, in the member declaration
    that holds the change, on a line that declares or spells a name the message quotes, or, for a diagnostic of the
    whole graph at the schema's attribute, with a quoted name declared on a changed line. Which of those anchored
    it is counted in ANCHORS."""
    kind = site_kind(case, line, message, name)
    if kind:
        ANCHORS[(kind, re.sub(r"'[^']*'", "'…'", message)[:90])] += 1
    return kind is not None


def site_kind(case, line, message, name):
    if name != 'Case.swift':
        return None
    changed = rewritten_lines(case)
    lines = case['text'].split('\n')
    if line in changed:
        return 'token line'
    if declaration_span(lines, line) & changed:
        return 'enclosing declaration'
    source = lines[line - 1] if 0 < line <= len(lines) else ''
    names = [n for n in quoted_names(message) if n]
    spelled = lambda text: any(re.search(r'(?<![\w])' + re.escape(n) + r'(?![\w])', text) for n in names)
    if spelled(source) or any(spelled(lines[n - 1]) for n in declaration_span(lines, line) if 0 < n <= len(lines) and n <= line + 1):
        # The diagnostic names the declaration it is anchored at (its attribute line, or the line after it).
        return 'named declaration'
    # A diagnostic of the whole graph stands at the schema's attribute; it is at the site when a name it quotes is
    # declared on a changed line.
    declares = lambda text: any(re.search(r'\b(case|struct|enum|class|actor|protocol|typealias|func)\s+`?' + re.escape(n) + r'\b', text) for n in names)
    if source.lstrip().startswith('@StateMachine(') and any(declares(lines[r - 1]) for r in changed if 0 < r <= len(lines)):
        return 'schema attribute'
    return None


def refusal_matches(pattern, case, variant, exact=False):
    """Whether the variant is refused with a diagnostic matching `pattern` at the changed site; with `exact`, also
    that nothing else accompanies it but what a refused expansion leaves undeclared."""
    located = variant.get('located', [])
    macro = [(m, line, name) for p, m, name, line in located if p == 'macro']
    if not any(re.search(pattern, m) and at_site(case, line, m, name) for m, line, name in macro):
        return False
    if not exact:
        return True
    if any(not re.search(pattern, m) for m, _, _ in macro):
        return False
    # Besides the refusal: names the refused expansion leaves undeclared, the harness's references to them, Swift's own
    # error at the declaration the rewrite changed, or a documented consequence of the case's rewrites.
    lines, changed = case['text'].split('\n'), rewritten_lines(case)
    documented = [e['pattern'] for e in LIMITS if any(re.search(e['rewrites'], n) for n in case['rewrites'])]
    return all(p in ('macro', 'harness') or CASCADE.search(m) or (name == 'Case.swift' and declaration_span(lines, line) & changed)
               or any(re.search(d, m) for d in documented) for p, m, name, line in located)


def limit_for(case, observed, detail, role, variant=None):
    """The id of the documented limit a case's observation meets, or None. A macro diagnostic must stand at the
    changed site."""
    rewrites = case['rewrites'] if isinstance(case, dict) else case
    for entry in LIMITS:
        if not re.fullmatch(entry['observed'], observed):
            continue
        if not any(re.search(entry['rewrites'], name) for name in rewrites):
            continue
        if entry.get('role') and not re.fullmatch(entry['role'], role):
            continue
        if observed == 'macro-diagnostic' and isinstance(case, dict) and variant is not None:
            if refusal_matches(entry['pattern'], case, variant, entry.get('exact', False)):
                return entry['id']
            continue
        if re.search(entry['pattern'], detail):
            return entry['id']
    return None


def apply_mapping(lines, mapping):
    out = []
    for line in lines:
        for old, new in mapping.items():
            # A name of another module (`Swift.Bool`) is never the renamed declaration.
            line = re.sub(r'(?<![\w])(?<!Swift\.)(?<!StateMachine\.)' + re.escape(old) + r'(?![\w])', lambda m: new, line)
        out.append(line)
    return out


def describe(outcome):
    if outcome['status'] in ('ok',):
        return 'compiles'
    if outcome['status'] in RESOURCE_FAILURES:
        return {'memory': 'over memory cap'}.get(outcome['status'], outcome['status']) + (': ' + outcome.get('crash', '') if outcome.get('crash') else '')
    if outcome['status'] in RUN_FAILURES and outcome.get('crash'):
        return f"{outcome['status']}: {outcome['crash'][:220]}"
    first = next((m for p, m in outcome['errors'] if p not in ('authored', 'client')), None) or (outcome['errors'][0][1] if outcome['errors'] else '')
    return f"{outcome['status']}: {first[:220]}"


def order_free(case):
    """Which declaration-ordered graph lists a case's rewrites may permute."""
    return [kind for rewrite, kind in (('reorder-members', 'members'), ('reorder-cases', 'cases'), ('reorder-lists', 'lists'))
            if rewrite in case['rewrites']]


def rewritten_lines(case):
    """Line numbers of the case's text that its rewrites changed relative to its seed."""
    import difflib
    key = (case['seed'], case['text'])
    if key in _REWRITTEN:
        return _REWRITTEN[key]
    seed = SEED_TEXTS.get(case['seed'], '').split('\n')
    lines = set()
    for tag, a1, a2, b1, b2 in difflib.SequenceMatcher(None, seed, case['text'].split('\n'), autojunk=False).get_opcodes():
        if tag != 'equal':
            lines.update(range(b1 + 1, b2 + 2))
    _REWRITTEN[key] = lines
    return lines


_REWRITTEN = {}


def problems_of(outcome):
    return (outcome.get('spelling_problems', []) + outcome.get('diagram_problems', []) + outcome.get('label_problems', [])) if outcome else []


def problem_site(problem):
    return problem.split(': ', 1)[0]


def fresh_problems(variant, references, mapping):
    """The variant's problems at sites where no reference has one: a seed's own problem fails as the seed's, and every
    other site is judged on its own."""
    known = {problem_site(p) for ref in references for p in apply_mapping(problems_of(ref), mapping)}
    return [p for p in problems_of(variant) if problem_site(p) not in known]


def last_special(case):
    specials = [n for n, k in zip(case['rewrites'], case['kinds']) if k != 'eq']
    return specials[-1] if specials else None


def judge(case, base, control, variant, prefix=None):
    """Returns (verdict, expectation, observation). verdict: pass, limit:<id>, policy, fail, artefact. `prefix`, for a
    composed case whose last rewrite is not an equivalence, is the verdict of the other rewrites alone."""
    kinds = case['kinds']
    names = case['rewrites']
    role = case.get('role', 'value')
    if prefix is not None:
        verdict, expected, observed = prefix
        if verdict == 'fail':
            return 'fail', f'the other rewrites alone: {expected}', observed
        if verdict.startswith('limit:') or verdict == 'artefact':
            # The other rewrites meet a documented limit (or a fuzzer artefact) first; this case cannot tell more.
            return verdict, 'the other rewrites alone meet a documented limit', observed
    # Swift rejecting client code where a rewrite changed it is the rewrite's error, not the macro's.
    if variant['status'] == 'client-error' and set(variant.get('client_lines', [])[:1]) & rewritten_lines(case):
        return 'artefact', 'valid rewritten client code', describe(variant)
    if variant['status'] in RESOURCE_FAILURES:
        return 'fail', 'no crash, hang, or memory past the cap', describe(variant)
    if variant['status'] in RUN_FAILURES:
        return 'fail', 'a program that links and runs to completion, or a rejection before it', describe(variant)
    if case.get('expect'):
        entry = next(e for e in LIMITS if e['id'] == case['expect'])
        if variant['status'] == 'macro-diagnostic' and refusal_matches(entry['pattern'], case, variant, True):
            return f"limit:{entry['id']}", f"exactly the documented refusal ({entry['id']})", describe(variant)
        # Another rewrite of the composition may meet a documented refusal of its own first.
        others = dict(case, rewrites=[n for n in names if not re.search(entry['rewrites'], n)])
        other = limit_for(others, 'macro-diagnostic', '', role, variant) if variant['status'] == 'macro-diagnostic' else None
        if other:
            return f'limit:{other}', f"the documented refusal ({entry['id']}) or another rewrite's", describe(variant)
        return 'fail', f"exactly the documented refusal ({entry['id']}) at the changed site, alone: {entry['pattern']}", describe(variant)
    mapping = case.get('mapping', {})
    fresh = fresh_problems(variant, [base, control], mapping)
    if fresh and 'break' not in kinds:
        return 'fail', 'every exported spelling names the authored type where it is meant, both renderings read as the graph, and initializer labels follow declaration order', fresh[0]
    if 'break' in kinds:
        if variant['status'] == 'ok':
            return 'fail', 'rejected (invalid under the documented grammar)', 'compiles'
        pattern = BREAK_EXPECT.get(case.get('breaking') or last_special(case))
        # A graph-level diagnostic stands at the schema's attribute: there it meets the documented message alone.
        lines = case['text'].split('\n')
        graph_level = pattern and any(p == 'macro' and re.search(pattern, m) and name == 'Case.swift' and 0 < line <= len(lines)
                                      and lines[line - 1].lstrip().startswith('@StateMachine(') for p, m, name, line in variant.get('located', []))
        # The macro also reports some checks through the expansion, as an unavailable witness with its message.
        expansion_check = pattern and any(p == 'expansion' and re.search(pattern, m) for p, m, _, _ in variant.get('located', []))
        if pattern and not graph_level and not expansion_check and not refusal_matches(pattern, case, variant):
            return 'fail', f'rejected with the documented diagnostic at the changed site: {pattern}', describe(variant)
        return 'pass', 'rejected', describe(variant)
    if 'diag' in kinds:
        # Valid Swift the guide calls unsupported: the macro itself must say so, where the case changed it.
        if variant['status'] == 'macro-diagnostic' and refusal_matches(r'.', case, variant):
            return 'pass', 'a macro diagnostic', describe(variant)
        return 'fail', 'a macro diagnostic at the changed site (Swift accepts it; the guide calls it unsupported)', describe(variant)
    if 'safe' in kinds:
        # Valid Swift the guide neither supports nor rules out: compile, or refuse with a macro diagnostic.
        if variant['status'] == 'ok' or (variant['status'] == 'macro-diagnostic' and refusal_matches(r'.', case, variant)):
            return 'pass', 'compiles or a macro diagnostic', describe(variant)
        if variant['status'] == 'expansion-error':
            entry = limit_for(case, 'expansion-error', ' | '.join(m for p, m in variant['errors'] if p == 'expansion'), role)
            if entry:
                return f'limit:{entry}', 'compiles, a macro diagnostic, or a documented check', describe(variant)
        if variant['status'] == 'authored-error':
            return 'artefact', 'compiles or a macro diagnostic', describe(variant)
        return 'fail', 'compiles or a macro diagnostic at the changed site, never invalid generated code', describe(variant)
    if case.get('verb') and variant['status'] == 'ok' and control and control['status'] == 'ok':
        # A name a generated method shares with an owner's own member must not take that member's place.
        verb = case['verb']
        lost = [l for l in control.get('fingerprint', []) if re.search(r'\.' + verb + r'\b', l) and l not in variant.get('fingerprint', [])]
        if lost:
            return 'fail', f"the owner's own `{verb}` members survive an edge of that name, or a macro diagnostic", f'compiles without: {lost[0][:300]}'
        return 'pass', 'compiles beside the owner members of that name', 'compiles'
    if 'dist' in kinds:
        nonnfc = any(unicodedata.normalize('NFC', v) != v for v in case.get('mapping', {}).values())
        reference = control
        if reference is not None and reference['status'] in ('authored-error', 'client-error'):
            # The renaming broke the control's own code: a fuzzer artefact, as for an equivalence.
            return 'artefact', 'a control that compiles and runs', f"control: {describe(reference)}"
        if reference is None or reference['status'] != 'ok':
            return 'fail', 'a control that compiles and runs', f"control: {describe(reference) if reference else 'none'}"
        if variant['status'] == 'macro-diagnostic':
            entry = limit_for(case, 'macro-diagnostic', '', role, variant)
            if entry and (nonnfc or entry not in ('nfc-refusal',)):
                return f'limit:{entry}', 'as the seed with the declaration renamed, or the NFC refusal', describe(variant)
        same, why = same_outcome(reference, variant, case.get('mapping', {}), case.get('behaviour', True), case.get('run_mapping'), order_free(case), case.get('added', ()), case['text'],
                                 case.get('graphs_only', False))
        if same:
            if nonnfc and case.get('inside', True) and variant['status'] == 'ok':
                return 'policy', 'the NFC refusal for a name not in NFC', 'compiles as the renamed seed does'
            return 'pass', 'as the renamed seed', describe(variant)
        if variant['status'] == 'authored-error' and reference['status'] == 'ok':
            return 'artefact', 'as the renamed seed', describe(variant)
        return 'fail', f"as the renamed seed ({describe(reference)})", f'{describe(variant)}; {why}'
    if 'valid' in kinds:
        if variant['status'] == 'ok' and case.get('signature'):
            # A rewrite that makes two failures distinct: the router's prepared method throws PreparationRejection.
            if not any(re.search(case['signature'], line) for line in variant.get('fingerprint', [])):
                found = [l for l in variant.get('fingerprint', []) if 'Observed.' in l and 'throws' in l]
                return 'fail', f"compiles with a signature matching {case['signature']}", f"compiles with {found[:2]}"
            return 'pass', 'compiles with two failures', 'compiles'
        if variant['status'] == 'ok':
            return 'pass', 'compiles', 'compiles'
        if variant['status'] == 'macro-diagnostic':
            entry = limit_for(case, 'macro-diagnostic', '', role, variant)
            if entry:
                return f'limit:{entry}', 'compiles or a documented limit', describe(variant)
        if variant['status'] == 'authored-error':
            return 'artefact', 'compiles', describe(variant)
        return 'fail', 'compiles (Swift accepts the authored functions)', describe(variant)
    # Equivalence.
    if variant['status'] == 'macro-diagnostic':
        entry = limit_for(case, 'macro-diagnostic', '', role, variant)
        if entry:
            return f'limit:{entry}', 'as the seed, or a documented limit', describe(variant)
        return 'fail', 'as the seed (Swift reads the same program)', describe(variant)
    if variant['status'] == 'authored-error':
        return 'artefact', 'as the seed', describe(variant)
    if variant['status'] in ('expansion-error', 'client-error'):
        place = 'expansion' if variant['status'] == 'expansion-error' else 'client'
        message = ' | '.join(m for p, m in variant['errors'] if p == place)
        entry = limit_for(case, variant['status'], message, role)
        if entry:
            return f'limit:{entry}', 'as the seed, or a documented limit', describe(variant)
    if variant['status'] != 'ok':
        return 'fail', 'as the seed (Swift reads the same program)', describe(variant)
    reference = control if control is not None else base
    same, why = same_outcome(reference, variant, case.get('mapping', {}), case.get('behaviour', True), case.get('run_mapping'), order_free(case), case.get('added', ()), case['text'])
    if same:
        return 'pass', 'as the seed', 'same signatures, graph, and output'
    entry = limit_for(case, 'interface', why, role)
    if entry:
        return f'limit:{entry}', 'as the seed, or a documented limit', why
    return 'fail', 'as the seed: same generated signatures, graph, and output', why


def run_difference(a, b):
    for left, right in zip(a, b):
        if left == right:
            continue
        if left.startswith('graph: ') and right.startswith('graph: '):
            paths = []
            def walk(x, y, path):
                if len(paths) >= 3:
                    return
                if isinstance(x, dict) and isinstance(y, dict):
                    for key in sorted(set(x) | set(y)):
                        walk(x.get(key), y.get(key), f'{path}.{key}')
                elif isinstance(x, list) and isinstance(y, list) and len(x) == len(y):
                    for index, (p, q) in enumerate(zip(x, y)):
                        walk(p, q, f'{path}[{index}]')
                elif x != y:
                    paths.append(f'{path}: {json.dumps(x, ensure_ascii=False)[:120]} vs {json.dumps(y, ensure_ascii=False)[:120]}')
            walk(json.loads(left[7:]), json.loads(right[7:]), 'graph')
            return '; '.join(paths)
        return f'{left[:200]!r} vs {right[:200]!r}'
    return f'{len(a)} lines vs {len(b)} lines'


def same_outcome(reference, variant, mapping, behaviour, run_mapping=None, order_free=(), added=(), text=None, graphs_only=False):
    """Whether two outcomes agree, with the control's names mapped onto the variant's (`run_mapping`, when given,
    for the printed output, whose graph names a nested schema by its own name). Under a reordering of members, the
    reference's initializer labels are put in the variant's declaration order, so labels compare in order."""
    run_mapping = mapping if run_mapping is None else run_mapping
    if reference['status'] != variant['status']:
        return False, f"status {reference['status']} vs {variant['status']}"
    if reference['status'] != 'ok':
        a = sorted(set(apply_mapping([m for p, m in reference['errors'] if p != 'authored'], mapping)))
        b = sorted(set(m for p, m in variant['errors'] if p != 'authored'))
        return a == b, 'diagnostics differ: ' + ' | '.join(sorted(set(a) ^ set(b)))[:400]
    a = {line for line in apply_mapping(reference.get('fingerprint', []), mapping) if not any(re.search(pattern, line) for pattern in added)}
    b = {line for line in variant.get('fingerprint', []) if not any(re.search(pattern, line) for pattern in added)}
    if 'members' in order_free and text is not None:
        a = {reorder_labels(line, text) for line in a}
    if a != b:
        removed = sorted(a - b)[:4]
        added = sorted(b - a)[:4]
        return False, 'signatures differ: -' + ' -'.join(removed) + ' +' + ' +'.join(added)
    keys = set().union(*[DECLARATION_ORDERED[k] for k in order_free]) if order_free else set()
    ra = run_lines(apply_mapping(reference.get('run', []), run_mapping), keys)
    rb = run_lines(variant.get('run', []), keys)
    if graphs_only and ra != rb:
        # A renamed phase reaches the report through the owner (edge IDs, phase names), but a report may also print
        # the old name as text of its own: either reading of each report line will do.
        plain = run_lines([apply_mapping([line], run_mapping)[0] if line.startswith('graph: ') else line
                           for line in reference.get('run', [])], keys)
        ra = [b if b in (m, q) else m for m, q, b in zip(ra, plain, rb)] if len(ra) == len(rb) else ra
    if behaviour and ra != rb:
        return False, 'run output differs: ' + run_difference(ra, rb)
    return True, ''


# ---------------------------------------------------------------------------------------------------------------------
# Cost: scaled schemas, each spelled a base way and rewritten ways Swift reads alike. The rewritten form must reach the
# same outcome as the base at the same size (a budget diagnostic for only one of them fails), and the macro's own time,
# the processor time the plugin spends between the compiler's request and its response, must stay within a constant
# factor of the base's. The base itself must grow at most near-linearly from the smaller size to the larger.
#
# Processor time, read with `proc_pid_rusage`, does not grow when other work loads the machine, as the wall time
# between request and response does: on a loaded machine, one of three repeats of the same expansion took 0.85 s of
# wall time and the other two 3.49 s and 2.00 s. Where that call is unavailable, the proxy falls back to wall time.

PROXY = """#!/usr/bin/env python3
import ctypes, os, struct, subprocess, sys, time
child = subprocess.Popen([%r], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
log = open(%r, 'a')
class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16), ('user', ctypes.c_uint64), ('system', ctypes.c_uint64),
                ('rest', ctypes.c_uint64 * 8)]
class Timebase(ctypes.Structure):
    _fields_ = [('numer', ctypes.c_uint32), ('denom', ctypes.c_uint32)]
try:
    libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
    timebase = Timebase()
    ctypes.CDLL('/usr/lib/libSystem.dylib').mach_timebase_info(ctypes.byref(timebase))
    scale = timebase.numer / timebase.denom / 1e9
except OSError:
    libproc = None
def processor():
    # The plugin's user and system time in seconds (RUSAGE_INFO_V0 counts Mach time units), or None.
    usage = Usage()
    if libproc is None or libproc.proc_pid_rusage(child.pid, 0, ctypes.byref(usage)) != 0:
        return None
    return (usage.user + usage.system) * scale
def read(stream):
    header = stream.read(8)
    if len(header) < 8:
        return None
    size = struct.unpack('<Q', header)[0]
    return header + stream.read(size)
while True:
    request = read(sys.stdin.buffer)
    if request is None:
        break
    started, used = time.monotonic(), processor()
    child.stdin.write(request); child.stdin.flush()
    response = read(child.stdout)
    if response is None:
        break
    if b'expand' in request[8:200]:
        now = processor()
        seconds = now - used if now is not None and used is not None else time.monotonic() - started
        log.write('%%.6f\\n' %% seconds); log.flush()
    sys.stdout.buffer.write(response); sys.stdout.buffer.flush()
"""


def cost_family_discard(n, spelling):
    params = ', '.join(f'T{i}' for i in range(n))
    uses = ', '.join(f'Namespace.X<Namespace.C{i}>' for i in range(n))
    cases = '\n'.join(f'        struct C{i} {{}}' for i in range(n))
    base = {'plain': 'Namespace', 'alias': 'N1', 'alias-paren': 'N1', 'self': 'Self.Namespace', 'schema': 'Flow.Namespace',
            'backtick': '`Namespace`', 'paren': '(Namespace)'}[spelling]
    alias = {'alias': 'typealias N1 = Namespace', 'alias-paren': 'typealias N1 = (Namespace)'}.get(spelling, '')
    return f"""import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Flow: Sendable {{
    enum Namespace {{
        typealias Discard<T> = Swift::Int
        typealias Ignore<{params}> = Swift::Int
        typealias W<{params}> = Ignore<{', '.join(f'[T{i}]' for i in range(n))}>
        typealias X<U> = W<{', '.join('U' for _ in range(n))}>
{cases}
    }}
    {alias}
    typealias Payload = {base}.Discard<({uses})>
    struct Idle: Sendable {{}}
    struct Running: Sendable {{}}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable {{ case go }}
    @Operation(activeIn: [Running.self])
    enum Load {{ typealias Output = Payload }}
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running, _ value: Load.Output) -> Idle {{ Idle() }}
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> {{ Change(Running(), effects: [.load]) }}
}}
"""


def cost_family_routed(n, spelling):
    failure = {'plain': 'Problem', 'paren': '(Problem)', 'self': 'Self.Problem', 'alias': 'Trouble', 'backtick': '`Problem`'}[spelling]
    inputs = ', '.join(f'go{i}' for i in range(n))
    members = []
    for i in range(n):
        members.append(f"""    @Route(on: Input.go{i})
    fileprivate static func pick{i}(_ source: Idle) throws({failure}) -> Route.Pick{i} {{ .stay{i} }}
    @Transition(on: Input.go{i})
    fileprivate static func stay{i}(_ source: Idle) throws({failure}) -> Idle {{ source }}
    @Transition(on: Input.go{i})
    fileprivate static func keep{i}(_ source: Idle) throws({failure}) -> Idle {{ source }}""")
    return f"""import StateMachine

@StateMachine(mode: .shared, owners: [.owned])
nonisolated enum Flow: Sendable {{
    enum Problem: Error, Sendable {{ case bad }}
    typealias Trouble = Problem
    struct Idle: Sendable {{}}
    @Initial case idle(Idle)
    enum Input: Sendable {{ case {inputs} }}
""" + '\n'.join(members) + '\n}\n'


def cost_family_events(n, spelling):
    payload = {'plain': 'Item', 'paren': '(Item)', 'alias': 'Thing', 'module': 'Fz.Item'}[spelling]
    events = '\n'.join(f'    @Event\n    enum Note{i} {{ typealias Payload = {payload} }}' for i in range(n))
    emits = ', '.join(f'Note{i}.self' for i in range(n))
    return f"""import StateMachine

struct Item: Sendable {{}}
typealias Thing = Item

@StateMachine(mode: .shared, owners: [.owned])
nonisolated enum Flow: Sendable {{
    struct Idle: Sendable {{}}
    @Initial case idle(Idle)
    enum Input: Sendable {{ case go }}
{events}
    @Transition(on: Input.go, emits: [{emits}])
    fileprivate static func go(_ source: Idle) -> Change<Idle, Effect.Go> {{ Change(source, effects: []) }}
}}
"""


def cost_family_composition(n, spelling):
    protocols = '\n'.join(f'    protocol P{i} {{}}' for i in range(n))
    count = 300
    aliases = '\n'.join(f'    typealias A{i} = All' for i in range(count))
    members = ' & '.join((f'A{i}' if spelling == 'aliases' else 'All') for i in range(count))
    return f"""import StateMachine

@StateMachine(mode: .shared, owners: [.owned])
nonisolated enum Flow: Sendable {{
{protocols}
    typealias All = {' & '.join(f'P{i}' for i in range(n))}
{aliases}
    struct Problem<T>: Error, Sendable {{}}
    struct Idle: Sendable {{}}
    struct Done: Sendable {{}}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input: Sendable {{ case go }}
    @Transition(on: Input.go)
    fileprivate static func left(_ source: Idle) throws(Problem<any {members}>) -> Done {{ Done() }}
    @Transition(on: Input.go)
    fileprivate static func right(_ source: Idle) throws(Problem<any All>) -> Done {{ Done() }}
    @Route(on: Input.go)
    fileprivate static func pick(_ source: Idle) throws(Problem<any All>) -> Route.Pick {{ .left }}
}}
"""


def cost_family_long_name(n, spelling):
    name = 'Long' + ('x' * 200_000 if spelling == 'long' else '')
    bindings = '\n'.join(f'        struct C{i} {{}}' for i in range(n))
    uses = ', '.join(f'Space.X<Space.C{i}>' for i in range(n))
    return f"""import StateMachine

@StateMachine(mode: .shared, owners: [.owned])
nonisolated enum Flow: Sendable {{
    enum Space {{
        struct {name} {{}}
        typealias X<T> = (T, {name})
{bindings}
    }}
    struct Idle: Sendable {{}}
    struct Running: Sendable {{}}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable {{ case go }}
    @Operation(activeIn: [Running.self])
    enum Load {{ typealias Output = ({uses}) }}
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running, _ value: Load.Output) -> Idle {{ Idle() }}
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> {{ Change(Running(), effects: [.load]) }}
}}
"""


def cost_family_operations(n, spelling):
    output = {'plain': 'Int', 'alias': 'Count', 'paren': '(Int)'}[spelling]
    operations = '\n'.join(f'    @Operation(activeIn: [Idle.self])\n    enum Op{i} {{ typealias Output = {output} }}' for i in range(n))
    completions = '\n'.join(f'    @Transition(onSuccess: Op{i}.self)\n    fileprivate static func done{i}(_ source: Idle, _ value: Op{i}.Output) -> Idle {{ source }}' for i in range(n))
    starts = ', '.join(f'Op{i}.self' for i in range(n))
    return f"""import StateMachine

@StateMachine(mode: .shared, owners: [.local])
nonisolated enum Flow: Sendable {{
    typealias Count = Int
    struct Idle: Sendable {{}}
    @Initial case idle(Idle)
    enum Input: Sendable {{ case go }}
{operations}
    @Transition(on: Input.go, starts: [{starts}])
    fileprivate static func go(_ source: Idle) -> Change<Idle, Effect.Go> {{ Change(source, effects: []) }}
{completions}
}}
"""


def cost_family_path_chain(n, spelling):
    """Aliases reached along a path, `Ai = A(i-1).Next`, past the key budget; an unrelated event that mentions all but the
    last must not change what the router's candidates are read to throw."""
    aliases = '\n'.join(f'    typealias A{i} = A{i - 1}.Next' for i in range(1, n + 1))
    event = ''
    if spelling.startswith('seeded'):
        last = n + 1 if spelling == 'seeded-all' else n
        # An operation the graph starts and completes, whose input mentions the aliases, read before the routes.
        event = ('    @Operation(activeIn: [Idle.self])\n    enum Seed { typealias Input = (' + ', '.join(f'A{i}' for i in range(last)) + ') }\n'
                 '    @Transition(on: Input.seed, starts: [Seed.self])\n'
                 '    fileprivate static func seed(_ source: Idle, _ value: Seed.Input) -> Change<Idle, Effect.Seed> { Change(source, effects: [.seed(value)]) }\n'
                 '    @Transition(onSuccess: Seed.self)\n    fileprivate static func seeded(_ source: Idle) -> Idle { source }')
    return f"""import StateMachine

struct Ext: Sendable {{ typealias Next = Ext }}

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated enum Flow: Sendable {{
    struct Problem<T>: Error, Sendable {{}}
    typealias A0 = Ext
{aliases}
{event}
    struct Idle: Sendable {{}}
    struct Done: Sendable {{}}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input: Sendable {{ case go{', seed(Seed.Input)' if spelling.startswith('seeded') else ''} }}
    @Transition(on: Input.go)
    fileprivate static func left(_ source: Idle) throws(Problem<A{n}>) -> Done {{ Done() }}
    @Transition(on: Input.go)
    fileprivate static func right(_ source: Idle) throws(Problem<A{n - 1}.Next>) -> Done {{ Done() }}
    @Route(on: Input.go)
    fileprivate static func pick(_ source: Idle) throws(Problem<A{n}>) -> Route.Pick {{ .left }}
}}
"""


def cost_family_long_namespace(n, spelling):
    """A composition of N members of one namespace, read through an alias, whose name is short or 200,000 bytes."""
    name = 'Space' + ('x' * 200_000 if spelling == 'long' else '')
    protocols = '\n'.join(f'        protocol P{i} {{}}' for i in range(n))
    members = ' & '.join(f'NS.P{i}' for i in range(n))
    return f"""import StateMachine

@StateMachine(mode: .shared, owners: [.owned])
nonisolated enum Flow: Sendable {{
    enum {name} {{
{protocols}
    }}
    typealias NS = {name}
    struct Problem<T>: Error, Sendable {{}}
    struct Idle: Sendable {{}}
    struct Done: Sendable {{}}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    enum Input: Sendable {{ case go }}
    @Transition(on: Input.go)
    fileprivate static func left(_ source: Idle) throws(Problem<any {members}>) -> Done {{ Done() }}
    @Transition(on: Input.go)
    fileprivate static func right(_ source: Idle) throws(Problem<any {members}>) -> Done {{ Done() }}
    @Route(on: Input.go)
    fileprivate static func pick(_ source: Idle) throws(Problem<any {members}>) -> Route.Pick {{ .left }}
}}
"""


COST_COMPARE = {'path-chain': r'\bpick\b'}


COST_FAMILIES = {
    'discard': (cost_family_discard, 'plain', ['alias', 'alias-paren', 'self', 'schema', 'backtick', 'paren'], [100, 300]),
    'routed': (cost_family_routed, 'plain', ['paren', 'self', 'alias', 'backtick'], [100, 400]),
    'events': (cost_family_events, 'plain', ['paren', 'alias', 'module'], [150, 600]),
    'composition': (cost_family_composition, 'all', ['aliases'], [100, 500]),
    'long-name': (cost_family_long_name, 'short', ['long'], [250, 1000]),
    'operations': (cost_family_operations, 'plain', ['alias', 'paren'], [16, 64]),
    'path-chain': (cost_family_path_chain, 'plain', ['seeded', 'seeded-all'], [1024, 1100]),
    'long-namespace': (cost_family_long_namespace, 'short', ['long'], [100, 400]),
}


def run_cost(toolchain, output, jobs, factor, slack, only=''):
    proxies = output / 'proxies'
    proxies.mkdir(parents=True, exist_ok=True)

    def measure(name, text):
        directory = output / 'cost' / name
        directory.mkdir(parents=True, exist_ok=True)
        timing = directory / 'macro-seconds.txt'
        proxy = proxies / f'{name}.py'
        proxy.write_text(PROXY % (str(toolchain.plugin), str(timing)))
        proxy.chmod(0o755)
        timed = Toolchain.__new__(Toolchain)
        timed.__dict__.update(toolchain.__dict__)
        timed.plugin, timed.run = proxy, False
        outcome = compile_case(timed, directory, text)
        outcome['macro_seconds'] = round(sum(float(x) for x in timing.read_text().split()) if timing.exists() else 0.0, 3)
        return outcome

    families = {k: v for k, v in COST_FAMILIES.items() if re.search(only, k)}
    jobs_list = []
    for family, (generate, base, variants, sizes) in families.items():
        for size in sizes:
            for spelling in [base] + variants:
                jobs_list.append((family, size, spelling, generate(size, spelling)))
    outcomes = {}
    with concurrent.futures.ThreadPoolExecutor(max(1, jobs)) as pool:
        futures = {(f, n, sp): pool.submit(measure, f'{f}-{n}-{sp}', text) for f, n, sp, text in jobs_list}
        for key, future in futures.items():
            outcomes[key] = future.result()
    results = []
    for family, (generate, base, variants, sizes) in families.items():
        for size in sizes:
            reference = outcomes[(family, size, base)]
            for spelling in variants:
                variant = outcomes[(family, size, spelling)]
                verdict, observed = 'pass', ''
                if reference['status'] not in ('ok', 'macro-diagnostic'):
                    verdict, observed = 'fail', f'the base itself does not compile: {describe(reference)}'
                elif variant['status'] in ('crash', 'timeout', 'memory'):
                    verdict, observed = 'fail', describe(variant)
                elif reference['status'] != variant['status'] or (reference['status'] != 'ok' and
                        sorted(m for p, m in reference['errors'] if p == 'macro') != sorted(m for p, m in variant['errors'] if p == 'macro')):
                    verdict, observed = 'fail', f'base {describe(reference)}; rewritten {describe(variant)}'
                elif family in COST_COMPARE and reference['status'] == 'ok' and (
                        [l for l in reference['fingerprint'] if re.search(COST_COMPARE[family], l)] !=
                        [l for l in variant['fingerprint'] if re.search(COST_COMPARE[family], l)]):
                    picked = [l for l in variant['fingerprint'] if re.search(COST_COMPARE[family], l)]
                    verdict, observed = 'fail', 'generated signatures differ: ' + ' / '.join(picked)[:300]
                elif variant['macro_seconds'] > factor * reference['macro_seconds'] + slack:
                    verdict, observed = 'fail', f"macro {variant['macro_seconds']}s vs base {reference['macro_seconds']}s"
                results.append(dict(id=f'cost-{family}-{size}-{spelling}', family=family, size=size, rewrite=spelling, verdict=verdict,
                                    base=describe(reference), base_seconds=reference['macro_seconds'],
                                    seconds=variant['macro_seconds'], observed=observed or describe(variant)))
        small, large = sizes[0], sizes[-1]
        for spelling in [base] + variants:
            a, b = outcomes[(family, small, spelling)], outcomes[(family, large, spelling)]
            ratio = (large / small)
            limit = ratio * ratio / 2 if ratio > 2 else ratio * 4
            grew = b['macro_seconds'] / max(a['macro_seconds'], 0.02)
            verdict = 'fail' if b['macro_seconds'] > slack and grew > limit else 'pass'
            results.append(dict(id=f'growth-{family}-{spelling}', family=family, size=large, rewrite=spelling, verdict=verdict,
                                base=f'{small}: {a["macro_seconds"]}s', base_seconds=a['macro_seconds'], seconds=b['macro_seconds'],
                                observed=f'{large}: {b["macro_seconds"]}s, {grew:.1f}x for {ratio:.0f}x the size'))
    return results


# ---------------------------------------------------------------------------------------------------------------------
# Scaling: every list-like construct of the grammar at sizes n and 4n. The expansion must still compile, and the macro's
# own time, the median of several runs, may grow at most `--growth-bound` times. `--ceilings` searches each construct's
# largest size that compiles within a time cap.

def _schema(body, mode='.shared', owners='[.owned, .local]', head=''):
    return f"""import StateMachine
{head}
@StateMachine(mode: {mode}, owners: {owners})
nonisolated enum Flow: Sendable {{
{body}
}}
"""


def construct_phases(n):
    phases = '\n'.join(f'    struct P{i}: Sendable {{}}' for i in range(n))
    cases = '\n'.join(f'    {"@Initial " if i == 0 else ""}{"@Terminal " if i == n - 1 else ""}case p{i}(P{i})' for i in range(n))
    edges = '\n'.join(f'    @Transition(on: Input.next)\n    fileprivate static func step{i}(_ source: P{i}) -> P{i + 1} {{ P{i + 1}() }}' for i in range(n - 1))
    return _schema(f'{phases}\n{cases}\n    enum Input: Sendable {{ case next }}\n{edges}')


def construct_destinations(n):
    phases = '\n'.join(f'    struct D{i}: Sendable {{}}' for i in range(n))
    cases = '\n'.join(f'    @Terminal case d{i}(D{i})' for i in range(n))
    inputs = ', '.join(f'go{i}' for i in range(n))
    edges = '\n'.join(f'    @Transition(on: Input.go{i})\n    fileprivate static func go{i}(_ source: Idle) -> D{i} {{ D{i}() }}' for i in range(n))
    return _schema(f'    struct Idle: Sendable {{}}\n{phases}\n    @Initial case idle(Idle)\n{cases}\n    enum Input: Sendable {{ case {inputs} }}\n{edges}')


def construct_inputs(n):
    inputs = ', '.join(f'set{i}(Int)' for i in range(n))
    edges = '\n'.join(f'    @Transition(on: Input.set{i})\n    fileprivate static func set{i}(_ source: Idle, _ value: Int) -> Idle {{ source }}' for i in range(n))
    return _schema(f'    struct Idle: Sendable {{}}\n    @Initial case idle(Idle)\n    enum Input: Sendable {{ case {inputs} }}\n{edges}')


def construct_operations(n):
    return cost_family_operations(n, 'plain')


def construct_events(n):
    events = '\n'.join(f'    @Event\n    enum Note{i} {{ typealias Payload = Int }}' for i in range(n))
    emits = ', '.join(f'Note{i}.self' for i in range(n))
    return _schema(f'    struct Idle: Sendable {{}}\n    @Initial case idle(Idle)\n    enum Input: Sendable {{ case go }}\n{events}\n'
                   f'    @Transition(on: Input.go, emits: [{emits}])\n    fileprivate static func go(_ source: Idle) -> Change<Idle, Effect.Go> {{ Change(source, effects: []) }}')


def construct_scopes(n):
    scopes = '\n'.join(f'        case s{i}' for i in range(n))
    requires = ', '.join(f'Scope.s{i}' for i in range(1, n))
    return _schema(f"""    struct Idle: Sendable {{}}
    @Initial case idle(Idle)
    enum Scope {{
{scopes}
    }}
    enum Input: Sendable {{ case go, reset }}
    @Operation(scope: Scope.s0{', requires: [' + requires + ']' if requires else ''})
    enum Work {{ typealias Output = Int }}
    @Transition(on: Input.go, starts: [Work.self])
    fileprivate static func go(_ source: Idle) -> Change<Idle, Effect.Go> {{ Change(source, effects: [.work]) }}
    @Transition(on: Input.reset, invalidates: [{', '.join(f'Scope.s{i}' for i in range(n))}])
    fileprivate static func reset(_ source: Idle) -> Idle {{ source }}
    @Transition(onSuccess: Work.self)
    fileprivate static func done(_ source: Idle, _ value: Work.Output) -> Idle {{ source }}""")


def construct_routers(n):
    return cost_family_routed(n, 'plain')


def construct_candidates(n):
    edges = '\n'.join(f'    @Transition(on: Input.go)\n    fileprivate static func c{i}(_ source: Idle) -> Idle {{ source }}' for i in range(n))
    return _schema(f'    struct Idle: Sendable {{}}\n    @Initial case idle(Idle)\n    enum Input: Sendable {{ case go }}\n{edges}\n'
                   f'    @Route(on: Input.go)\n    fileprivate static func pick(_ source: Idle) -> Route.Pick {{ .c0 }}')


def construct_alias_chain(n):
    aliases = '\n'.join(f'    typealias A{i} = {"Swift::Int" if i == 0 else f"A{i - 1}"}' for i in range(n))
    return _operation_schema(aliases, f'A{n - 1}')


def _operation_schema(declarations, output):
    return _schema(f"""{declarations}
    struct Idle: Sendable {{}}
    struct Running: Sendable {{}}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable {{ case go }}
    @Operation(activeIn: [Running.self])
    enum Load {{ typealias Output = {output} }}
    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> {{ Change(Running(), effects: [.load]) }}
    @Transition(onSuccess: Load.self)
    fileprivate static func done(_ source: Running, _ value: Load.Output) -> Idle {{ Idle() }}""")


def construct_composition(n):
    protocols = '\n'.join(f'    protocol P{i} {{}}' for i in range(n))
    members = ' & '.join(f'P{i}' for i in range(n))
    return _schema(f"""{protocols}
    struct Problem<T>: Error, Sendable {{}}
    struct Idle: Sendable {{}}
    @Initial case idle(Idle)
    enum Input: Sendable {{ case go }}
    @Transition(on: Input.go)
    fileprivate static func left(_ source: Idle) throws(Problem<any {members}>) -> Idle {{ source }}
    @Transition(on: Input.go)
    fileprivate static func right(_ source: Idle) throws(Problem<any {members}>) -> Idle {{ source }}
    @Route(on: Input.go)
    fileprivate static func pick(_ source: Idle) throws(Problem<any {members}>) -> Route.Pick {{ .left }}""")


def construct_generic_arguments(n):
    parameters = ', '.join(f'T{i}' for i in range(n))
    return _operation_schema(f'    typealias W<{parameters}> = Swift::Int', 'W<' + ', '.join('Swift::Int' for _ in range(n)) + '>')


def construct_tuple(n):
    return _operation_schema('', '(' + ', '.join('Swift::Int' for _ in range(n)) + ')')


def construct_nesting(n):
    return _operation_schema('    enum Unread { typealias Output = Swift::Int }', '[' * n + 'Swift::Int' + ']' * n)


def control_nesting(n):
    # The same tokens with the two types swapped: the nested array is spelled where nothing reads it.
    return _operation_schema('    enum Unread { typealias Output = ' + '[' * n + 'Swift::Int' + ']' * n + ' }', 'Swift::Int')


def construct_namespaces(n):
    opening = ''.join(f'enum N{i} {{ ' for i in range(n))
    closing = '}' * n
    return _operation_schema(f'    {opening}typealias X = Swift::Int {closing}', '.'.join(f'N{i}' for i in range(n)) + '.X')


# Base sizes n: 4n stays below every construct's compile ceiling (`--ceilings`), and large enough that the macro's time
# at 4n is well above timing noise.
CONSTRUCTS = {
    'phases': (construct_phases, 128), 'destinations': (construct_destinations, 128), 'inputs': (construct_inputs, 128),
    'operations': (construct_operations, 64), 'events': (construct_events, 128), 'scopes': (construct_scopes, 128),
    'routers': (construct_routers, 64), 'candidates': (construct_candidates, 128), 'alias-chain': (construct_alias_chain, 1024),
    'composition': (construct_composition, 256), 'generic-arguments': (construct_generic_arguments, 256),
    'tuple': (construct_tuple, 256), 'nesting': (construct_nesting, 4), 'namespaces': (construct_namespaces, 16),
}

# The proxy times the plugin process, which first parses the declaration the compiler sends. SwiftParser's lookahead
# for an inline array type (`[N of T]`) tries each `[` both ways, so that parse doubles with each level of nested
# array sugar, and a debug SwiftSyntax built from source parses tens of times slower than the prebuilt one: at depth 16
# the parse alone took 6 s of a from-source debug plugin's time. A construct listed here is measured against its
# control, the same tokens with the construct spelled where the macro never reads it, so the time judged is what the
# macro spends reading the construct, and the parse both pay alike drops out.
CONTROLS = {'nesting': control_nesting}


def _typecheck_timed(toolchain, directory, source, tag):
    """Type-checks `source` once through a fresh timing proxy; returns the watched result and the macro's own time."""
    timing = directory / f'macro-seconds-{tag}.txt'
    proxy = directory / f'proxy-{tag}.py'
    proxy.write_text(PROXY % (str(toolchain.plugin), str(timing)))
    proxy.chmod(0o755)
    timed = Toolchain.__new__(Toolchain)
    timed.__dict__.update(toolchain.__dict__)
    timed.plugin = proxy
    command = timed.command(source, directory / 'Case.o', link=False)
    command[command.index('-c')] = '-typecheck'
    del command[command.index('-o'):command.index('-o') + 2]
    command.remove('-dump-macro-expansions')
    command.remove('-Xfrontend')
    result = watched(command, toolchain.timeout)
    return result, (sum(float(x) for x in timing.read_text().split()) if timing.exists() else 0.0)


def _outcome(result, text, started):
    log, code = result.stdout, (result.returncode if result.verdict == 'ok' else result.verdict)
    errors = classify(log, schema_lines(text))
    status = ('memory' if code == 'memory' else 'timeout' if code == 'timeout' else 'launch' if code == 'launch' else
              'crash' if CRASH.search(log) or (isinstance(code, int) and code < 0) else 'ok' if code == 0 else
              'macro-diagnostic' if any(p == 'macro' for p, _ in errors) else 'expansion-error' if any(p == 'expansion' for p, _ in errors) else 'error')
    outcome = dict(status=status, errors=errors, seconds=round(time.monotonic() - started, 2), peak_mb=result.peak_mb)
    if status in ('memory', 'timeout'):
        outcome['crash'] = f'{"over memory cap" if status == "memory" else "timeout"} ({result.peak_mb} MB, {result.seconds}s)'
    return outcome


def measure_macro(toolchain, directory, text, repeats, control=None):
    """Type-checks `text` through a timing proxy `repeats` times; returns the outcome of the first run and the median
    of the macro's own time over all of them. With `control`, each attempt type-checks the control right after
    `text`, so a change in machine load meets both alike, and the time kept is the median of the differences;
    `control_seconds` and `total_seconds` keep the medians of the two."""
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / 'Case.swift'
    source.write_text(text)
    if control is not None:
        (directory / 'Control.swift').write_text(control)
    times, controls, differences, first, repeats_seen = [], [], [], None, []
    for attempt in range(repeats):
        started = time.monotonic()
        result, seconds = _typecheck_timed(toolchain, directory, source, attempt)
        outcome = _outcome(result, text, started)
        repeats_seen.append(outcome['status'])
        if first is None or (first['status'] == 'ok' and outcome['status'] != 'ok'):
            # Every repeat's outcome counts: a later crash or cap replaces an earlier success.
            first = dict(outcome, failing_repeat=attempt) if first is not None else outcome
            (directory / f'compile-{attempt}.log').write_text(result.stdout[-20000:])
        times.append(seconds)
        if outcome['status'] in RESOURCE_FAILURES:
            break
        if control is not None:
            started = time.monotonic()
            result, seconds = _typecheck_timed(toolchain, directory, directory / 'Control.swift', f'control-{attempt}')
            outcome = _outcome(result, control, started)
            repeats_seen.append(f"control {outcome['status']}")
            if outcome['status'] != 'ok':
                (directory / 'control.log').write_text(result.stdout[-20000:])
                first = dict(outcome, status=outcome['status'], control_failed=True)
                break
            controls.append(seconds)
            differences.append(times[-1] - seconds)
    first['repeats'] = repeats_seen

    def median(values):
        return round(sorted(values)[len(values) // 2], 3) if values else 0.0

    if control is not None and differences:
        first['total_seconds'], first['control_seconds'] = median(times), median(controls)
        first['macro_seconds'] = max(0.0, median(differences))
    else:
        first['macro_seconds'] = median(times)
    return first


def run_scaling(toolchain, output, jobs, bound, repeats, only=''):
    constructs = {k: v for k, v in CONSTRUCTS.items() if re.search(only, k)}
    work = [(name, size) for name, (generate, n) in constructs.items() for size in (n, 4 * n)]
    with concurrent.futures.ThreadPoolExecutor(max(1, jobs)) as pool:
        futures = {key: pool.submit(measure_macro, toolchain, output / 'scaling' / f'{key[0]}-{key[1]}',
                                    constructs[key[0]][0](key[1]), repeats,
                                    CONTROLS[key[0]](key[1]) if key[0] in CONTROLS else None) for key in work}
        outcomes = {key: future.result() for key, future in futures.items()}
    results = []
    for name, (generate, n) in constructs.items():
        small, large = outcomes[(name, n)], outcomes[(name, 4 * n)]
        grew = large['macro_seconds'] / max(small['macro_seconds'], 0.01)
        verdict, observed = 'pass', f"{n}: {small['macro_seconds']}s, {4 * n}: {large['macro_seconds']}s ({grew:.1f}x)"
        if name in CONTROLS:
            observed += (f"; plugin time with the declaration's parse, {n}: {small.get('total_seconds')}s, "
                         f"{4 * n}: {large.get('total_seconds')}s")
        for size, outcome in ((n, small), (4 * n, large)):
            if outcome['status'] != 'ok':
                what = 'its control' if outcome.get('control_failed') else ''
                verdict, observed = 'fail', (f'{size}{" " + what if what else ""} does not compile: {describe(outcome)} '
                                             f"(repeats: {', '.join(outcome.get('repeats', []))})")
                break
        else:
            if large['macro_seconds'] > 0.2 and grew > bound:
                verdict = 'fail'
        results.append(dict(id=f'scaling-{name}', construct=name, verdict=verdict, observed=observed,
                            small=small['macro_seconds'], large=large['macro_seconds']))
    return results


# The plugin parses each declaration again with SwiftParser, which stops nesting at its own maximum; the compiler and
# the prebuilt SwiftSyntax stop at 256 levels, but a debug SwiftSyntax built from source, which SwiftPM builds once a
# declared test target depends on SwiftSyntax, stops at 20 (`Parser.defaultMaximumNestingLevel`). Such a plugin reads
# a schema nested deeper cut short, losing the members past that depth, so `namespaces` at 64 gets "Mark exactly one
# phase case with @Initial.", and it parses tens of times slower than the time bounds here assume.
PARSER_PROBE_DEPTH = 24


def plugin_parser_problem(toolchain, output):
    """Why the plugin cannot take the scaling and ceiling checks, or None."""
    outcome = measure_macro(toolchain, output / 'parser-probe', construct_namespaces(PARSER_PROBE_DEPTH), 1)
    if outcome['status'] == 'ok':
        return None
    return (f'the plugin cannot read a schema nested {PARSER_PROBE_DEPTH + 1} levels deep, which the compiler parses '
            f'({describe(outcome)}): its SwiftParser stops nesting early, as a debug SwiftSyntax built from source does '
            'at 20 levels. Use a plugin linked against the prebuilt SwiftSyntax, which a native build uses while no '
            'declared test target depends on SwiftSyntax.')


# The guide's size limits, each checked in the heaviest owner set: every owner the shared mode generates.
SIZE_LIMITS = {'phases': (construct_phases, 600), 'inputs': (construct_inputs, 512),
               'operations': (construct_operations, 256), 'effect cases': (construct_events, 512)}


def all_owners(text):
    return re.sub(r'@StateMachine\(mode: \.shared, owners: \[[^\]]*\]\)', '@StateMachine(mode: .shared)', text)


def run_size_limits(toolchain, output, cap):
    """At each documented limit the expansion compiles within the time and memory caps; one past it, the macro
    refuses it with the size-limit diagnostic. One compilation at a time."""
    bounded = Toolchain.__new__(Toolchain)
    bounded.__dict__.update(toolchain.__dict__)
    bounded.timeout = cap
    pattern = next(e['pattern'] for e in LIMITS if e['id'] == 'size-limit')
    rows, results = [], []
    for name, (generate, limit) in SIZE_LIMITS.items():
        at = measure_macro(bounded, output / 'limits' / f'{name}-{limit}', all_owners(generate(limit)), 1)
        over = measure_macro(bounded, output / 'limits' / f'{name}-{limit + 1}', all_owners(generate(limit + 1)), 1)
        messages = [m for p, m in over['errors'] if p == 'macro']
        under_ok = at['status'] == 'ok'
        over_ok = over['status'] == 'macro-diagnostic' and any(re.search(pattern, m) for m in messages)
        verdict = 'pass' if under_ok and over_ok else 'fail'
        rows.append(f"| {name} | {limit} | {describe(at)} ({at['seconds']}s, {at.get('peak_mb', '-')} MB) | "
                    f"{describe(over)[:160]} | {verdict} |")
        results.append(dict(id=f'size-limit-{name}', verdict=verdict,
                            observed=f'{limit}: {describe(at)}; {limit + 1}: {describe(over)[:200]}'))
    lines = ['| Construct | Documented limit | At the limit (all owners) | One past it | Verdict |', '|---|---|---|---|---|'] + rows
    (output / 'size-limits.md').write_text('\n'.join(lines) + '\n')
    return results


def run_ceilings(toolchain, output, jobs, cap, limit, only=''):
    """For each construct, sizes 8, 16, 32, ... up to `limit`, one compilation at a time, stopping at the first that does
    not compile within the time and memory caps; reports the largest size that compiled ("at least" when the search
    reached `limit`) and what stopped the next one."""
    found = []
    output.mkdir(parents=True, exist_ok=True)
    pattern = next(e['pattern'] for e in LIMITS if e['id'] == 'size-limit')
    for name in [k for k in CONSTRUCTS if re.search(only, k)]:
        generate, _ = CONSTRUCTS[name]
        bounded = Toolchain.__new__(Toolchain)
        bounded.__dict__.update(toolchain.__dict__)
        bounded.timeout = cap
        good, failing, reason, at, size, kind = None, None, None, {}, 8, None
        while size <= min(limit, CEILING_LIMITS.get(name, limit)):
            outcome = measure_macro(bounded, output / 'ceilings' / f'{name}-{size}', generate(size), 1)
            at[size] = outcome
            if outcome['status'] != 'ok':
                failing, reason = size, describe(outcome)
                messages = [m for p, m in outcome.get('errors', []) if p == 'macro']
                # A documented refusal stops a search as the guide says it should; running out of time or memory, or
                # crashing, is a failure of its own, whatever size it happens at.
                if outcome['status'] in RESOURCE_FAILURES:
                    kind = 'resource'
                elif outcome['status'] == 'macro-diagnostic' and messages and all(re.search(pattern, m) for m in messages):
                    kind = 'refusal'
                else:
                    kind = 'error'
                break
            good, size = size, size * 2
        verdict = 'fail' if kind == 'resource' or (kind == 'error' and failing <= CEILING_FLOOR) else 'pass'
        found.append(dict(construct=name, ceiling=good, failing=failing, stopped=reason, kind=kind, verdict=verdict,
                          timings=at, limit=min(limit, CEILING_LIMITS.get(name, limit))))
    lines = ['| Construct | Compiles up to | First failing size | Macro time / peak memory at the largest | What stops it | Verdict |',
             '|---|---|---|---|---|---|']
    for row in found:
        largest = row['timings'].get(row['ceiling'], {})
        reach = (f"at least {row['ceiling']}" if row['failing'] is None else f"{row['ceiling'] or '< 8'}")
        stopped = {'resource': 'resource failure: ', 'refusal': 'documented refusal: ', 'error': 'error: '}.get(row['kind'], '')
        lines.append(f"| {row['construct']} | {reach} | {row['failing'] or '-'} | {largest.get('macro_seconds', '-')}s / "
                     f"{largest.get('peak_mb', '-')} MB | {stopped}{(row['stopped'] or 'nothing up to the search limit')[:200]} | {row['verdict']} |")
    (output / 'ceilings.md').write_text('\n'.join(lines) + '\n')
    return found


# Sizes at or below which any failure to compile fails a ceiling search; above it, Swift's own limits (its check of a
# generated switch, its parser's nesting limit) may stop a construct the guide sets no limit for.
CEILING_FLOOR = 256
# Search limits of constructs past which Swift itself, not the macro, takes unbounded time: plain Swift type-checks a
# 24-deep nested array type in about 9 s, and its parser refuses 256 levels of nesting.
CEILING_LIMITS = {'nesting': 16, 'namespaces': 128}


# ---------------------------------------------------------------------------------------------------------------------
# Self-test: each oracle against a planted defect it must report, beside a clean control it must pass. A check of the
# fuzzer that no planted defect trips is not trusted.

SELF_TEST_SCHEMA = '''import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local, .mainActorHost])
nonisolated enum Plant: Sendable {
    typealias Detail = Swift::String
    struct Idle: Sendable {}
    struct Busy: Sendable {}
    @Initial case idle(Idle)
    @Terminal case busy(Busy)
    enum Input: Sendable { case go(Detail), stop }
    @Event
    enum Logged {
        struct Detail: Sendable {}
        typealias Payload = Detail
    }
    @Event
    enum Closing {}
    @Transition(on: Input.go, emits: [Logged.self, Closing.self])
    fileprivate static func go(_ source: Idle, _ value: Swift::Int) -> Change<Busy, Effect.Go> {
        Change(Busy(), effects: [.logged(Logged.Detail()), .closing])
    }
    @Transition(on: Input.stop)
    fileprivate static func stop(_ source: Idle) -> Busy { Busy() }
}
extension Plant.Input { typealias Detail = Swift::Int }

func fuzzReport() -> String { "planted" }
'''


def self_test_graph():
    return {'name': 'Plant', 'formatVersion': 2, 'mode': 'shared', 'owners': ['owned', 'local', 'mainActorHost'],
            'initial': 'idle', 'terminal': ['busy'], 'restorable': [],
            'phases': [{'id': 'idle', 'payload': 'Idle'}, {'id': 'busy', 'payload': 'Busy'}],
            'inputs': [{'id': 'go', 'payload': 'Detail'}, {'id': 'stop'}], 'scopes': [], 'operations': [],
            'events': [{'id': 'Logged', 'effect': 'logged', 'payload': 'Detail'}, {'id': 'Closing', 'effect': 'closing', 'payload': 'Void'}],
            'edges': [{'id': 'idle.go', 'name': 'go', 'source': 'idle', 'destination': 'busy', 'trigger': {'input': {'_0': 'go'}},
                       'starts': [], 'cancels': [], 'emits': ['Logged', 'Closing'], 'invalidates': []},
                      {'id': 'idle.stop', 'name': 'stop', 'source': 'idle', 'destination': 'busy', 'trigger': {'input': {'_0': 'stop'}},
                       'starts': [], 'cancels': [], 'emits': [], 'invalidates': []}],
            'routers': []}


def synthetic(graph=None, fingerprint=(), report='planted', **extra):
    graph = graph or self_test_graph()
    lines = normalize_run('graph: ' + json.dumps(graph, sort_keys=True) + f'\nreport: {report}')
    return dict(dict(status='ok', errors=[], located=[], fingerprint=list(fingerprint), run=lines, report=report,
                     spelling_problems=[], diagram_problems=[], label_problems=[], seconds=0.0), **extra)


def self_case(text, rewrites=('paren',), kinds=('eq',), **extra):
    SEED_TEXTS.setdefault('selftest', SELF_TEST_SCHEMA)
    return dict(dict(id='selftest', seed='selftest', rewrites=list(rewrites), kinds=list(kinds), text=text, role='value',
                     mapping={}, behaviour=True, added=[], steps=[]), **extra)


OLD_MERMAID = 'stateDiagram-v2\n    [*] --> {0}\n    {0} --> busy : go\n    {0} --> busy : stop\n    busy --> [*]\n'
NEW_MERMAID = ('stateDiagram-v2\n    state "{0}" as p0\n    state "busy" as p1\n    [*] --> p0\n    p0 --> p1 : go\n    p0 --> p1 : stop\n'
               '    p1 --> [*]\n')
DOT = ('digraph "Plant" {{\n    "*" [shape=point];\n    "{0}";\n    "busy" [peripheries=2];\n    "*" -> "{0}";\n'
       '    "{0}" -> "busy" [label="go"];\n    "{0}" -> "busy" [label="stop"];\n}}\n')
INIT = ('Fz.Plant.MainActorHost.init(_: Fz.Plant.Idle, {0}, configuration: StateMachine.Configuration) -> Fz.Plant.MainActorHost')


def self_tests(toolchain, output):
    """(name, oracle, planted verdict is a failure, control verdict passes, detail) for each check."""
    checks = []

    def check(name, oracle, planted, control):
        checks.append((name, oracle, planted, control))

    base_text = SELF_TEST_SCHEMA
    SEED_TEXTS['selftest'] = base_text
    case = self_case(base_text)
    base = synthetic()

    # (1) Triggers and spelled fields.
    swapped = self_test_graph()
    swapped['edges'][0]['trigger'] = {'input': {'_0': 'stop'}}
    failure = self_test_graph()
    failure['edges'][0]['trigger'] = {'failure': {'_0': 'go'}}
    respelled = self_test_graph()
    respelled['inputs'][0]['payload'] = 'Self.Detail'
    check('swapped trigger', 'graph comparison', judge(case, base, None, synthetic(swapped))[0],
          judge(case, base, None, synthetic(respelled))[0])
    check('input trigger read as failure', 'graph comparison', judge(case, base, None, synthetic(failure))[0],
          judge(case, base, None, synthetic())[0])
    keyed = self_test_graph()
    keyed['operations'] = [{'id': 'Load', 'effect': 'load', 'input': 'Void', 'output': 'Void', 'failure': 'Never', 'key': 'Int'}]
    unkeyed = json.loads(json.dumps(keyed))
    del unkeyed['operations'][0]['key']
    check('key dropped', 'graph comparison', judge(case, synthetic(keyed), None, synthetic(unkeyed))[0],
          judge(case, synthetic(keyed), None, synthetic(keyed))[0])

    # (2) Spelling probes, compiled.
    directory = output / 'self-test' / 'probes'
    directory.mkdir(parents=True, exist_ok=True)
    wrong_input = self_test_graph()
    wrong_input['inputs'][0]['payload'] = 'Swift::String'
    wrong_event = self_test_graph()
    wrong_event['events'][0]['payload'] = 'Plant.Detail'
    schema_scope = Toolchain.__new__(Toolchain)
    schema_scope.__dict__.update(toolchain.__dict__)
    schema_scope.spelling_scope = 'schema'
    clean = check_spellings(toolchain, directory, base_text, [self_test_graph()])
    check('wrong exported input spelling', 'spelling probe', 'fail' if check_spellings(toolchain, directory, base_text, [wrong_input]) else 'pass',
          'pass' if not clean else f'fail: {clean[:1]}')
    check('wrong exported event spelling', 'event-payload probe', 'fail' if check_spellings(toolchain, directory, base_text, [wrong_event]) else 'pass',
          'pass' if not clean else f'fail: {clean[:1]}')
    check('spelling read at another scope (shadowed payload shape)', 'probe scope', 'fail' if check_spellings(schema_scope, directory, base_text, [self_test_graph()]) else 'pass',
          'pass' if not clean else f'fail: {clean[:1]}')
    extra = self_test_graph()
    extra['phases'].append({'id': 'ghost', 'payload': 'Idle'})
    check('graph record without a probe', 'probe count', 'fail' if spelling_probes(base_text, [extra])[2] else 'pass',
          'pass' if not spelling_probes(base_text, [self_test_graph()])[2] else 'fail')
    labels = [dict(site='Plant phase idle payload', exported='Idle')]
    check('probe symbols missing on both sides', 'both symbols required', 'fail' if compare_probe_types(labels, {}) else 'pass',
          'pass' if not compare_probe_types(labels, {(0, 'e'): 'Fz.Plant.Idle.Type', (0, 'a'): 'Fz.Plant.Idle.Type'}) else 'fail')

    # (3) Baselines.
    check('seed with a spelling problem', 'seed baseline', 'fail' if seed_problems('selftest', synthetic(spelling_problems=['Plant input go payload: wrong'])) else 'pass',
          'pass' if not seed_problems('selftest', base) else 'fail')
    check('seed that crashes the compiler', 'seed baseline', 'fail' if seed_problems('selftest', dict(status='crash', crash='Stack dump:', errors=[])) else 'pass',
          'pass' if not seed_problems('selftest', base) else 'fail')
    EXPECTED_REPORTS['selftest'] = 'planted'
    check('domain report changed', 'pinned report', 'fail' if seed_problems('selftest', synthetic(report='wrong edge')) else 'pass',
          'pass' if not seed_problems('selftest', base) else 'fail')
    del EXPECTED_REPORTS['selftest']
    noisy = synthetic(spelling_problems=['Plant input go payload: names String'])
    check('variant problem at a new site beside a seed problem', 'per-site comparison',
          judge(case, noisy, None, synthetic(spelling_problems=['Plant input go payload: names String', 'Plant phase idle payload: names Busy']))[0],
          judge(case, noisy, None, synthetic(spelling_problems=['Plant input go payload: names String']))[0])

    # (4) Refusals.
    attribute_line = base_text.split('\n').index('    fileprivate static func stop(_ source: Idle) -> Busy { Busy() }') + 1
    refused_text = base_text.replace('    fileprivate static func stop(', '    @MainActor fileprivate static func stop(')
    message = "Remove '@MainActor': generated code calls this function from nonisolated code and from every owner, so it takes only ..."
    refusal = lambda line, extra=(): dict(status='macro-diagnostic', errors=[('macro', message)] + [(p, m) for p, m, _, _ in extra],
                                          located=[('macro', message, 'Case.swift', line)] + list(extra))
    refused_case = self_case(refused_text, rewrites=['declaration-attributes'], kinds=['safe'], expect='custom-attribute')
    check('refusal away from the changed site', 'refusal site', judge(refused_case, base, None, refusal(3))[0],
          judge(refused_case, base, None, refusal(attribute_line))[0])
    check('exact refusal with another error', 'exact refusal', judge(refused_case, base, None, refusal(attribute_line, [('expansion', 'type mismatch', 'Case.swift', 4)]))[0],
          judge(refused_case, base, None, refusal(attribute_line, [('authored', "cannot find type 'Effect' in scope", 'Case.swift', 20)]))[0])
    phase_message = "Phase 'idle' needs a distinct nongeneric struct or enum declared directly inside the schema, named with a Swift identifier that needs no backticks; aliases are unsupported."
    aliased = base_text.replace('@Initial case idle(Idle)', '@Initial case idle(FuzzAlias)')
    alias_case = self_case(aliased, rewrites=['alias-local'], role='phase')
    phase_line = aliased.split('\n').index('    @Initial case idle(FuzzAlias)') + 1
    other = dict(status='macro-diagnostic', errors=[('macro', 'Some other refusal.')], located=[('macro', 'Some other refusal.', 'Case.swift', phase_line)])
    alias = dict(status='macro-diagnostic', errors=[('macro', phase_message)], located=[('macro', phase_message, 'Case.swift', phase_line)])
    check('phase alias refused for another reason', 'limit message', judge(alias_case, base, None, other)[0], judge(alias_case, base, None, alias)[0])
    broken = self_case(base_text.replace('@Terminal case busy', 'case busy'), rewrites=['terminal-flip'], kinds=['break'])
    busy_line = base_text.split('\n').index('    @Terminal case busy(Busy)') + 1
    unexit = "Phase 'busy' has no outgoing transitions; mark it '@Terminal' or declare a transition from it."
    check('breaking rewrite rejected only by the linker', 'rejection', judge(broken, base, None, dict(status='link-error', errors=[('link', 'undefined symbol')], located=[]))[0],
          judge(broken, base, None, dict(status='macro-diagnostic', errors=[('macro', unexit)], located=[('macro', unexit, 'Case.swift', busy_line)]))[0])
    check('breaking rewrite rejected with another diagnostic', 'documented rejection',
          judge(broken, base, None, dict(status='macro-diagnostic', errors=[('macro', 'Unrelated.')], located=[('macro', 'Unrelated.', 'Case.swift', busy_line)]))[0],
          judge(broken, base, None, dict(status='macro-diagnostic', errors=[('macro', unexit)], located=[('macro', unexit, 'Case.swift', busy_line)]))[0])
    composed = self_case(refused_text, rewrites=['paren', 'declaration-attributes'], kinds=['eq', 'safe'], expect='custom-attribute')
    check('composed case whose other rewrites fail alone', 'composed control',
          judge(composed, base, None, refusal(attribute_line), ('fail', 'as the seed', 'signatures differ'))[0],
          judge(composed, base, None, refusal(attribute_line), ('pass', 'as the seed', 'same'))[0])

    # (5) Execution.
    directory = output / 'self-test' / 'runs'
    crashed = compile_case(toolchain, directory / 'trap', base_text.replace('"planted"', 'fatalError("planted")'))
    exited = compile_case(toolchain, directory / 'exit', base_text.replace('func fuzzReport() -> String { "planted" }',
                                                                         'import Foundation\nfunc fuzzReport() -> String { exit(3) }'))
    ran = compile_case(toolchain, directory / 'clean', base_text)
    check('program traps', 'run outcome', judge(case, ran, None, crashed)[0], judge(case, ran, None, ran)[0])
    check('program exits non-zero', 'run outcome', judge(case, ran, None, exited)[0], judge(case, ran, None, ran)[0])
    check('two equally failing runs', 'run outcome', judge(case, crashed, None, crashed)[0], judge(case, ran, None, ran)[0])
    unlaunchable = Toolchain.__new__(Toolchain)
    unlaunchable.__dict__.update(toolchain.__dict__)
    unlaunchable.swiftc = str(output / 'no-such-swiftc')
    check('compiler cannot launch', 'launch outcome', judge(case, ran, None, compile_case(unlaunchable, directory / 'launch', base_text))[0],
          judge(case, ran, None, ran)[0])
    renamed = self_case(base_text, rewrites=['collide-case'], kinds=['dist'])
    check('renaming whose control fails', 'distinction control', judge(renamed, ran, crashed, ran)[0], judge(renamed, ran, ran, ran)[0])

    # (6) Client module and labels.
    stub = '''import StateMachine

// @Event
enum Logged {}
// @Event
enum Closing {}
@MainActor final class Host { init(_ x: Int, ARGUMENTS) {} }

func fuzzReport() -> String { "stub" }
// fuzz-client
@testable import Fz

@MainActor func fuzzClient() -> Host { Host(1, /*fuzz-args*/onLogged: { (_: String) in }, onClosing: { }/*end-args*/) }
'''
    wrong = compile_case(toolchain, directory / 'client-wrong', stub.replace('ARGUMENTS', 'onClosing: @escaping () -> Void, onLogged: @escaping (String) -> Void'))
    right = compile_case(toolchain, directory / 'client-right', stub.replace('ARGUMENTS', 'onLogged: @escaping (String) -> Void, onClosing: @escaping () -> Void'))
    check('generated initializer in the wrong label order', 'client module', judge(case, right, None, wrong)[0], judge(case, right, None, right)[0])
    wrong_init = INIT.format('onClosing: () -> (), onLogged: (Fz.Plant.Logged.Detail) -> ()')
    right_init = INIT.format('onLogged: (Fz.Plant.Logged.Detail) -> (), onClosing: () -> ()')
    check('labels in the wrong order in every case', 'declaration-order labels', 'fail' if label_order_problems([wrong_init], base_text) else 'pass',
          'pass' if not label_order_problems([right_init], base_text) else 'fail')
    swapped_text = base_text.replace('''    @Event
    enum Logged {
        struct Detail: Sendable {}
        typealias Payload = Detail
    }
    @Event
    enum Closing {}''', '''    @Event
    enum Closing {}
    @Event
    enum Logged {
        struct Detail: Sendable {}
        typealias Payload = Detail
    }''')
    reordered = self_case(swapped_text, rewrites=['reorder-members'])
    check('reordered events, labels kept in the old order', 'ordered label comparison',
          judge(reordered, synthetic(fingerprint=[right_init]), None, synthetic(fingerprint=[right_init]))[0],
          judge(reordered, synthetic(fingerprint=[right_init]), None, synthetic(fingerprint=[wrong_init]))[0])

    # (7) Diagrams.
    graph = self_test_graph()
    noted = json.loads(json.dumps(graph).replace('"idle"', '"note"').replace('idle.', 'note.'))
    check('Mermaid state named note', 'Mermaid reader', 'fail' if check_diagrams(noted, OLD_MERMAID.format('note'), DOT.format('note')) else 'pass',
          'pass' if not check_diagrams(noted, NEW_MERMAID.format('note'), DOT.format('note')) else 'fail')
    check('Mermaid describing another graph', 'Mermaid structure', 'fail' if check_diagrams(graph, NEW_MERMAID.format('idle').replace('p0 --> p1 : stop', 'p1 --> p0 : stop'), DOT.format('idle')) else 'pass',
          'pass' if not check_diagrams(graph, OLD_MERMAID.format('idle'), DOT.format('idle')) else 'fail')
    check('DOT name with an unescaped quote', 'DOT reader', 'fail' if check_diagrams(graph, NEW_MERMAID.format('idle'), DOT.replace('"Plant"', '"Pl"ant"').format('idle')) else 'pass',
          'pass' if not check_diagrams(graph, NEW_MERMAID.format('idle'), DOT.format('idle')) else 'fail')
    check('DOT edge missing', 'DOT structure', 'fail' if check_diagrams(graph, NEW_MERMAID.format('idle'), DOT.format('idle').replace('    "idle" -> "busy" [label="stop"];\n', '')) else 'pass',
          'pass' if not check_diagrams(graph, NEW_MERMAID.format('idle'), DOT.format('idle')) else 'fail')

    # (8) Resources.
    real = globals()['_typecheck_timed']
    sequence = []

    def fake(toolchain_, directory_, source, tag):
        sequence.append(tag)
        if len(sequence) == 2:
            return Watched('Stack dump:\n', -11, 'ok', 10, 1.0), 0.5
        return Watched('', 0, 'ok', 10, 1.0), 0.5
    globals()['_typecheck_timed'] = fake
    try:
        repeated = measure_macro(toolchain, output / 'self-test' / 'scaling', 'import StateMachine\n', 3)
        sequence.clear()
        sequence.extend(['x', 'y', 'z', 'w'])
        steady = measure_macro(toolchain, output / 'self-test' / 'scaling-ok', 'import StateMachine\n', 3)
    finally:
        globals()['_typecheck_timed'] = real
    check('crash in a later scaling repeat', 'scaling repeats', 'fail' if repeated['status'] != 'ok' else 'pass', 'pass' if steady['status'] == 'ok' else 'fail')
    real_measure = globals()['measure_macro']
    globals()['measure_macro'] = lambda *a, **k: dict(status='timeout', errors=[], crash='timeout (10 MB, 121s)', seconds=121, peak_mb=10, macro_seconds=0)
    try:
        timed_out = run_ceilings(toolchain, output / 'self-test' / 'ceilings-timeout', 1, 1, 1024, '^phases$')[0]
        refusal_text = 'This schema declares 700 phases; the macro accepts at most 600, because ...'
        globals()['measure_macro'] = lambda *a, **k: dict(status='macro-diagnostic', errors=[('macro', refusal_text)], seconds=1, peak_mb=10, macro_seconds=0)
        refused = run_ceilings(toolchain, output / 'self-test' / 'ceilings-refusal', 1, 1, 1024, '^phases$')[0]
    finally:
        globals()['measure_macro'] = real_measure
    check('ceiling stopped by a timeout', 'ceiling verdict', timed_out['verdict'], refused['verdict'])
    return checks


def compare_probe_types(labels, types):
    """Problems of the probes' demangled types: a missing symbol on either side, or two different types."""
    problems = []
    for index, label in enumerate(labels):
        emitted, authored = types.get((index, 'e')), types.get((index, 'a'))
        if emitted is None or authored is None:
            problems.append(f"{label['site']}: probe symbol missing (exported {emitted}, authored {authored})")
        elif emitted != authored:
            problems.append(f"{label['site']}: {label['exported']!r} names {emitted}, the authored type is {authored}")
    return problems


def run_self_test(toolchain, output):
    (output / 'self-test').mkdir(parents=True, exist_ok=True)
    checks = self_tests(toolchain, output)
    rows, failed = [], 0
    for name, oracle, planted, control in checks:
        ok = planted == 'fail' and (control == 'pass' or control.startswith('limit:'))
        failed += not ok
        rows.append(f"| {name} | {oracle} | {planted} | {control} | {'ok' if ok else 'NOT TRUSTED'} |")
        print(f"{'PASS' if ok else 'FAIL'} self-test {name} ({oracle}): planted {planted}, control {control}", flush=True)
    table = ['| Planted defect | Oracle | Verdict on the defect | Verdict on its control | |', '|---|---|---|---|---|'] + rows
    (output / 'self-test.md').write_text('\n'.join(table) + '\n')
    print(f'{len(checks)} self-tests: {len(checks) - failed} trusted, {failed} not trusted')
    return 1 if failed else 0


# ---------------------------------------------------------------------------------------------------------------------
# Driving.

def case_id(seed, names, index):
    return f"{seed}--{'+'.join(names)}--{index}"


def spread(items, limit):
    if len(items) <= limit:
        return list(range(len(items)))
    step = (len(items) - 1) / (limit - 1)
    return sorted({round(i * step) for i in range(limit)})


def make_case(seed_name, names, choices, text, info, number):
    kinds = [REWRITE_BY_NAME[n].kind for n in names]
    # Client code may rely on what a breaking, unsupported, or unspecified form changes, so those compile alone.
    if any(k in ('break', 'diag', 'safe') for k in kinds):
        text = schema_only(text)
    control = info['control']
    if control is None and info['flags']:
        # A case compiled with other flags compares with its seed compiled with them.
        control = seeds_text_of(seed_name)
    return dict(id=case_id(seed_name, names, number), seed=seed_name, rewrites=list(names), kinds=kinds, text=text,
                steps=info['steps'], role=info['role'], control=control, mapping=info['mapping'],
                run_mapping=info['run_mapping'], behaviour=info['behaviour'], choices=list(choices),
                inside=info.get('inside', True), flags=info['flags'], added=info.get('added', []), verb=info.get('verb'),
                expect=info.get('expect'), breaking=info.get('breaking'), signature=info.get('signature'),
                graphs_only=info.get('graphs_only'))


SEED_TEXTS = {}


def seeds_text_of(name):
    return SEED_TEXTS[name]


def site_signature(rewrite, info):
    """What makes one site of a rewrite different from another for the macro: the kind and role of a type site and
    the shape of its spelling with names abstracted, or a non-type rewrite's flavour."""
    site = info.get('site', '')
    shape = re.sub(r"'[^']*'|`[^`]*`|\b[A-Za-z_]\w*\b", lambda m: m.group(0) if m.group(0) in KEYWORDS or m.group(0) in STANDARD
                   or m.group(0) in GENERATED_NAMES or m.group(0) in OWNER_VERBS or m.group(0) in SHADOWED else 'N', site)
    return (rewrite.name, info.get('role', 'value'), shape)


# Seeds and the rewrites whose every site `--smoke` keeps: the seeds written for a kind of defect, each with the
# families written for it. Every other site is left out once two earlier seeds covered its signature.
SMOKE_EVERY_SITE = {
    # These seeds keep every site of every family except the ones listed here, which reach them through the signature
    # rule like any other seed.
    **{f'own-{name}': r'^(?!(integer-spelling|helper-basename|alias-to-extension|binding-shadow|reserved-phase|edge-availability|'
                      r'lowercase-attribute|conditional-attribute|existential-metatype|composition-flatten|inline-array|'
                      r'owner-selection|metatype-split|redirect-entrance|router-delete|router-duplicate|operation-drop|'
                      r'scope-ineligible|cancel-unkeyed|owner-invalid|restoration-invalid|schema-access|declaration-attributes|'
                      r'phase-alias-other|conditional-compilation|async-function|generic-function|inout-source|untyped-throws|'
                      r'throws-any-error|terminal-flip|nest-generic)$)' for name in ('initial-factory', 'rejecting-routers', 'scoped-invalidation', 'composed-failure',
                                         'routed-closure', 'routed-closure-borrowing', 'owned-single', 'input-shadow',
                                         'keyed-completion-router', 'event-isolated')},
    'own-access-pair': r'^(helper-basename|schema-access|nest-schema)$',
    'own-value-generic-failure': r'^(integer-spelling|inline-array)$',
    'own-event-shadow': r'^(alias-to-extension|binding-shadow|reorder-members)$',
    'own-cross-file-input': r'^(alias-to-extension|binding-shadow)$',
    'fx-GMT-input-case-extension': r'^(alias-to-extension|binding-shadow)$',
    'own-lowercase-actor': r'^(lowercase-attribute|conditional-attribute)$',
    'own-function-attributes': r'^(function-attribute-order|module-selector)$',
    'own-metatype-failure': r'^(existential-metatype|metatype-split|composition-flatten)$',
    'own-parallel-32': r'^integer-spelling$',
    'own-parallel-33': r'^integer-spelling$',
    'own-keyed-scoped-restoration': r'^(shadow-alias|restoration-invalid|scope-ineligible|operation-drop|cancel-unkeyed|integer-spelling)$',
    'own-report-local': r'^(reorder-members|reorder-cases|verb-edge-name|collide-case|reserved-phase|operation-drop)$',
    'own-available-schema': r'^(edge-availability|declaration-attributes)$',
    'own-isolated-default': r'^(owner-selection|owner-invalid)$',
    'own-single-managed': r'^(owner-selection|owner-invalid)$',
    'own-managed-only': r'^(owner-selection|owner-invalid|reorder-members)$',
    'doc-Approval': r'^reserved-phase$',
}


def smoke_cases(seeds, rewrites, per_rewrite, full=False):
    """Every seed with every rewrite, at sites spread over each rewrite's candidates. Unless `full`, a site whose
    signature two earlier seeds already covered is left out, except where SMOKE_EVERY_SITE keeps every site of a
    seed's rewrite; seeds written for this fuzzer come first."""
    cases = []
    covered = collections.Counter()
    order = sorted(seeds, key=lambda name: (not name.startswith('own-'), not name.startswith('fx-'), name))
    for seed_name in order:
        text = seeds[seed_name]
        for rw in rewrites:
            try:
                mutations = rw.function(text, random.Random(f'{seed_name}/{rw.name}'))
            except Exception as error:  # A rewrite that cannot read a seed is a fuzzer defect worth seeing.
                print(f'rewrite {rw.name} failed on {seed_name}: {error!r}', file=sys.stderr)
                continue
            every = re.search(SMOKE_EVERY_SITE.get(seed_name, r'$^'), rw.name) is not None
            # A rewrite that is not an equivalence differs from site to site in kind, so it gets more of them.
            for index in spread(mutations, per_rewrite * 3 if rw.kind != 'eq' else per_rewrite):
                signature = site_signature(rw, mutations[index][1])
                if not full and not every and covered[signature] >= 2:
                    continue
                covered[signature] += 1
                choices = [(index + 0.5) / len(mutations)]
                composed = compose(seed_name, text, [rw.name], choices)
                if composed:
                    cases.append(make_case(seed_name, [rw.name], choices, composed[0], composed[1], index))
    return cases


def schema_only(text):
    """The text without its top-level functions, so that only the macro or its expansion can reject a breaking rewrite."""
    out, skipping = [], False
    # An extension that adds functions is client code too.
    text = re.sub(r'^extension [^\n{]*\{\n(?:(?!^\}).*\n)*?\}\n',
                  lambda m: '' if 'func ' in m.group(0) and '@StateMachine(' not in m.group(0) else m.group(0), text, flags=re.M)
    for line in text.split('\n'):
        if out and re.match(r'(@MainActor\s+)?(nonisolated\s+)?func\s', line) and re.match(r'@(available|MainActor)\b', out[-1]):
            # The attribute line of a removed function goes with it.
            out.pop()
        if (re.match(r'(@MainActor\s+)?(nonisolated\s+)?func\s', line) or line.strip() == '@MainActor') and 'fuzzLocalSchema' not in line:
            skipping = not line.rstrip().endswith('}') and line.strip() != '@MainActor'
            continue
        if skipping:
            if line.startswith('}'):
                skipping = False
            continue
        out.append(line)
    return '\n'.join(out)


def compose(seed_name, text, names, choices):
    """Applies the named rewrites in turn, each at the site its fraction in `choices` selects; None if one does not
    apply. Fractions rather than indices keep a site choice stable when reduction drops an earlier rewrite."""
    info_all = dict(steps=[], mapping={}, run_mapping=None, control=None, role='value', behaviour=True, inside=True, flags=[])
    current = text
    for name, fraction in zip(names, choices):
        try:
            mutations = REWRITE_BY_NAME[name].function(current, random.Random(f'{seed_name}/{name}'))
        except Exception as error:  # A rewrite that cannot read an earlier rewrite's output is reported, not fatal.
            print(f'rewrite {name} failed on {seed_name} after {names}: {error!r}', file=sys.stderr)
            return None
        if not mutations:
            return None
        new, info = mutations[min(int(fraction * len(mutations)), len(mutations) - 1)]
        if info.get('control') is not None:
            info_all['inside'] = info.get('inside', True)
            info_all['control'] = info['control']
            info_all['behaviour'] = info.get('behaviour', True) and info_all['behaviour']
            # The control already holds every earlier rewrite, so only this step's renaming maps it onto the variant.
            info_all['mapping'], info_all['run_mapping'] = {}, None
        info_all['mapping'].update(info.get('mapping', {}))
        if info.get('run_mapping') is not None:
            info_all['run_mapping'] = dict(info_all['run_mapping'] or {}, **info['run_mapping'])
        if info.get('behaviour') is False:
            info_all['behaviour'] = False
        info_all['flags'] += [f for f in info.get('flags', []) if f not in info_all['flags']]
        info_all['added'] = info_all.get('added', []) + info.get('added', [])
        if info.get('verb'):
            info_all['verb'] = info['verb']
        if info.get('expect'):
            info_all['expect'] = info['expect']
        for key in ('breaking', 'signature', 'graphs_only'):
            if info.get(key):
                info_all[key] = info[key]
        # The strongest role a step gives decides which limits apply: a phase payload, then a result shape.
        rank = {'value': 0, 'attribute': 1, 'shape': 2, 'phase': 3}
        if rank.get(info.get('role'), 0) > rank.get(info_all['role'], 0):
            info_all['role'] = info['role']
        info_all['steps'].append(info.get('site', ''))
        current = new
    return current, info_all


def random_cases(seeds, count, seed_value):
    rng = random.Random(seed_value)
    eq = [r.name for r in REWRITES if r.kind == 'eq']
    special = [r.name for r in REWRITES if r.kind != 'eq']
    cases = []
    attempts = 0
    while len(cases) < count and attempts < count * 30:
        attempts += 1
        seed_name = rng.choice(sorted(seeds))
        names = [rng.choice(eq) for _ in range(rng.randint(2, 4))]
        # Any other kind comes last: a renaming or a breaking rewrite judges the text the equivalences leave.
        if rng.random() < 0.4:
            names[-1] = rng.choice(special)
        choices = [rng.random() for _ in names]
        composed = compose(seed_name, seeds[seed_name], names, choices)
        if composed is None:
            continue
        cases.append(make_case(seed_name, names, choices, composed[0], composed[1], len(cases)))
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--output', type=pathlib.Path, required=True, help='a fresh directory for cases and results')
    parser.add_argument('--configuration', choices=('debug', 'release'), default='debug')
    parser.add_argument('--scratch-path', type=pathlib.Path, help='the SwiftPM scratch path whose native build to use')
    parser.add_argument('--plugin', type=pathlib.Path, help='a macro plugin executable to use instead of the build')
    parser.add_argument('--modules', type=pathlib.Path, help='the directory of StateMachine.swiftmodule for --plugin')
    parser.add_argument('--library', type=pathlib.Path, help='a directory with libStateMachine.dylib to link instead of the build\'s objects')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--smoke', action='store_true', help='every rewrite alone, at sites of every shape the seeds hold; deterministic')
    mode.add_argument('--random', action='store_true', help='random compositions of two to four rewrites')
    mode.add_argument('--cost', action='store_true', help='scaled schemas: rewritten spellings against the base spelling')
    mode.add_argument('--scaling', action='store_true', help='every list-like construct at sizes n and 4n')
    mode.add_argument('--ceilings', action='store_true', help="search each construct's largest size that compiles")
    mode.add_argument('--self-test', action='store_true', help='plant a defect for each oracle and check that it is reported')
    parser.add_argument('--growth-bound', type=float, default=5.0, help='allowed growth of macro time for 4x the size')
    parser.add_argument('--repeats', type=int, default=3, help='runs per measurement; the median is kept')
    parser.add_argument('--ceiling-cap', type=int, default=120, help='seconds a ceiling attempt may take')
    parser.add_argument('--ceiling-limit', type=int, default=1024, help='largest size a ceiling search tries')
    parser.add_argument('--cost-factor', type=float, default=3.0, help='allowed macro time of a rewrite over its base')
    parser.add_argument('--cost-slack', type=float, default=0.5, help='seconds of macro time always allowed')
    parser.add_argument('--count', type=int, default=200)
    parser.add_argument('--seed', type=int, default=1)
    parser.add_argument('--per-rewrite', type=int, default=2, help='sites per seed and rewrite in --smoke')
    parser.add_argument('--full', action='store_true', help='with --smoke, every seed and site, without leaving out repeated site signatures')
    parser.add_argument('--only-seeds', default='', help='a regular expression selecting seeds (with --cost, families)')
    parser.add_argument('--only-rewrites', default='', help='a regular expression selecting rewrites')
    parser.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) // 2), help='compilations at once (default: half the cores)')
    parser.add_argument('--timeout', type=int, default=120, help='seconds a compilation may take before it is killed')
    parser.add_argument('--memory-cap-mb', type=int, default=3000,
                        help="megabytes a compilation's process tree may hold before it is killed as over the memory cap")
    parser.add_argument('--no-run', action='store_true', help='compile only; do not link and run cases')
    parser.add_argument('--no-reduce', action='store_true')
    parser.add_argument('--list', action='store_true', help='list seeds and rewrites and exit')
    parser.add_argument('--spelling-scope', choices=('written', 'schema'), default='written',
                        help="where an exported spelling is read: where the guide says it is meant (default), or, to check a "
                             "macro older than that contract, at the schema's scope")
    args = parser.parse_args()

    seeds = {k: v for k, v in all_seeds().items() if re.search(args.only_seeds, k)}
    rewrites = [r for r in REWRITES if re.search(args.only_rewrites, r.name)]
    if args.list:
        for name in seeds:
            print('seed', name)
        for r in REWRITES:
            print('rewrite', r.kind, r.name, '-', r.doc)
        return 0
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error(f'{output} is not empty; give a fresh --output')
    output.mkdir(parents=True, exist_ok=True)

    if args.plugin:
        if not args.modules:
            parser.error('--plugin needs --modules')
        plugin, modules = args.plugin.resolve(), args.modules.resolve()
        link = ([f'-L{args.library}', '-lStateMachine', '-Xlinker', '-rpath', '-Xlinker', str(args.library)] if args.library
                else [str(p) for p in sorted((modules.parent / 'objects').glob('*.o'))])
    else:
        command = ['swift', 'build', '--build-system', 'native', '--configuration', args.configuration, '--show-bin-path']
        if args.scratch_path:
            command += ['--scratch-path', str(args.scratch_path)]
        bin_path = pathlib.Path(subprocess.check_output(command, cwd=ROOT, text=True).strip())
        plugin, modules = bin_path / 'StateMachineMacros-tool', bin_path / 'Modules'
        if args.library:
            link = [f'-L{args.library}', '-lStateMachine', '-Xlinker', '-rpath', '-Xlinker', str(args.library)]
        else:
            link = [str(p) for p in sorted((bin_path / 'StateMachine.build').glob('*.o'))]
        if not plugin.exists() or not (modules / 'StateMachine.swiftmodule').exists():
            parser.error(f'no native build of the macro plugin at {bin_path}; build the package first')
    # Keep the plugin this run uses, so concurrent rebuilds cannot change it mid-run.
    kept = output / 'plugin'
    shutil.copy2(plugin, kept)
    global MEMORY_CAP_MB
    MEMORY_CAP_MB = args.memory_cap_mb
    toolchain = Toolchain(kept, modules, link, args.jobs, args.timeout, not args.no_run)
    toolchain.spelling_scope = args.spelling_scope
    if args.cost or args.scaling or args.ceilings:
        # Large schemas compile one at a time, so a compilation near the memory cap is the only one running.
        args.jobs = 1

    for entry in LIMITS:
        if entry['doc'] and ' '.join(entry['doc'].split()) not in ' '.join(DOC.read_text().split()):
            print(f"warning: limit {entry['id']} quotes text DeclaringAGraph.md no longer contains: {entry['doc']!r}", file=sys.stderr)
    (output / 'limits.json').write_text(json.dumps(LIMITS, indent=2, ensure_ascii=False) + '\n')

    started = time.monotonic()
    if args.self_test:
        return run_self_test(toolchain, output)
    if args.scaling or args.ceilings:
        problem = plugin_parser_problem(toolchain, output)
        if problem:
            print(f'error: {problem}', file=sys.stderr)
            return 2
        if args.scaling:
            results = run_scaling(toolchain, output, args.jobs, args.growth_bound, args.repeats, args.only_seeds)
            for r in results:
                print(f"{r['verdict'].upper():4} {r['id']}: {r['observed']}", flush=True)
        else:
            found = run_ceilings(toolchain, output, args.jobs, args.ceiling_cap, args.ceiling_limit, args.only_seeds)
            print((output / 'ceilings.md').read_text(), end='')
            results = [dict(id=f"ceiling-{r['construct']}", verdict=r['verdict'],
                            observed=f"{r['ceiling']} ({r['kind'] or 'search limit'}: {r['stopped'] or '-'})") for r in found]
            if not args.only_seeds:
                results += run_size_limits(toolchain, output, args.ceiling_cap)
                print((output / 'size-limits.md').read_text(), end='')
        failed = [r for r in results if r['verdict'] == 'fail']
        (output / 'results.json').write_text(json.dumps(dict(summary=dict(mode='scaling' if args.scaling else 'ceilings',
            cases=len(results), failed=len(failed), seconds=round(time.monotonic() - started, 1)), results=results), indent=2) + '\n')
        print(f'{len(results)} checks in {time.monotonic() - started:.0f}s: {len(failed)} fail')
        return 1 if failed else 0
    if args.cost:
        results = run_cost(toolchain, output, args.jobs, args.cost_factor, args.cost_slack, args.only_seeds)
        failed = [r for r in results if r['verdict'] == 'fail']
        for r in results:
            print(f"{r['verdict'].upper():4} {r['id']}: base {r['base']} ({r['base_seconds']}s); {r['observed']}", flush=True)
        (output / 'results.json').write_text(json.dumps(dict(summary=dict(mode='cost', cases=len(results), failed=len(failed),
            seconds=round(time.monotonic() - started, 1)), results=results), indent=2) + '\n')
        print(f'{len(results)} cost checks in {time.monotonic() - started:.0f}s: {len(failed)} fail')
        return 1 if failed else 0
    # Seeds first. Every seed must pass on its own: it compiles, links, and runs to completion, prints the report it
    # pins, exports spellings that name its types, renders both diagrams as its graph, and takes initializer labels in
    # declaration order. A seed that fails is a failure; one that does not compile blocks its cases.
    bases = {}
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = {name: pool.submit(compile_case, toolchain, output / 'seeds' / name, text) for name, text in seeds.items()}
        for name, future in futures.items():
            bases[name] = future.result()
    SEED_TEXTS.update(seeds)
    results, blocked = [], {}
    for name, outcome in bases.items():
        problems = seed_problems(name, outcome)
        for number, problem in enumerate(problems):
            case = dict(id=f'{name}--seed--{number}', seed=name, rewrites=['seed'], kinds=['eq'], text=seeds[name],
                        steps=['the seed as written'], control=None)
            results.append((case, dict(id=case['id'], seed=name, rewrites=['seed'], kinds=['eq'], steps=case['steps'], verdict='fail',
                                       expected='the seed passes on its own', observed=problem, seconds=outcome['seconds'])))
            print(f'FAIL {case["id"]}: {problem}', flush=True)
        if outcome['status'] != 'ok':
            blocked[name] = describe(outcome)
    runnable = {k: v for k, v in seeds.items() if k not in blocked}

    cases = smoke_cases(runnable, rewrites, args.per_rewrite, args.full) if args.smoke else random_cases(runnable, args.count, args.seed)
    print(f'{len(seeds)} seeds ({len(blocked)} blocked), {len(rewrites)} rewrites, {len(cases)} cases, {args.jobs} jobs', flush=True)
    declarations = {name: declaration_signature(text) for name, text in seeds.items()}

    def probe_for(case):
        # Spellings are probed for a renaming, and for any case whose exported spellings or declarations differ from
        # its seed's: a moved or added declaration can change what an unchanged spelling names.
        if 'dist' in case['kinds']:
            return True
        seed_spellings = bases[case['seed']].get('spellings')
        return lambda spellings, text: spellings != seed_spellings or declaration_signature(text) != declarations[case['seed']]

    # Controls of distinction rewrites compile once each, before the cases that compare with them.
    def control_key(case):
        return hashlib.sha256((case['control'] + '\0' + ' '.join(case['flags'])).encode()).hexdigest()[:16]
    pending = {control_key(c): c for c in cases if c['control'] is not None}
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = {key: pool.submit(compile_case, toolchain, output / 'controls' / key, c['control'], True, c['flags'])
                   for key, c in pending.items()}
        controls = {key: future.result() for key, future in futures.items()}

    def control_outcome(case):
        return bases[case['seed']] if case['control'] is None else controls[control_key(case)]

    def prefix_verdict(case):
        """For a composed case whose last rewrite is not an equivalence: the verdict of its other rewrites alone."""
        if len(case['rewrites']) < 2 or case['kinds'][-1] == 'eq':
            return None
        names, choices = case['rewrites'][:-1], case['choices'][:-1]
        composed = compose(case['seed'], runnable[case['seed']], names, choices)
        if composed is None:
            return ('artefact', 'the other rewrites alone apply', 'they do not')
        prefix = make_case(case['seed'], names, choices, composed[0], composed[1], 0)
        key = hashlib.sha256((prefix['text'] + '\0' + ' '.join(prefix['flags'])).encode()).hexdigest()[:16]
        reused = next((o for k, o in controls.items() if pending[k]['control'] == prefix['text'] and pending[k]['flags'] == prefix['flags']), None)
        variant = reused or compile_case(toolchain, output / 'prefixes' / key, prefix['text'], probe_for(prefix), prefix['flags'])
        control = None
        if prefix['control'] is not None:
            control = compile_case(toolchain, output / 'prefixes' / f'{key}-control', prefix['control'], True, prefix['flags'])
        return judge(prefix, bases[case['seed']], control, variant)

    def run_case(case):
        directory = output / 'cases' / safe(case['id'])
        variant = compile_case(toolchain, directory, case['text'], probe_for(case), case['flags'])
        control = control_outcome(case)
        verdict, expected, observed = judge(case, bases[case['seed']], control, variant, prefix_verdict(case))
        result = dict(id=case['id'], seed=case['seed'], rewrites=case['rewrites'], kinds=case['kinds'], steps=case['steps'],
                      verdict=verdict, expected=expected, observed=observed, seconds=variant['seconds'])
        (directory / 'result.json').write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
        if verdict in ('pass',) or verdict.startswith('limit:'):
            shutil.rmtree(directory, ignore_errors=True)
        return case, result

    done = 0
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        for case, result in pool.map(run_case, cases):
            results.append((case, result))
            done += 1
            if result['verdict'] in ('fail', 'policy'):
                print(f"{result['verdict'].upper()} {result['id']}: expected {result['expected']}; observed {result['observed']}", flush=True)
            if done % 100 == 0:
                print(f'... {done}/{len(cases)} ({time.monotonic() - started:.0f}s)', flush=True)

    failures = [(c, r) for c, r in results if r['verdict'] == 'fail']
    if args.random and not args.no_reduce:
        failures = [reduce_case(toolchain, output, bases, runnable, c, r) if c['rewrites'] != ['seed'] else (c, r) for c, r in failures]
    write_failures(output, failures, [(c, r) for c, r in results if r['verdict'] == 'policy'])
    counts = {}
    for _, r in results:
        key = r['verdict'].split(':')[0]
        counts[key] = counts.get(key, 0) + 1
    summary = dict(mode='smoke' if args.smoke else 'random', seeds=len(seeds), blocked_seeds=blocked, rewrites=len(rewrites),
                   cases=len(results), counts=counts, seconds=round(time.monotonic() - started, 1), plugin=str(plugin),
                   spelling_scope=toolchain.spelling_scope)
    (output / 'results.json').write_text(json.dumps(dict(summary=summary, results=[r for _, r in results]), indent=2, ensure_ascii=False) + '\n')
    (output / 'anchors.txt').write_text(''.join(f'{n}\t{kind}\t{message}\n' for (kind, message), n in ANCHORS.most_common()))
    passed = counts.get('pass', 0) + counts.get('limit', 0) + counts.get('artefact', 0)
    print(f"{passed}/{len(results)} fuzz cases passed ({counts.get('limit', 0)} at documented limits, "
          f"{counts.get('artefact', 0)} fuzzer artefacts), {counts.get('fail', 0)} failed, {counts.get('policy', 0)} policy, "
          f"{len(blocked)} seeds blocked, in {summary['seconds']}s; evidence: {output}")
    return 1 if counts.get('fail') or counts.get('policy') or blocked else 0


def seed_problems(name, outcome):
    """Why a seed does not pass on its own, as `site: detail` problems."""
    if outcome['status'] != 'ok':
        return [f'the seed itself: {describe(outcome)}']
    problems = list(problems_of(outcome))
    expected = EXPECTED_REPORTS.get(name)
    if expected is not None and outcome.get('report') != expected:
        problems.append(f"report: {outcome.get('report')!r}, expected {expected!r}")
    return problems


def declaration_signature(text):
    """Every type and alias declaration with the declarations that enclose it, sorted: what a spelling can name."""
    mask = code_mask(text)
    stack, pending, found = [], None, []
    for match in re.finditer(r'\b(struct|enum|class|protocol|actor|extension|typealias)\s+(`[^`]+`|[^\s`<:={(]+)|[{}]', text):
        if not mask[match.start()]:
            continue
        token = match.group(0)
        if token == '{':
            stack.append(pending)
            pending = None
        elif token == '}':
            if stack:
                stack.pop()
        else:
            kind, name = match.group(1), match.group(2).strip('`')
            enclosing = tuple(s for s in stack if s)
            if kind != 'extension':
                found.append((enclosing, kind, name))
            if kind != 'typealias':
                pending = name if kind != 'extension' else f'extension {name}'
    return sorted(found)

def safe(identifier):
    return re.sub(r'[^\w.+-]', '_', identifier)[:150]


def reduce_case(toolchain, output, bases, seeds, case, result):
    """Drops rewrites one at a time while the case still fails."""
    names, choices = list(case['rewrites']), list(case['choices'])
    for index in range(len(names) - 1, -1, -1):
        if index >= len(names) or len(names) < 2:
            continue
        trial, trial_choices = names[:index] + names[index + 1:], choices[:index] + choices[index + 1:]
        composed = compose(case['seed'], seeds[case['seed']], trial, trial_choices)
        if composed is None:
            continue
        candidate = make_case(case['seed'], trial, trial_choices, composed[0], composed[1], 0)
        candidate['id'] = case['id']
        directory = output / 'reduce' / safe(case['id']) / str(index)
        variant = compile_case(toolchain, directory, candidate['text'], flags=candidate['flags'])
        control = (compile_case(toolchain, directory / 'control', candidate['control'], flags=candidate['flags'])
                   if candidate['control'] is not None else None)
        verdict, expected, observed = judge(candidate, bases[case['seed']], control, variant)
        if verdict == 'fail':
            names, choices = trial, trial_choices
            case, result = candidate, dict(result, rewrites=trial, steps=candidate['steps'], expected=expected,
                                           observed=observed, reduced=True)
    return case, result


def write_failures(output, failures, policies):
    directory = output / 'failures'
    directory.mkdir(exist_ok=True)
    lines = []
    for case, result in failures + policies:
        name = safe(result['id'])
        header = (f"// fuzz-macro {result['verdict']}: seed {result['seed']}; rewrites {' + '.join(result['rewrites'])} "
                  f"at {' / '.join(s.replace(chr(10), ' ') for s in result['steps'])}\n"
                  f"// expected: {result['expected']}\n// observed: {result['observed']}\n")
        (directory / f'{name}.swift').write_text(header + case['text'])
        if case.get('control') is not None:
            (directory / f'{name}.control.swift').write_text('// The control: the same schema with the renamed declaration spelled as the seed spells it.\n' + case['control'])
        lines.append(f"{result['verdict']}\t{name}.swift\t{' + '.join(result['rewrites'])}\texpected {result['expected']}\tobserved {result['observed']}")
    (directory / 'index.txt').write_text('\n'.join(lines) + ('\n' if lines else ''))
    # One line per distinct failure: the rewrite and the observation with its names abstracted.
    groups = {}
    for case, result in failures + policies:
        groups.setdefault(signature(result), []).append(result)
    with open(directory / 'groups.txt', 'w') as out:
        for key, members in sorted(groups.items(), key=lambda item: -len(item[1])):
            first = members[0]
            out.write(f"{len(members)}\t{first['verdict']}\t{safe(first['id'])}.swift\t{key}\n")


def signature(result):
    observed = re.sub(r"'[^']*'", "'\u2026'", result['observed'])
    observed = re.sub(r'\(\w+\)|\b\d+\b', '\u2026', observed)
    observed = re.sub(r'(signatures differ|run output differs|diagnostics differ):.*', r'\1', observed)
    return f"{' + '.join(sorted(set(result['rewrites'])))}: {observed[:200]}"


if __name__ == '__main__':
    sys.exit(main())
