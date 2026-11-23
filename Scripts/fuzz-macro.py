#!/usr/bin/env python3
"""Fuzz the @StateMachine macro with rewrites whose meaning Swift decides.

Each case applies rewrites to a valid seed schema and compiles it alone through the real macro plugin.

- An equivalence rewrite (parentheses, backticks, aliases, qualification, sugar, trivia, reordering, ...)
  must preserve the program's meaning. The case must compile, emit identical canonical signatures
  (demangled object symbols), export the same graph structure, and print the seed's output. A macro
  diagnostic or difference passes only when LIMITS lists it.
- A distinction rewrite renames one declaration so it collides with another in a normal form the macro
  might use (canonical Unicode equivalence, case, a raw identifier against a path, or a confusable
  letter). Swift reads two distinct names, so the case must behave like the seed with that declaration
  renamed. Because the guide requires the macro to refuse non-NFC schema names, such a name must emit
  that diagnostic, and accepting it fails as `policy`.
- A breaking rewrite makes the schema invalid under the documented grammar while keeping it valid Swift.
  The macro or compiler must reject it with the documented diagnostic (BREAK_EXPECT) at the changed site.
- An unsupported rewrite writes valid Swift that the guide calls unsupported (async edges, untyped
  throws, `inout` sources, generic functions, or generic enclosing types). The macro itself must diagnose
  it.
- A variation rewrite changes the program in a way Swift accepts (closure conventions, default isolation,
  or `-O`), and the case must compile. A safe rewrite writes valid Swift that the guide neither supports
  nor rules out (access levels, attributes, or a schema in a function body). The case must either compile
  or emit a macro diagnostic, and never produce invalid generated code.

Each case compiles as the module `Fz`. A separate harness module imports `Fz` to print every graph, its
Mermaid and DOT renderings, and the seed's report. Any client section in the seed also compiles in that
harness module so it sees the schema as another module does. Beyond the rewrite comparisons above, every
compiled case must pass these checks:

- Link and run to completion.
- Print a graph for every declared schema containing every phase, input, operation, and event from the
  source.
- Export each type spelling as the author's single-line text without comments, naming the authored type
  when compiled in the scope the guide specifies.
- Render Mermaid and DOT diagrams that a strict reader parses back into the exact graph, including graph
  names decoded under non-identifier strings.
- Give each managed owner an initializer whose driver and handler labels match declaration order.
- Keep any client section that calls a deprecated generated member compiling after applying the compiler's
  deprecation fix-its.

Every seed must pass these checks on its own. A domain seed must print the report pinned in
EXPECTED_REPORTS, and a module generated from the seed's attributes must use every selected owner and
reject every unselected one. A refusal must match its whole documented message at the named token. A
watchdog kills any compilation process tree that exceeds `--memory-cap-mb` or `--timeout`, failing the
case before any allowance applies. `--self-test` plants a defect for each oracle and verifies that each
one is reported.

`--cost` compares scaled schemas spelled in base and rewritten forms, checking for identical outcomes at
the same size, macro time within a constant factor, and near-linear growth from smaller to larger sizes.

Every case compiles in its own process so one variant's error cannot hide another's. A crash or timeout in
the plugin or compiler always fails. After reducing away unneeded rewrites, the script writes each failing
case to OUTPUT/failures/ as a self-contained source file with a one-line description.
"""
import argparse
import collections
import concurrent.futures
import hashlib
import itertools
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
# A macro diagnostic meets an entry only when the whole message matches `pattern` (`re.fullmatch`), it stands where the
# case changed the schema (on a line a rewrite changed, or on a line that declares a name the message quotes), and the
# token at its line and column is the one the message names (`anchored_token`). An entry marked `exact` is a refusal a
# rewrite must meet: the case passes only with that diagnostic, and only when every other diagnostic or error is one
# the refused expansion leaves behind (CASCADE) or one the entry lists as its consequence (`consequent`). Every
# interface allowance must explain every line of the difference, not a part of it.

FAILURE_SPLIT_CLIENT = (
    r"thrown expression type '[^']+\.PreparationRejection' cannot be converted to error type '[^']+'|"
    r"cannot convert return expression of type '[^']+\.Route\.\w+Result' to return type '(?:StateMachine\.)?Advance<[^']+>'"
)

LIMITS = [
    dict(id='phase-alias', rewrites=r'^alias-', observed='macro-diagnostic', role='phase',
         pattern=r"Phase '[^']*' needs a distinct nongeneric struct or enum declared directly inside the schema, named with a Swift identifier that needs no backticks; aliases are unsupported\.|"
                 r"(Source |Destination )?'[^']*' is not a phase payload type declared in this schema\.|Put this construction in a static function that returns .* and name that function here\.",
         doc='Phase aliases, reusing a payload type for several phases, generic schema or phase payload'),
    dict(id='reserved-names', rewrites=r'^(reserved-member|verb-edge-name)$', observed='macro-diagnostic',
         pattern=r"(The schema name is reserved or shadowed by a direct member|'[^']*' is reserved for generated members|"
                 r"'[^']*' names a declaration the expansion makes inside the schema)\b.*|"
                 r"(Router|Transition) '[^']*' would generate the \w+ method [^ ]+, which (shadows|redeclares) .*; rename the (router|transition)\.|"
                 r"This (transition|router)'s effect type would be Effect\.\w+, which is unavailable; rename the (transition|router)\.",
         doc='Generated member names are reserved'),
    dict(id='pinned-failure', rewrites=r'^(throws-any-error|untyped-throws)$', observed='expansion-error',
         pattern=r'.*cannot be converted to error type.*',
         doc='The compiler then checks that the router and every throwing candidate throw that type'),
    dict(id='public-default', rewrites=r'^schema-access$', observed='expansion-error', pattern=r'.*is internal and cannot be referenced from a default argument.*',
         doc='a public schema needs a public initializer or function'),
    # Refusals a rewrite must meet exactly: the case passes only with this diagnostic.
    dict(id='conditional-members', rewrites=r'^conditional-compilation$', observed='macro-diagnostic',
         pattern=r"Move this '#if' outside the schema or into a function body: .*", exact=True, token=r'#if',
         doc='so it refuses `#if` among the members of the schema, `Input`, `Scope`, and each operation and event namespace'),
    dict(id='conditional-attributes', rewrites=r'^conditional-attribute$', observed='macro-diagnostic',
         pattern=r"Move this '#if' out of the declaration's attributes: .*", exact=True, token=r'#if',
         doc='and in the attributes of any of those members'),
    dict(id='custom-attribute', rewrites=r'^(declaration-attributes|lowercase-attribute)$', observed='macro-diagnostic',
         pattern=r"Remove '@[^']+': generated code calls this function from nonisolated code and from every owner, .*", exact=True,
         doc='any other attribute, which could isolate it to a global actor such as `@MainActor`, whatever its capitalization, or change how a call to it is checked, is refused'),
    dict(id='function-availability', rewrites=r'^(declaration-attributes|edge-availability)$', observed='macro-diagnostic',
         pattern=r"Remove '@(available|backDeployed)' and give the schema this availability instead: .*", exact=True,
         # Swift's own refusals of the same attribute on the authored function: `@backDeployed` on a fileprivate
         # function, and an `@available` older than the schema's own availability.
         consequent=r"'@backDeployed' may not be used on (fileprivate|private) declarations|"
                    r"static method cannot be more available than enclosing scope",
         doc='so it refuses `@available` and `@backDeployed` on the function and asks for them on the schema'),
    # A rewrite that declares an alias or helper of internal access inside a public schema meets the same refusal.
    dict(id='schema-access', rewrites=r'^(schema-access|alias-generic|alias-chain|alias-nested|alias-local|leaf-access)$', observed='macro-diagnostic',
         pattern=r"Declare '[^']*' (public|package): the (public|package) schema '[^']*' generates (public|package) members that name it.*",
         exact=True, doc='Each declaration of the schema that one of those spellings names, as Swift resolves the spelling where it is written, needs that access too'),
    # Not an allowance: under `reorder-members` the initializers' driver and handler labels must follow the new
    # declaration order, as this documents; every case checks them against its own declaration order.
    dict(id='declaration-order-labels', rewrites=r'^reorder-members$', observed='normalization', pattern=r'$^',
         doc="A managed owner's initializers take one driver per operation, in the order the operations are declared, and then one handler per event, in the order the events are declared"),
    dict(id='size-limit', rewrites=r'^ceilings$', observed='macro-diagnostic', exact=True,
         pattern=r'This schema declares \d+ (phases|input cases|operations|operations, cancellations, and events); the macro accepts at most \d+, .*',
         doc='The macro accepts at most 600 phases, 512 input cases, 256 operations, and 512 effect cases'),
    dict(id='raw-type-names', rewrites=r'^collide-raw$', observed='macro-diagnostic',
         pattern=r'Name the (case|schema|operation|event|phase set|transition or router) with a Swift identifier that needs no backticks, .*|'
                 r"Phase '[^']*' needs a distinct nongeneric struct or enum declared directly inside the schema, named with a Swift identifier that needs no backticks; aliases are unsupported\.",
         doc='names are Swift identifiers that need no backticks'),
    # A failure the macro reads without confirming it (a name a nested namespace finds outside itself, a bare `Array` or
    # `Int` the schema does not declare, a `Swift.` the schema does not declare) is not provably the type another
    # function throws, even one spelled `Swift::Int`, so a router's method
    # throws PreparationRejection and its Owned method returns the routed result instead of one shared Advance.
    dict(id='unconfirmed-failure-split', rewrites=r'^(alias-nested|sugar|swift-dot|module-selector)$', observed='interface|client-error',
         pattern=r'PreparationRejection|Route\.\w+Result',
         client_pattern=FAILURE_SPLIT_CLIENT,
         doc='Every other pair counts as two failures, which keeps the generated code correct'),
    dict(id='outside-alias-failure', rewrites=r'^alias-file$', observed='interface|client-error',
         pattern=r'PreparationRejection|Route\.\w+Result',
         client_pattern=FAILURE_SPLIT_CLIENT,
         doc='an alias declared outside the schema is invisible to the macro'),
    dict(id='outside-never', rewrites=r'^alias-file$', observed='expansion-error',
         pattern=r'.*names Never through a declaration the macro cannot read.*',
         # The generated code that reads the failure as a type with values: its catch of a typed error and its
         # `try` find the type is `Never` after all.
         consequent=r"cannot convert value of type 'any Error' to expected argument type '[^']*' \(aka 'Never'\)|"
                    r"no calls to throwing functions occur within 'try' expression|"
                    r"'catch' block is unreachable because no errors are thrown in 'do' block",
         doc='that the macro reads as a type with values without confirming its kind, must not be `Never`'),
    dict(id='outside-never-owned', rewrites=r'^alias-file$', observed='macro-diagnostic', exact=True, token=r'throws',
         pattern=r'Owned-only transitions cannot throw; return Advance<Source, Destination, Effect, Failure> to give the source back\.',
         doc='an alias declared outside the schema is invisible to the macro'),
    dict(id='nfc-refusal', rewrites=r'^collide-(nfd|kelvin|varia)', observed='macro-diagnostic',
         pattern=r"The name '[^']*' is not in Unicode Normalization Form C(; spell it '[^']*'|, and composed it reads '[^']*', which is no name; spell it with other characters)\. .*",
         doc='The macro therefore refuses a name that is not in that form anywhere it reads one'),
    dict(id='repeated-ownership', rewrites=r'^shared-param$', observed='interface', pattern=r'__shared',
         doc='repeats the payload\'s ownership'),
]

POLICY_NFC = r"The name '[^']*' is not in Unicode Normalization Form C.*"

# Errors a refused expansion leaves behind: authored code that names a generated type the macro never declared.
CASCADE = re.compile(r"^cannot find (type )?'(Effect|Route|Change|Advance|Restoration|Observed|Owned|Prepared|Snapshot|Phase|"
                     r"\w+Request|\w+Completion|\w+Result)' in scope$|^'(Effect|Route|Change|Advance|Restoration|Observed|Owned|"
                     r"Prepared|Snapshot|Phase|Local|Shared|\w+Request|\w+Completion|\w+Result)' is not a member type|"
                     # Swift's own access errors where an access refusal names the declaration that lacks access.
                     r"uses an? (internal|fileprivate|private|package) type|is (internal|fileprivate|private|package) and cannot be referenced|"
                     # The harness's accessor of a graph or owner whose expansion was refused.
                     r"^type '[^']*' has no member '(graph|owned)'$")

# What a breaking rewrite must be rejected with: the macro's documented diagnostic, or Swift's own error where the
# grammar is Swift's. A case rejected any other way, or by a link error, fails.
# The graph checks a breaking rewrite of the graph may meet first: which one fires depends on the order the macro checks
# a graph in, so any of them is the documented rejection of a graph made invalid.
# The graph findings a graph made invalid elsewhere leaves behind: a phase or an operation that only the changed part
# reached. A breaking rewrite of the graph names its own finding (`refusal`, below); these may accompany it.
GRAPH_CONSEQUENCES = (r"Phase '[^']*' is unreachable from the initial phase '[^']*'( or a phase @Restoration can restore)?; declare a transition into it, or remove it\.|"
                      r"Phase '[^']*' has no outgoing transitions; mark it '@Terminal' or declare a transition from it\.|"
                      r"Operation '[^']*' is never started: .*|Operation '[^']*' can start but .*")

# What a breaking rewrite must be rejected with, the whole message: the macro's documented diagnostic, or Swift's own
# error where the grammar is Swift's. A rewrite whose change names a phase or an operation gives the exact finding in
# its `refusal`; these are the rest. A case rejected any other way, or by a link error, fails.
BREAK_EXPECT = {
    'router-returns-void': r"A router with no edge to choose returns Never and throws a typed rejection.*|A router returns its choice among .*|"
                           r"The name '[^']*' is not in Unicode Normalization Form C.*",
    'scope-property': r"Operation metadata must reference declared Scope cases, .*|\w+ must reference declared Scope cases\.|Write each reference .*|"
                      r"The name '[^']*' is not in Unicode Normalization Form C.*",
    'phase-alias-other': r"Phase '[^']*' needs a distinct nongeneric struct or enum declared directly inside the schema, .*|The name '[^']*' is not in Unicode Normalization Form C.*|"
                         r"'[^']*' is not a phase payload type declared in this schema\.|Put this construction in a static function .*",
    'drop-request-label': r'.*labeled request:.*',
    'router-duplicate': r"Ambiguous routing from '[^']*' for .*; declare exactly one @Route when multiple edges match\.|.*more than one @Route.*|.*twice.*",
    'cancel-unkeyed': r'.*\bcancels?:? .*keyed.*|.*cancel.*',
    'owner-duplicate': r"List each owner once; '\.[^']*' appears twice\.",
    'owner-excluded': r"Owner '\.[^']*' is unavailable in \.\w+, which supports .*",
    'owner-empty': r'List at least one owner, or omit owners:.*',
    'restoration-duplicate': r'Declare at most one @Restoration function in a schema\.',
    'restoration-entrance': r"List at least one restorable phase in only:\.",
    'qualify-renamed': r"Write the bare name of the replacement (edge|router) in 'renamed:': the generated methods repeat this "
                       r"deprecation as written, so it must name another (edge|router) that has a generated public method "
                       r"wherever this one has\.",
}

# Swift's own diagnostics of the unsupported form itself, which may accompany the macro's.
# - "generic parameter 'T' is not used in function signature": an authored generic function's unused parameter
#   (`generic-function`) is Swift's own warning, an error under `-warnings-as-errors`.
# - "static stored properties not supported in generic types": inside a generic enclosing type (`nest-generic`)
#   Swift itself refuses every static stored property the schema's authored members declare.
DIAG_CONSEQUENCES = (r"generic parameter '[^']*' is not used in function signature|"
                     r"static stored properties not supported in generic types")

# What an unsupported rewrite must be diagnosed with, the whole message, at the token it changed.
DIAG_EXPECT = {
    'async-function': r"Use a synchronous nongeneric static function with .*",
    'generic-function': r"Use a synchronous nongeneric static function with .*|Take this .* as a concrete type; an opaque 'some' parameter makes the function generic\.",
    'untyped-throws': r".* must use typed throws\(Failure\), or omit throws\.",
    'inout-source': r"Use a plain or borrowing phase payload as the source parameter\.|Pass the saved data to a @Restoration function by value, not inout\.",
    'nest-generic': r"Generic schemas(, including schemas inside a generic enclosing type,)? are unsupported.*",
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
    'own-public-sendable-helper': '7',
    'own-swap-drivers': 'left done L,noted 1; right done R,logged 2',
    'own-deprecated-edge': 'finished',
    'own-deprecated-message-edge': 'finished',
    'own-alias-leaf-specialized': 'done',
    'own-failure-router': 'retained 1; paused.gaveUp',
    'own-testing-duplicate': 'first loading.hold; duplicate none; unexercised ["loading.hold"]',
    'own-same-basename': '2 3',
    'own-alias-leaf': 'done',
    'own-report-local': 'idle.left@1; driver L1; delivery busy.worked; idle.right@3; driver R2; delivery busy.worked; '
                        'idle.finish@5; logged left 1,worked 21,right 2,worked 22; rejected left(3); done; idle.right@1; '
                        'driver R4; delivery busy.worked; 2; refused broken',
    'own-phase-set': 'draft.edit@1; noted d; rejected edit; editing.revert@2; draft.submit@3; review.edit@4; noted r; '
                     'editing.archive@5; archived; owned noted o; archived; edges 9',
    'own-phase-set-owned': 'closed; open; edges 5',
    'own-routed-handoff': 'comparing.advance@1/11; comparing.stay@2/11; rejected empty; comparing.finish@3/ok:22; '
                          'delivery reviewing.followUp@4/req:7|ok:22; delivery followUp.done@5/req:7|ok:22; owned 33; edges 6',
    'own-routed-noncopyable': 'open.inspect@1/5; open.take@2/9; taken; owned 12; closure 42; edges 5',
    'own-generic-source': 'browsing.select@1/7; noted 7; browsing.show@2/7:s1; presenting.select@3/9:s1; noted 9; '
                          'presenting.presentConfirmation@4/9:s1:c1; sheetConfirming.select@5/11:s1:c1; noted 11; '
                          'sheetConfirming.back@6/11; rejected back; browsing.reset@7/0; browsing.finish@8/0+end; '
                          'done; owned 5:s2; edges 19',
    'own-generic-source-owned': 'advanced r1; rejected r1; closed r1; reset init; edges 6',
}


def chain_seed(limit, length, mode='.shared', owners='.local'):
    """A `.parallel(limit:)` operation started once whose completions walk a chain of `length` phases: the macro counts
    executions up to 32 and treats a larger limit as unbounded, so the chain is reachable exactly when
    `length <= limit` or `limit > 32`."""
    phases = '\n'.join(f'    struct C{i}: Sendable {{}}' for i in range(length + 1))
    cases = '\n'.join(f'    {"@Terminal " if i == length else ""}case c{i}(C{i})' for i in range(1, length + 1))
    active = ', '.join(f'C{i}.self' for i in range(1, length))
    edges = '\n'.join(f'    @Transition(onSuccess: Work.self)\n    fileprivate static func step{i}(_ source: C{i}, _ value: Int) -> C{i + 1} {{ C{i + 1}() }}'
                      for i in range(1, length))
    return f'''import StateMachine

@StateMachine(mode: {mode}, owners: [{owners}])
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

def chain_owner_seed(mode, owner):
    """A schema in `mode` selecting `owner` alone, with an operation whose driver its initializer takes."""
    return f'''import StateMachine

@StateMachine(mode: {mode}, owners: [{owner}])
nonisolated enum Solo: Sendable {{
    struct Idle: Sendable {{}}
    struct Busy: Sendable {{}}
    @Initial case idle(Idle)
    case busy(Busy)
    enum Input: Sendable {{ case go }}
    @Operation(activeIn: [Busy.self])
    enum Work {{ typealias Output = Int }}
    @Transition(on: Input.go, starts: [Work.self])
    fileprivate static func go(_ source: Idle) -> Change<Busy, Effect.Go> {{ Change(Busy(), effects: [.work]) }}
    @Transition(onSuccess: Work.self)
    fileprivate static func done(_ source: Busy, _ value: Int) -> Idle {{ Idle() }}
}}
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
    case .run(let ran): return "produced \\(ran.withValue { $0.value })"
    case .skip: return "no evaluation"
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
    case .run(let ran): return "produced \\(ran.withValue { $0.value })"
    case .keep: return "no evaluation"
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
func fuzzReport() -> String {
    var gauge = Gauge.Local(Gauge.Start())
    let low = (try? gauge.send(.read(3)))?.edgeID ?? "rejected"
    return low
}
// fuzz-client
@testable import Fz
import StateMachine

@available(macOS 26, *)
func pinned(_ start: Gauge.Observed<Gauge.Start>) -> (Int) throws(Gauge.Problem<10>) -> Gauge.Prepared {
    { value throws(Gauge.Problem<10>) in try start.read(value) }
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
    # The same chains in an isolated schema with a confined managed owner beside `Local`.
    'parallel-32-isolated': chain_seed(32, 33, '.isolated', '.local, .isolatedHost'),
    'parallel-33-isolated': chain_seed(33, 34, '.isolated', '.local, .isolatedHost'),
    # A public closure payload beside a lower-access helper named `Sendable`: `@Sendable` is an attribute, not a type
    # the access check resolves, so the helper's access does not matter.
    'public-sendable-helper': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
public nonisolated enum Runner: Swift::Sendable {
    enum Sendable {}
    public struct Idle: Swift::Sendable { public init() {} }
    public struct Done: Swift::Sendable { public let value: Swift::Int }
    @Initial case idle(Idle)
    @Terminal case done(Done)
    public enum Input: Swift::Sendable { case run(@Sendable () -> Swift::Int) }
    @Transition(on: Input.run)
    fileprivate static func run(_ source: Idle, _ work: @escaping @Sendable () -> Swift::Int) -> Done { Done(value: work()) }
}

func fuzzReport() -> String { Runner.owned(Runner.Idle()).run { 7 }.withValue { "\\($0.value)" } }
''',
    # A managed graph with two drivers of one type and two handlers of one payload: wiring the wrong closure to an
    # operation or an event changes the pinned report.
    'swap-drivers': '''
import StateMachine
import os

@StateMachine(mode: .shared, owners: [.mainActorHost])
nonisolated enum Swap: Sendable {
    struct Idle: Sendable {}
    struct Busy: Sendable {}
    struct Done: Sendable {}
    @Initial case idle(Idle)
    case busy(Busy)
    @Terminal case done(Done)
    enum Input: Sendable { case left, right }
    @Operation(activeIn: [Busy.self])
    enum Left { typealias Output = Int }
    @Operation(activeIn: [Busy.self])
    enum Right { typealias Output = Int }
    @Event
    enum Noted { typealias Payload = Int }
    @Event
    enum Logged { typealias Payload = Int }
    @Transition(on: Input.left, starts: [Left.self], emits: [Noted.self])
    fileprivate static func goLeft(_ source: Idle) -> Change<Busy, Effect.GoLeft> { Change(Busy(), effects: [.left, .noted(1)]) }
    @Transition(on: Input.right, starts: [Right.self], emits: [Logged.self])
    fileprivate static func goRight(_ source: Idle) -> Change<Busy, Effect.GoRight> { Change(Busy(), effects: [.right, .logged(2)]) }
    @Transition(onSuccess: Left.self)
    fileprivate static func leftDone(_ source: Busy, _ value: Int) -> Done { Done() }
    @Transition(onSuccess: Right.self)
    fileprivate static func rightDone(_ source: Busy, _ value: Int) -> Done { Done() }
}

final class FuzzLog: Sendable {
    let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
    func add(_ line: String) { lines.withLock { $0.append(line) } }
}

@MainActor func fuzzSwapRun(_ input: Swap.Input) async -> String {
    let log = FuzzLog()
    let host = Swap.MainActorHost(
        Swap.Idle(),
        leftDriver: {
            log.add("L")
            return 10
        },
        rightDriver: {
            log.add("R")
            return 20
        },
        onNoted: { log.add("noted \\($0)") },
        onLogged: { log.add("logged \\($0)") }
    )
    _ = try? host.send(input)
    for _ in 0 ..< 10_000 {
        if case .done = host.snapshot() { break }
        await Task.yield()
    }
    let phase = if case .done = host.snapshot() { Swap.graph.terminal[0] } else { "stuck" }
    return "\\(input) \\(phase) \\(log.lines.withLock { $0.sorted() }.joined(separator: ","))"
}

@MainActor func fuzzReportAsync() async -> String { "\\(await fuzzSwapRun(.left)); \\(await fuzzSwapRun(.right))" }
''',
    # One managed owner selected alone, each with an operation, so its external use stands on its own.
    'single-actor-host': chain_owner_seed('.shared', '.actorHost'),
    'single-main-actor-host': chain_owner_seed('.shared', '.mainActorHost'),
    'single-isolated-host': chain_owner_seed('.isolated', '.isolatedHost'),
    # A deprecated authored function: generated public members named for it repeat the deprecation, and the
    # expansion stays warning-clean.
    'deprecated-edge': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
public nonisolated enum Renamed: Swift::Sendable {
    public struct Idle: Swift::Sendable { public init() {} }
    public struct Done: Swift::Sendable {}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    public enum Input: Swift::Sendable { case go, finish }
    @available(*, deprecated, renamed: "finish")
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle) -> Done { Done() }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Idle) -> Done { Done() }
}

func fuzzReport() -> String { Renamed.owned(Renamed.Idle()).finish().withValue { _ in "finished" } }
// fuzz-client
@testable import Fz

// A caller of the deprecated member: applying the compiler's fix-it must give a call that compiles.
func fuzzDeprecatedCall() -> String { Renamed.owned(Renamed.Idle()).go().withValue { _ in "go" } }
''',
    # A deprecation with a migration message, whose options Swift reads in any order.
    'deprecated-message-edge': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
public nonisolated enum Migrating: Swift::Sendable {
    public struct Idle: Swift::Sendable { public init() {} }
    public struct Done: Swift::Sendable {}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    public enum Input: Swift::Sendable { case go, finish }
    @available(*, deprecated, message: "migration")
    @Transition(on: Input.go)
    fileprivate static func go(_ source: Idle) -> Done { Done() }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Idle) -> Done { Done() }
}

func fuzzReport() -> String { Migrating.owned(Migrating.Idle()).finish().withValue { _ in "finished" } }
''',
    # A completion that a router refuses, delivered and retained before a test takes the owner, then delivered
    # again inside the test: the duplicate prepares nothing, so it is no evidence that the router refused it, and
    # coverage still lists the router. The report reads the evidence from each delivery's own result.
    'testing-duplicate': '''
import StateMachine
import StateMachineTesting

@StateMachine(mode: .shared, owners: [.local])
nonisolated enum Hold: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable {}
    struct Paused: Sendable {}
    enum Refusal: Error, Sendable, Equatable { case busy }
    @Initial case idle(Idle = Idle())
    case loading(Loading)
    case paused(Paused)
    enum Input: Sendable { case start, pause }
    @Operation(activeIn: [Loading.self, Paused.self])
    enum Fetch { typealias Output = Int }
    @Transition(on: Input.start, starts: [Fetch.self])
    fileprivate static func start(_ source: Idle) -> Change<Loading, Effect.Start> {
        Change(Loading(), effects: [.fetch])
    }
    @Transition(on: Input.pause)
    fileprivate static func pause(_ source: Loading) -> Paused { Paused() }
    @Route(onSuccess: Fetch.self)
    fileprivate static func hold(_ source: Loading, _ value: Int) throws(Refusal) -> Never { throw .busy }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func resume(_ source: Paused, _ value: Int) -> Idle { Idle() }
}

func fuzzRefusal(_ result: Hold.DeliveryResult) -> String {
    if case .refused(_, _, let route) = result { return route ?? "unnamed" }
    return "none"
}

func fuzzReport() -> String {
    var owner = Hold.Local()
    guard (try? owner.send(.start)) != nil,
        case .fetch(let work)? = owner.drainCommands(limit: .max).flatMap(\\.commands).first
    else { return "no fetch" }
    let first = owner.deliver(.fetch(work.succeeded(1)))
    var coverage = GraphCoverage(for: Hold.Local.self)
    var test = ManualMachineTest(owner)
    let duplicate = test.deliver(.fetch(work.succeeded(1)))
    coverage.record(test)
    return "first \\(fuzzRefusal(first)); duplicate \\(fuzzRefusal(duplicate)); unexercised \\(coverage.unexercisedRejectingRouters.map(\\.id))"
}
''',
    # A failure router that always refuses beside completion edges that accept the outcome in another phase: the
    # refused failure is retained, and reconciling it after a pause takes the failure edge.
    'failure-router': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.local])
nonisolated enum Retry: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable {}
    struct Paused: Sendable {}
    enum Problem: Error, Sendable { case failed, busy }
    @Initial case idle(Idle = Idle())
    case loading(Loading)
    case paused(Paused)
    enum Input: Sendable { case start, pause }
    @Operation(activeIn: [Loading.self, Paused.self])
    enum Fetch {
        typealias Output = Int
        typealias Failure = Problem
    }
    @Transition(on: Input.start, starts: [Fetch.self])
    fileprivate static func start(_ source: Idle) -> Change<Loading, Effect.Start> {
        Change(Loading(), effects: [.fetch])
    }
    @Transition(on: Input.pause)
    fileprivate static func pause(_ source: Loading) -> Paused { Paused() }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func loaded(_ source: Loading, _ value: Int) -> Idle { Idle() }
    @Route(onFailure: Fetch.self)
    fileprivate static func hold(_ source: Loading, _ failure: Problem) throws(Problem) -> Never { throw .busy }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func resumed(_ source: Paused, _ value: Int) -> Idle { Idle() }
    @Transition(onFailure: Fetch.self)
    fileprivate static func gaveUp(_ source: Paused, _ failure: Problem) -> Idle { Idle() }
}

func fuzzReport() -> String {
    var owner = Retry.Local()
    guard (try? owner.send(.start)) != nil,
        case .fetch(let work)? = owner.drainCommands(limit: .max).flatMap(\\.commands).first
    else { return "no fetch" }
    _ = owner.deliver(.fetch(work.failed(.failed)))
    let retained = owner.pendingCompletions().map(\\.id)
    guard let id = retained.first, (try? owner.send(.pause)) != nil else { return "not retained" }
    guard case .committed(let receipt) = owner.reconcile(id: id) else { return "not reconciled" }
    return "retained \\(retained.count); \\(receipt.edgeID ?? "none")"
}
''',
    # Two schemas of one basename in different enclosing types, one in another file of the module.
    'same-basename': '''
import StateMachine

enum Left {}
enum Right {}

extension Left {
    @StateMachine(mode: .shared, owners: [.owned])
    nonisolated enum Flow: Sendable {
        struct Idle: Sendable {}
        struct Done: Sendable {}
        @Initial case idle(Idle)
        @Terminal case done(Done)
        enum Input: Sendable { case go }
        @Transition(on: Input.go)
        fileprivate static func go(_ source: Idle) -> Done { Done() }
    }
}

func fuzzReport() -> String { "\\(Left.Flow.graph.phases.count) \\(Right.Flow.graph.phases.count)" }
// fuzz-file: Other.swift
import StateMachine

extension Right {
    @StateMachine(mode: .shared, owners: [.owned])
    nonisolated enum Flow: Sendable {
        struct Start: Sendable {}
        struct Middle: Sendable {}
        struct End: Sendable {}
        @Initial case start(Start)
        case middle(Middle)
        @Terminal case end(End)
        enum Input: Sendable { case go }
        @Transition(on: Input.go)
        fileprivate static func go(_ source: Start) -> Middle { Middle() }
        @Transition(on: Input.go)
        fileprivate static func on(_ source: Middle) -> End { End() }
    }
}
''',
    # A public schema whose payload names a public leaf through a public namespace alias; `leaf-access` lowers the
    # leaf's access, which the access check must refuse through the alias as it does through the type's own name.
    'alias-leaf': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
public nonisolated enum Leaf: Swift::Sendable {
    public enum Box { public struct Hidden: Swift::Sendable { public init() {} } }
    public typealias N = Box
    public struct Idle: Swift::Sendable { public init() {} }
    public struct Done: Swift::Sendable {}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    public enum Input: Swift::Sendable { case use(N.Hidden) }
    @Transition(on: Input.use)
    fileprivate static func use(_ source: Idle, _ value: N.Hidden) -> Done { Done() }
}

func fuzzReport() -> String { Leaf.owned(Leaf.Idle()).use(Leaf.Box.Hidden()).withValue { _ in Leaf.graph.terminal[0] } }
''',
    # The same leaf through a specialized namespace alias and in a typed throw; `leaf-access` lowers the leaf's
    # access, spelled through the alias and through the directly specialized base.
    'alias-leaf-specialized': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
public nonisolated enum Special: Swift::Sendable {
    public enum Box<T> { public struct Hidden: Swift::Error { public init() {} } }
    public typealias N = Box<Swift::Int>
    public struct Idle: Swift::Sendable { public init() {} }
    public struct Done: Swift::Sendable {}
    @Initial case idle(Idle)
    @Terminal case done(Done)
    public enum Input: Swift::Sendable { case use }
    @Transition(on: Input.use)
    fileprivate static func use(_ source: Idle) throws(N.Hidden) -> Done { Done() }
}

func fuzzReport() -> String {
    switch Special.owned(Special.Idle()).use() {
    case .advanced(let done, _): done.withValue { _ in Special.graph.terminal[0] }
    default: "not advanced"
    }
}
''',
    # A public schema with private and fileprivate `@PhaseSet` enums declared both before and after transitions,
    # non-alphabetical member orders, an unused set containing a `@Terminal` phase, an inline `from:` list, and a
    # cross-module client.
    'phase-set': '''
import StateMachine

@StateMachine(mode: .shared, owners: [.owned, .local])
public nonisolated enum Board: Swift::Sendable {
    public struct Draft: Swift::Sendable {
        public let note: Swift::String
        public init(note: Swift::String = "init") { self.note = note }
    }
    public struct Review: Swift::Sendable { public let note: Swift::String }
    public struct Editing: Swift::Sendable { public let note: Swift::String }
    public struct Archived: Swift::Sendable { public let note: Swift::String }
    @Initial case draft(Draft = Draft())
    case review(Review)
    case editing(Editing)
    @Terminal case archived(Archived)
    public enum Input: Swift::Sendable { case submit, edit(Swift::String), revert, archive }
    @Operation(activeIn: [Review.self])
    public enum Audit { public typealias Output = Swift::Int }
    @Event
    public enum Noted { public typealias Payload = Swift::String }
    @PhaseSet([Review.self, Draft.self])
    fileprivate enum Editable {}
    @Transition(on: Input.submit, starts: [Audit.self])
    fileprivate static func submit(_ source: Draft) -> Change<Review, Effect.Submit> {
        Change(Review(note: source.note), effects: [.audit])
    }
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: Review, _ score: Audit.Output) -> Draft {
        Draft(note: "\\(source.note):\\(score)")
    }
    @Transition(from: Editable.self, on: Input.edit, emits: [Noted.self])
    fileprivate static func edit(_ note: Swift::String) -> Change<Editing, Effect.Edit> {
        Change(Editing(note: note), effects: [.noted(note)])
    }
    @Transition(from: [Editing.self, Review.self], on: Input.revert)
    fileprivate static func revert() -> Draft { Draft(note: "reverted") }
    @Transition(from: Closeable.self, on: Input.archive)
    fileprivate static func archive() -> Archived { Archived(note: "archived") }
    @PhaseSet([Editing.self, Review.self, Draft.self])
    private enum Closeable {}
    @PhaseSet([Archived.self, Draft.self])
    fileprivate enum SnapshotPhases {}
}

func fuzzReport() -> String {
    var out: [String] = []
    var board = Board.Local()
    func step(_ input: Board.Input, _ label: String) {
        do {
            let receipt = try board.send(input)
            out.append("\\(receipt.edgeID ?? "-")@\\(receipt.snapshot.revision)")
        } catch { out.append("rejected \\(label)") }
        for batch in board.drainCommands() {
            for command in batch.commands {
                switch command {
                case .audit(let work): _ = board.acknowledgeExecution(work.execution)
                case .noted(let text): out.append("noted \\(text)")
                case .cancel: break
                }
            }
        }
    }
    step(.edit("d"), "edit")
    step(.edit("e"), "edit")
    step(.revert, "revert")
    step(.submit, "submit")
    step(.edit("r"), "edit")
    step(.archive, "archive")
    out.append("\\(Board.Local.phase(of: board.snapshot()))")
    let change = Board.owned().edit("o")
    let ownedNote = change.effects.compactMap { if case .noted(let text) = $0 { text } else { nil } }.joined(separator: ",")
    out.append("owned noted \\(ownedNote)")
    out.append(change.next.archive().withValue { $0.note })
    out.append("edges \\(Board.graph.edges.count)")
    return out.joined(separator: "; ")
}
// fuzz-client
import Fz

func fuzzClient() -> Swift::String {
    let change = Board.owned().edit("c")
    return change.next.archive().withValue { $0.note }
}
''',
    # An `.ownedOnly` noncopyable schema with a `@PhaseSet` direct transition and an inline `from:` direct transition.
    'phase-set-owned': '''
import StateMachine

@StateMachine(mode: .ownedOnly)
nonisolated enum Handle: ~Copyable {
    struct Open: ~Copyable { let label: Swift::String }
    struct Busy: ~Copyable { let label: Swift::String }
    struct Closed: ~Copyable { let label: Swift::String }
    @Initial case open(Open)
    case busy(Busy)
    @Terminal case closed(Closed)
    @PhaseSet([Busy.self, Open.self])
    fileprivate enum Live {}
    @Transition
    fileprivate static func begin(_ source: consuming Open) -> Busy { Busy(label: source.label) }
    @Transition(from: Live.self)
    fileprivate static func close() -> Closed { Closed(label: "closed") }
    @Transition(from: [Busy.self, Open.self])
    fileprivate static func reset() -> Open { Open(label: "open") }
}

func fuzzReport() -> String {
    let closed = Handle.owned(Handle.Open(label: "a")).begin().close().withValue { $0.label }
    let reopened = Handle.owned(Handle.Open(label: "b")).begin().reset().withValue { $0.label }
    return "\\(closed); \\(reopened); edges \\(Handle.graph.edges.count)"
}
''',
    # A public `.isolated` schema exercising typed `routed:` handoffs: a `fileprivate` non-`Sendable` closure payload
    # kept out of the public interface, a labeled tuple payload, a bare fallback candidate, typed router throws, and
    # a completion router passing both `request:` and `routed:` in order with distinct per-branch `starts:`.
    'routed-handoff': '''
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned, .local, .mainActorHost])
public nonisolated enum FlowHandoff {
    fileprivate struct Step {
        let compute: () -> Swift::Int
    }
    public struct Comparing {
        public let score: Swift::Int
        public init(score: Swift::Int = 0) { self.score = score }
    }
    public struct Reviewing {
        public let summary: Swift::String
    }
    public struct FollowUpPhase {
        public let summary: Swift::String
    }
    public struct Finished {
        public let summary: Swift::String
    }
    public enum ChoiceError: Swift::Error, Swift::Equatable { case empty }
    @Initial case comparing(Comparing = Comparing())
    case reviewing(Reviewing)
    case followUp(FollowUpPhase)
    @Terminal case finished(Finished)
    public enum Input { case choose(Swift::Int) }
    @Operation(activeIn: [Reviewing.self])
    public enum Fetch {
        public typealias Input = Swift::Int
        public typealias Output = Swift::String
    }
    @Operation(activeIn: [FollowUpPhase.self])
    public enum FollowUp {
        public typealias Output = Swift::String
    }
    @Transition(on: Input.choose)
    fileprivate static func advance(_ source: Comparing, _ delta: Swift::Int, routed step: Step) -> Comparing {
        Comparing(score: source.score + step.compute())
    }
    @Transition(on: Input.choose)
    fileprivate static func stay(_ source: Comparing, _ delta: Swift::Int) -> Comparing {
        source
    }
    @Transition(on: Input.choose, starts: [Fetch.self])
    fileprivate static func finish(
        _ source: Comparing,
        _ delta: Swift::Int,
        routed pair: (label: Swift::String, score: Swift::Int)
    ) -> Change<Reviewing, Effect.Finish> {
        Change(Reviewing(summary: "\\(pair.label):\\(pair.score)"), effects: [.fetch(7)])
    }
    @Route(on: Input.choose)
    fileprivate static func routeChoice(_ source: Comparing, _ delta: Swift::Int) throws(ChoiceError) -> Route.RouteChoice {
        if delta < 0 { throw .empty }
        if delta == 0 { return .stay }
        if delta >= 10 { return .finish((label: "ok", score: source.score + delta)) }
        let added = delta + 10
        return .advance(Step(compute: { added }))
    }
    @Transition(onSuccess: Fetch.self, starts: [FollowUp.self])
    fileprivate static func followUp(
        _ source: Reviewing,
        _ output: Fetch.Output,
        request: FetchRequest,
        routed summary: Swift::String
    ) -> Change<FollowUpPhase, Effect.FollowUp> {
        Change(FollowUpPhase(summary: summary), effects: [.followUp])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func completeDirect(_ source: Reviewing, _ output: Fetch.Output) -> Finished {
        Finished(summary: output)
    }
    @Route(onSuccess: Fetch.self)
    fileprivate static func routeFetch(
        _ source: Reviewing,
        _ output: Fetch.Output,
        request: FetchRequest
    ) -> Route.RouteFetch {
        output == "need" ? .followUp("req:\\(request.input)|\\(source.summary)") : .completeDirect
    }
    @Transition(onSuccess: FollowUp.self)
    fileprivate static func done(_ source: FollowUpPhase, _ output: FollowUp.Output) -> Finished {
        Finished(summary: source.summary)
    }
}

func fuzzReport() -> String {
    var out: [String] = []
    var owner = FlowHandoff.Local()
    for delta in [1, 0, -1, 11] {
        do {
            let receipt = try owner.send(.choose(delta))
            let detail: String = switch receipt.snapshot {
            case .comparing(let c): "\\(c.value.score)"
            case .reviewing(let r): r.value.summary
            case .followUp(let f): f.value.summary
            case .finished(let d): d.value.summary
            }
            out.append("\\(receipt.edgeID ?? "-")@\\(receipt.snapshot.revision)/\\(detail)")
        } catch {
            out.append("rejected empty")
        }
    }
    guard case .fetch(let fetchWork)? = owner.drainCommands(limit: .max).flatMap(\\.commands).first else {
        return "missing fetch"
    }
    guard case .committed(let firstDelivery) = owner.deliver(.fetch(fetchWork.succeeded("need"))),
        case .followUp(let followPhase) = firstDelivery.snapshot
    else { return "bad fetch delivery" }
    out.append("delivery \\(firstDelivery.edgeID ?? "-")@\\(firstDelivery.snapshot.revision)/\\(followPhase.value.summary)")
    _ = owner.acknowledgeExecution(fetchWork.execution)
    guard case .followUp(let followWork)? = owner.drainCommands(limit: .max).flatMap(\\.commands).first else {
        return "missing followUp"
    }
    guard case .committed(let secondDelivery) = owner.deliver(.followUp(followWork.succeeded("ok"))),
        case .finished(let donePhase) = secondDelivery.snapshot
    else { return "bad followUp delivery" }
    out.append("delivery \\(secondDelivery.edgeID ?? "-")@\\(secondDelivery.snapshot.revision)/\\(donePhase.value.summary)")
    _ = owner.acknowledgeExecution(followWork.execution)
    let ownedScore: Int = switch FlowHandoff.owned(FlowHandoff.Comparing(score: 20)).routeChoice(3) {
    case .advance(let next): next.withValue { $0.score }
    case .stay(let next): next.withValue { $0.score }
    case .finish(let change): change.next.withValue { _ in -1 }
    case .rejected: -2
    }
    out.append("owned \\(ownedScore)")
    out.append("edges \\(FlowHandoff.graph.edges.count)")
    return out.joined(separator: "; ")
}
// fuzz-client
import Fz

func fuzzClient() -> Swift::Int {
    switch FlowHandoff.owned().routeChoice(0) {
    case .stay(let next): next.withValue { $0.score }
    case .advance(let next): next.withValue { $0.score }
    case .finish(let change): change.next.withValue { _ in 1 }
    case .rejected: -1
    }
}
''',
    # An `.isolated` schema with `~Copyable` `routed:` ownership (`consuming` and `borrowing`) plus `@escaping` and
    # `sending` conventions on routed parameters.
    'routed-noncopyable': '''
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned, .local])
nonisolated enum TokenRouter {
    struct Token: ~Swift::Copyable { let value: Swift::Int }
    struct Open {
        let total: Swift::Int
        init(total: Swift::Int = 0) { self.total = total }
    }
    struct Taken { let value: Swift::Int }
    @Initial case open(Open = Open())
    @Terminal case taken(Taken)
    enum Input { case step(Swift::Int), run }
    @Transition(on: Input.step)
    fileprivate static func inspect(_ source: Open, _ amount: Swift::Int, routed token: borrowing Token) -> Open {
        Open(total: source.total + token.value)
    }
    @Transition(on: Input.step)
    fileprivate static func take(_ source: Open, _ amount: Swift::Int, routed token: consuming Token) -> Taken {
        Taken(value: source.total + token.value)
    }
    @Transition(on: Input.step)
    fileprivate static func stay(_ source: Open, _ amount: Swift::Int) -> Open {
        source
    }
    @Route(on: Input.step)
    fileprivate static func routeStep(_ source: Open, _ amount: Swift::Int) -> Route.RouteStep {
        if amount == 0 { return .stay }
        if amount > 0 { return .inspect(Token(value: amount)) }
        return .take(Token(value: -amount))
    }
    @Transition(on: Input.run)
    fileprivate static func runClosure(_ source: Open, routed work: @escaping () -> Swift::Int) -> Taken {
        Taken(value: work())
    }
    @Transition(on: Input.run)
    fileprivate static func runSending(_ source: Open, routed flag: sending Swift::Int) -> Open {
        Open(total: flag)
    }
    @Route(on: Input.run)
    fileprivate static func routeRun(_ source: Open) -> Route.RouteRun {
        .runClosure({ 42 })
    }
}

func fuzzReport() -> String {
    var out: [String] = []
    var owner = TokenRouter.Local()
    if let r1 = try? owner.send(.step(5)), case .open(let p) = r1.snapshot {
        out.append("\\(r1.edgeID ?? "-")@\\(r1.snapshot.revision)/\\(p.value.total)")
    }
    if let r2 = try? owner.send(.step(-4)), case .taken(let p) = r2.snapshot {
        out.append("\\(r2.edgeID ?? "-")@\\(r2.snapshot.revision)/\\(p.value.value)")
    }
    out.append("\\(TokenRouter.Local.phase(of: owner.snapshot()))")
    let ownedVal: Int = switch TokenRouter.owned(TokenRouter.Open(total: 10)).routeStep(-2) {
    case .take(let done): done.withValue { $0.value }
    case .inspect(let open): open.withValue { $0.total }
    case .stay(let open): open.withValue { $0.total }
    }
    out.append("owned \\(ownedVal)")
    let closureVal: Int = switch TokenRouter.owned().routeRun() {
    case .runClosure(let done): done.withValue { $0.value }
    case .runSending(let open): open.withValue { $0.total }
    }
    out.append("closure \\(closureVal)")
    out.append("edges \\(TokenRouter.graph.edges.count)")
    return out.joined(separator: "; ")
}
''',
    # A public `.shared` schema combining generic `<Source>` multi-source transitions (same-phase `-> Change<Source, ...>`,
    # fixed destination with trailing `where`, typed error, two same-named multi-source transitions over `@PhaseSet`,
    # old parameterless `from:`, deprecated generic `from:`, and composed `from:` + `routed:`) with a cross-module client.
    'generic-source': '''
import StateMachine

nonisolated public protocol NavSelectionCarrying: Swift::Sendable {
    var selected: Swift::Int? { get set }
}
nonisolated public protocol NavSheetCarrying: NavSelectionCarrying {
    var sheet: Swift::String { get }
}

@StateMachine(mode: .shared, owners: [.owned, .local])
public nonisolated enum NavFlow: Swift::Sendable {
    public struct Browsing: NavSelectionCarrying {
        public var selected: Swift::Int?
        public init(selected: Swift::Int? = nil) { self.selected = selected }
    }
    public struct Confirming: NavSelectionCarrying {
        public var selected: Swift::Int?
        public let confirm: Swift::String
    }
    public struct Presenting: NavSheetCarrying {
        public var selected: Swift::Int?
        public let sheet: Swift::String
    }
    public struct SheetConfirming: NavSheetCarrying {
        public var selected: Swift::Int?
        public let sheet: Swift::String
        public let confirm: Swift::String
    }
    public struct Done: Swift::Sendable {
        public let note: Swift::String
    }
    public enum NavError: Swift::Error, Swift::Sendable, Swift::Equatable { case missingSelection }
    @Initial case browsing(Browsing = Browsing())
    case confirming(Confirming)
    case presenting(Presenting)
    case sheetConfirming(SheetConfirming)
    @Terminal case done(Done)
    public enum Input: Swift::Sendable {
        case select(Swift::Int?)
        case show(Swift::String)
        case presentConfirmation(Swift::String)
        case back
        case reset
        case finish
    }
    @Event
    public enum Noted { public typealias Payload = Swift::Int }
    @PhaseSet([Browsing.self, Confirming.self, Presenting.self, SheetConfirming.self])
    fileprivate enum AllActive {}
    @PhaseSet([Browsing.self, Confirming.self])
    fileprivate enum NonSheet {}
    @PhaseSet([Presenting.self, SheetConfirming.self])
    fileprivate enum SheetPhases {}
    @available(*, deprecated, message: "use rename")
    @Transition(from: AllActive.self, on: Input.select, emits: [Noted.self])
    fileprivate static func select<Source: NavSelectionCarrying>(
        _ source: Source,
        _ id: Swift::Int?
    ) -> Change<Source, Effect.Select> {
        var next = source
        next.selected = id
        return Change(next, effects: [.noted(id ?? -1)])
    }
    @Transition(from: [Browsing.self, Confirming.self], on: Input.show)
    fileprivate static func show<Source>(
        _ source: Source,
        _ sheet: Swift::String
    ) -> Presenting where Source: NavSelectionCarrying {
        Presenting(selected: source.selected, sheet: sheet)
    }
    @Transition(from: NonSheet.self, on: Input.presentConfirmation)
    fileprivate static func presentConfirmation<Source: NavSelectionCarrying>(
        _ source: Source,
        _ confirm: Swift::String
    ) -> Confirming {
        Confirming(selected: source.selected, confirm: confirm)
    }
    @Transition(from: SheetPhases.self, on: Input.presentConfirmation)
    fileprivate static func presentConfirmation<Source: NavSheetCarrying>(
        _ source: Source,
        _ confirm: Swift::String
    ) -> SheetConfirming {
        SheetConfirming(selected: source.selected, sheet: source.sheet, confirm: confirm)
    }
    @Transition(from: [Confirming.self, Presenting.self, SheetConfirming.self], on: Input.back)
    fileprivate static func back<Source: NavSelectionCarrying>(_ source: Source) throws(NavError) -> Browsing {
        guard let selected = source.selected else { throw .missingSelection }
        return Browsing(selected: selected)
    }
    @Transition(from: [Browsing.self, Presenting.self], on: Input.reset)
    fileprivate static func reset() -> Browsing {
        Browsing(selected: 0)
    }
    @Transition(from: [Browsing.self, Confirming.self], on: Input.finish)
    fileprivate static func finish<Source: NavSelectionCarrying>(_ source: Source, routed suffix: Swift::String) -> Done {
        Done(note: "\\(source.selected ?? -1)\\(suffix)")
    }
    @Transition(on: Input.finish)
    fileprivate static func keepBrowsing(_ source: Browsing) -> Browsing { source }
    @Route(on: Input.finish)
    fileprivate static func routeFinishBrowsing(_ source: Browsing) -> Route.RouteFinishBrowsing {
        .finish("+end")
    }
    @Transition(on: Input.finish)
    fileprivate static func keepConfirming(_ source: Confirming) -> Confirming { source }
    @Route(on: Input.finish)
    fileprivate static func routeFinishConfirming(_ source: Confirming) -> Route.RouteFinishConfirming {
        .finish("+conf")
    }
}

func fuzzReport() -> String {
    var out: [String] = []
    var nav = NavFlow.Local()
    func describe(_ snapshot: NavFlow.Snapshot) -> String {
        switch snapshot {
        case .browsing(let p): "\\(p.value.selected ?? -1)"
        case .confirming(let p): "\\(p.value.selected ?? -1):\\(p.value.confirm)"
        case .presenting(let p): "\\(p.value.selected ?? -1):\\(p.value.sheet)"
        case .sheetConfirming(let p): "\\(p.value.selected ?? -1):\\(p.value.sheet):\\(p.value.confirm)"
        case .done(let p): p.value.note
        }
    }
    func step(_ input: NavFlow.Input, _ label: String) {
        do {
            let receipt = try nav.send(input)
            out.append("\\(receipt.edgeID ?? "-")@\\(receipt.snapshot.revision)/\\(describe(receipt.snapshot))")
        } catch {
            out.append("rejected \\(label)")
        }
        for batch in nav.drainCommands() {
            for command in batch.commands {
                if case .noted(let value) = command { out.append("noted \\(value)") }
            }
        }
    }
    step(.select(7), "select")
    step(.show("s1"), "show")
    step(.select(9), "select")
    step(.presentConfirmation("c1"), "confirm")
    step(.select(11), "select")
    step(.back, "back")
    step(.back, "back")
    step(.reset, "reset")
    step(.finish, "finish")
    out.append("\\(NavFlow.Local.phase(of: nav.snapshot()))")
    let ownedShown = NavFlow.owned(NavFlow.Browsing(selected: 5)).show("s2").withValue { "\\($0.selected ?? -1):\\($0.sheet)" }
    out.append("owned \\(ownedShown)")
    out.append("edges \\(NavFlow.graph.edges.count)")
    return out.joined(separator: "; ")
}
// fuzz-client
import Fz

func fuzzClient() -> Swift::String {
    let presented = NavFlow.owned(NavFlow.Browsing(selected: 3)).show("c")
    return presented.withValue { "\\($0.selected ?? -1):\\($0.sheet)" }
}
''',
    # An `.ownedOnly` noncopyable schema with a generic `<Source>` same-phase `Advance`, fixed destination, and old
    # parameterless `from:`.
    'generic-source-owned': '''
import StateMachine

nonisolated protocol UniqueTitled: ~Swift::Copyable {
    var title: Swift::String { get set }
}

@StateMachine(mode: .ownedOnly)
nonisolated enum UniqueDoc: ~Swift::Copyable {
    struct Draft: ~Swift::Copyable, UniqueTitled { var title: Swift::String }
    struct Review: ~Swift::Copyable, UniqueTitled { var title: Swift::String }
    struct Closed: ~Swift::Copyable { let title: Swift::String }
    enum RenameError: Swift::Error { case empty }
    @Initial case draft(Draft)
    case review(Review)
    @Terminal case closed(Closed)
    enum Input { case rename(Swift::String) }
    @PhaseSet([Review.self, Draft.self])
    fileprivate enum Editable {}
    @Transition
    fileprivate static func submit(_ source: consuming Draft) -> Review { Review(title: source.title) }
    @Transition(from: Editable.self, on: Input.rename)
    fileprivate static func rename<Source: UniqueTitled & ~Swift::Copyable>(
        _ source: consuming Source,
        _ title: Swift::String
    ) -> Advance<Source, Source, Swift::Never, RenameError> {
        guard !title.isEmpty else { return .rejected(.empty, source) }
        var next = source
        next.title = title
        return .advanced(next, effects: [])
    }
    @Transition(from: [Review.self, Draft.self])
    fileprivate static func close<Source: UniqueTitled & ~Swift::Copyable>(_ source: consuming Source) -> Closed {
        Closed(title: source.title)
    }
    @Transition(from: [Review.self])
    fileprivate static func reset() -> Draft { Draft(title: "init") }
}

func fuzzReport() -> String {
    var out: [String] = []
    let review = UniqueDoc.owned(UniqueDoc.Draft(title: "d0")).submit()
    switch review.rename("r1") {
    case .advanced(let updated, _):
        out.append("advanced \\(updated.withValue { $0.title })")
        switch updated.rename("") {
        case .advanced(let kept, _):
            out.append("unexpected \\(kept.withValue { $0.title })")
        case .rejected(_, let original):
            out.append("rejected \\(original.withValue { $0.title })")
            out.append("closed \\(original.close().withValue { $0.title })")
        }
    case .rejected:
        out.append("failed")
    }
    let resetTitle = UniqueDoc.owned(UniqueDoc.Draft(title: "d1")).submit().reset().withValue { $0.title }
    out.append("reset \\(resetTitle)")
    out.append("edges \\(UniqueDoc.graph.edges.count)")
    return out.joined(separator: "; ")
}
''',
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
    """True for each character outside comments and string literals. Block comments nest, as Swift's do, and a raw
    string (`#"…"#`, multiline or not) ends only at its own delimiter."""
    mask = [True] * len(text)
    index = 0
    while True:
        opening = text.find('/*', index)
        if opening < 0:
            break
        # Only a comment opener in code: not inside a line comment or a string that starts earlier on its line.
        line_start = text.rfind('\n', 0, opening) + 1
        if '//' in text[line_start:opening] or text[line_start:opening].count('"') % 2:
            index = opening + 2
            continue
        depth, cursor = 1, opening + 2
        while cursor < len(text) and depth:
            if text.startswith('/*', cursor):
                depth, cursor = depth + 1, cursor + 2
            elif text.startswith('*/', cursor):
                depth, cursor = depth - 1, cursor + 2
            else:
                cursor += 1
        for position in range(opening, cursor):
            mask[position] = False
        index = cursor
    for raw in re.finditer(r'(#+)("""|")(.*?)\2\1', text, re.S):
        if mask[raw.start()]:
            for position in range(raw.start(), raw.end()):
                mask[position] = False
    for match in re.finditer(r'//[^\n]*|"""(?:.|\n)*?"""|"(?:[^"\\\n]|\\\((?:[^()]|\([^()]*\))*\)|\\.)*"', text):
        if not mask[match.start()]:
            continue
        for index in range(match.start(), match.end()):
            mask[index] = False
        # Code interpolated into a string literal is code.
        if match.group(0).startswith('"'):
            for inner in re.finditer(r'\\\(((?:[^()]|\((?:[^()]|\([^()]*\))*\))*)\)', match.group(0)):
                for index in range(match.start() + inner.start(1), match.start() + inner.end(1)):
                    mask[index] = True
    return mask


class Site:
    def __init__(self, start, end, kind, text, context, phase=False):
        self.start, self.end, self.kind, self.text, self.context = start, end, kind, text, context
        self.phase = phase

    def __repr__(self):
        return f'{self.kind}:{self.text}'


MODIFIERS = r'(?:(?:borrowing|consuming|__owned|__shared|sending|inout|isolated)\s+|@escaping\s+|@autoclosure\s+)*'


SCHEMA_DECLARATION = re.compile(r'@StateMachine\([^)]*\)\s*(?:@\w+(?:\([^)]*\))?\s*)*(?:\w+\s+)*enum\s+`?(\w+)`?[^{]*\{')


def schema_declarations(text, mask=None):
    if mask is None:
        mask = code_mask(text)
    return [declaration for marker in re.finditer(r'@StateMachine\(', text)
            if mask[marker.start()] and (declaration := SCHEMA_DECLARATION.match(text, marker.start()))]


def schema_names(text):
    return [m.group(1) for m in schema_declarations(text)]


def schema_bounds(text, mask=None):
    """Each schema declaration and the offset of its closing brace."""
    if mask is None:
        mask = code_mask(text)
    braces = re.compile(r'[{}]')
    for declaration in schema_declarations(text, mask):
        depth, end = 1, len(text)
        for brace in braces.finditer(text, declaration.end()):
            if mask[brace.start()]:
                depth += 1 if brace.group() == '{' else -1
                if depth == 0:
                    end = brace.start()
                    break
        yield declaration, end


def schema_phase_sites(text, mask=None):
    """For each schema body, yield `(start, end, payloads)` mapping each direct phase payload's start offset to its
    core type name."""
    opening = re.compile(r'\w+`?\s*\(')
    for declaration, end in schema_bounds(text, mask):
        start = declaration.end()
        body = text[start:end]
        direct = direct_member_text(body)
        payloads = {start + opening.match(direct, offset).end(): core_name(payload)
                    for _, offset, payload in direct_case_items(body, direct) if payload is not None}
        yield start, end, payloads


def phase_payloads(text):
    return {payload for _, _, sites in schema_phase_sites(text) for payload in sites.values()}


IDENT_TOKEN = r'(?:`[^`\n]+`|[^\W\d]\w*)'
PHASE_SET_ATTR = re.compile(r'@(?:`?StateMachine`?\s*(?:::|\.)\s*)?`?PhaseSet`?(?![\w`])\s*\(')
DECL_STOP_KEYWORDS = {'struct', 'class', 'actor', 'protocol', 'typealias', 'case', 'func', 'var', 'let',
                      'init', 'subscript', 'deinit', 'extension', 'import'}


def parse_phase_set_members(argument_text):
    """Return ordered payload type names from a `@PhaseSet([...])` argument, or None if not a bare `<Type>.self` list."""
    bracketed = re.fullmatch(r'\s*\[\s*(.*?)\s*\]\s*', argument_text, re.S)
    if not bracketed:
        return None
    inner = bracketed.group(1)
    if not inner.strip():
        return []
    members = []
    for item in split_top(inner):
        stripped = item.strip()
        if not stripped:
            continue
        match = re.fullmatch(r'(' + IDENT_TOKEN + r')\s*\.\s*`?self`?', stripped)
        if not match:
            return None
        members.append(match.group(1).strip('`'))
    return members


def phase_sets(direct):
    """Map each direct `@PhaseSet([...])` empty nested enum name in `direct` to its ordered payload type names."""
    sets = {}
    ident = re.compile(IDENT_TOKEN)
    attr = re.compile(r'@' + IDENT_TOKEN + r'(?:\s*(?:::|\.)\s*' + IDENT_TOKEN + r')*')
    for match in PHASE_SET_ATTR.finditer(direct):
        arg_end = scan_type_end(direct, match.end(), '')
        if arg_end >= len(direct) or direct[arg_end] != ')':
            continue
        members = parse_phase_set_members(direct[match.end():arg_end])
        if not members:
            continue
        cursor = arg_end + 1
        enum_name = None
        while cursor < len(direct):
            while cursor < len(direct) and direct[cursor].isspace():
                cursor += 1
            if cursor >= len(direct):
                break
            if direct[cursor] == '@':
                found = attr.match(direct, cursor)
                if not found:
                    break
                cursor = found.end()
                while cursor < len(direct) and direct[cursor].isspace():
                    cursor += 1
                if cursor < len(direct) and direct[cursor] == '(':
                    close = scan_type_end(direct, cursor + 1, '')
                    cursor = close + 1
                continue
            word = ident.match(direct, cursor)
            if not word:
                break
            token = word.group(0)
            cursor = word.end()
            if token == 'enum':
                while cursor < len(direct) and direct[cursor].isspace():
                    cursor += 1
                name_match = ident.match(direct, cursor)
                if name_match and direct[name_match.end():].lstrip()[:1] != '<':
                    enum_name = name_match.group(0).strip('`')
                break
            if token in DECL_STOP_KEYWORDS:
                break
        if enum_name is not None:
            sets[enum_name] = members
    return sets


def phase_set_names(text):
    """All `@PhaseSet` enum names declared directly inside any schema in `text`."""
    mask = code_mask(text)
    names = set()
    for declaration, end in schema_bounds(text, mask):
        names.update(phase_sets(direct_member_text(text[declaration.end():end])))
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
    phase_sites = list(schema_phase_sites(text, mask))
    schemas = [(start, end, set(payloads.values())) for start, end, payloads in phase_sites]
    phases = {offset for _, _, payloads in phase_sites for offset in payloads}

    def add(start, end, kind, context, generic_params=()):
        if end <= start or not mask[start]:
            return
        spelling = text[start:end]
        if re.fullmatch(r'\s*-?\d[\w]*\s*', spelling):
            # An integer argument of a value generic is a value, not a type.
            return
        references_generic = any(re.search(r'(?<![\w.`])' + re.escape(gp) + r'(?![\w`])', spelling) for gp in generic_params)
        phase = kind == 'phase-case'
        if kind in ('param', 'return', 'return-arg'):
            names = next((names for lower, upper, names in reversed(schemas) if lower <= start < upper), ())
            phase = core_name(spelling) in names
        if not references_generic:
            sites.append(Site(start, end, kind, spelling, context, phase))
        # Generic arguments of a nominal spelling are sites of their own.
        head = re.match(r'[\w.`:]+<', spelling)
        if head:
            index = start + head.end()
            while index < end - 1:
                arg_end = scan_type_end(text, index, ',')
                if arg_end > end - 1:
                    break
                lead = len(text[index:arg_end]) - len(text[index:arg_end].lstrip())
                add(index + lead, arg_end, kind + '-arg', context, generic_params)
                index = arg_end
                while index < end and text[index] in ', ':
                    index += 1
                if text[index:index + 1] == '>' or index >= end - 1:
                    break

    for match in re.finditer(r'static func\s+`?\w+`?\s*(?:<([^>]*)>\s*)?\(', text):
        if not mask[match.start()]:
            continue
        generic_params = tuple(
            p.strip().strip('`')
            for raw in (split_top(match.group(1)) if match.group(1) else ())
            for p in [re.sub(r'^each\s+', '', raw.strip()).split(':', 1)[0].strip()]
            if p
        )
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
        # Walk top-level parameters so commas inside tuple types (`(a: Int, b: String)`) stay intact.
        cursor = index
        params_end = depth_end - 1
        while cursor < params_end:
            p_end = scan_type_end(text, cursor, ',')
            if p_end > params_end:
                p_end = params_end
            segment = text[cursor:p_end]
            param = re.match(r'\s*(?:`?\w+`?\s+)?`?\w+`?\s*:\s*' + MODIFIERS, segment)
            if param:
                type_start = cursor + param.end()
                type_end = scan_type_end(text, type_start, ',=')
                if type_end > p_end:
                    type_end = p_end
                add(type_start, type_end, 'param', context, generic_params)
            cursor = p_end + 1
        rest = depth_end
        throws = re.match(r'\s*(?:async\s+)?throws\(', text[rest:])
        if throws:
            type_start = rest + throws.end()
            type_end = scan_type_end(text, type_start, '')
            add(type_start, type_end, 'throws', context, generic_params)
            rest = type_end + 1
        arrow = re.match(r'\s*(?:throws\s*)?->\s*', text[rest:])
        if arrow:
            type_start = rest + arrow.end()
            type_end = scan_type_end(text, type_start, '{\n')
            # A trailing `where` clause ends the return type spelling before `{`.
            where_match = re.search(r'\s+where\b', text[type_start:type_end])
            if where_match:
                type_end = type_start + where_match.start()
            add(type_start, type_end, 'return', context, generic_params)
    for match in re.finditer(r'typealias\s+`?\w+`?(?:<[^>=]*>)?\s*=\s*', text):
        type_end = scan_type_end(text, match.end(), ';\n')
        indent = text.rfind('\n', 0, match.start())
        nested = text[indent + 1:match.start()].startswith('        ') or text[indent + 1:match.start()].lstrip().startswith(('enum', '@'))
        add(match.end(), type_end, 'alias', 'nested' if nested else ('file' if text[indent + 1:match.start()] == '' else 'schema'))
    for start in phases:
        add(start, scan_type_end(text, start, ',='), 'phase-case', 'case')
    for match in re.finditer(r'\bcase\s+`?\w+`?\(', text):
        if mask[match.start()] and match.end() not in phases:
            add(match.end(), scan_type_end(text, match.end(), ',='), 'case', 'case')
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


def site_role(site):
    """`phase` for a phase payload, `shape` for the result shape of an edge (its `Change`, `Advance`, or router choice
    and what they name), else `value`."""
    if site.phase:
        return 'phase'
    if site.context == 'edge' and (site.kind == 'return-arg' or (site.kind == 'return' and re.match(r'\s*(Self\.|\w+\.)?(Route|Change|Advance)\b', site.text))):
        return 'shape'
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
        results.append((new, dict(site=repr(site), role=site_role(site))))
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


def enclosing_namespace(text, site_start):
    """If `site_start` lies inside a direct nested `enum` or `struct` namespace of its schema, return `(schema, name)`."""
    schema = schema_of(text, site_start)
    if not schema:
        return None, None
    for namespace in re.finditer(r'^    (?:@[\w.:`]+(?:\([^)\n]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private)\s+)*(?:enum|struct)\s+`?(\w+)`?[^{\n]*\{', text, re.M):
        body = body_of(text, namespace)
        if namespace.end() <= site_start < namespace.end() + len(body):
            return schema, namespace.group(1)
    return schema, None


def direct_schema_types(text, schema):
    """Types declared directly inside `schema`'s body (excluding types declared only inside nested namespaces)."""
    body = schema_body(text, schema)
    if body is None:
        return set()
    return declared_types(direct_member_text(body))


@rewrite('self-qualify', 'eq', 'may be written `Draft`, `Self.Draft`, or `Approval.Draft`')
def _(text, rng):
    def transform(site):
        if not is_simple_name(site.text) or site.context in ('nested',):
            return None
        schema, namespace = enclosing_namespace(text, site.start)
        if not schema or namespace is not None:
            return None
        if core_name(site.text) not in direct_schema_types(text, schema):
            return None
        return 'Self.' + site.text.strip()
    return at_sites(text, lambda s: within_schema(text, s) and s.kind != 'case', transform)


@rewrite('schema-qualify', 'eq', 'may be written `Draft`, `Self.Draft`, or `Approval.Draft`')
def _(text, rng):
    def transform(site):
        if not is_simple_name(site.text):
            return None
        schema, namespace = enclosing_namespace(text, site.start)
        if not schema:
            return None
        name = core_name(site.text)
        # Inside a nested namespace such as `Input` or an `@Operation`, a bare name that the namespace declares
        # (including via an extension) resolves to that namespace's member, not the outer schema's type of that name.
        if namespace is not None and name in scope_members(text, schema, namespace):
            return f'{schema}.{namespace}.{site.text.strip()}'
        if name not in direct_schema_types(text, schema):
            return None
        return f'{schema}.{site.text.strip()}'
    return at_sites(text, lambda s: within_schema(text, s), transform)


def generic_bindings(text):
    """Spans `(start, end, names)` where generic parameters `names` are in scope."""
    mask = code_mask(text)
    bindings = []
    for declaration in re.finditer(r'\b(typealias|enum|struct|class|actor|func)\s+`?\w+`?\s*<', text):
        if not mask[declaration.start()]:
            continue
        parameters_end = scan_type_end(text, declaration.end(), '')
        if parameters_end >= len(text) or text[parameters_end] != '>':
            continue
        parameters = {name.group(1) for parameter in split_top(text[declaration.end():parameters_end])
                      if (name := re.match(r'\s*(?:(?:let|each)\s+)?`?(\w+)', parameter))}
        if not parameters:
            continue
        kind = declaration.group(1)
        if kind == 'typealias':
            equals = re.match(r'\s*=\s*', text[parameters_end + 1:])
            if equals:
                start = parameters_end + 1 + equals.end()
                bindings.append((start, scan_type_end(text, start, ';\n'), parameters))
        elif kind == 'func':
            start = parameters_end + 1
            depth, cursor = 0, start
            while cursor < len(text):
                if mask[cursor]:
                    ch = text[cursor]
                    if ch in '([{':
                        if ch == '{' and depth == 0:
                            break
                        depth += 1
                    elif ch in ')]}':
                        depth = max(0, depth - 1)
                cursor += 1
            if cursor < len(text) and text[cursor] == '{':
                body = body_of(text, re.compile(r'\{').match(text, cursor))
                bindings.append((start, cursor + 1 + len(body), parameters))
            else:
                bindings.append((start, scan_type_end(text, start, ';\n'), parameters))
        else:
            opening = re.match(r'[^{};]*\{', text[parameters_end + 1:])
            if opening:
                brace_at = parameters_end + 1 + opening.end() - 1
                bindings.append((parameters_end + 1, brace_at + 1 + len(body_of(text, re.compile(r'\{').match(text, brace_at))), parameters))
    return bindings


def alias_rewrite(text, make, predicate=lambda s: True, phases=False, hoists=True):
    """Mutations that spell one site through an alias. A phase payload spelled through an alias is a documented limit,
    so only `alias-local` tries those sites."""
    results = []
    bindings = generic_bindings(text) if hoists else []
    for site in type_sites(text):
        if not within_schema(text, site) or not predicate(site) or not not_generated(site):
            continue
        if not phases and site_role(site) == 'phase':
            continue
        if hoists and bindings:
            roots = {root.group(0).strip('`') for root in type_lookup_roots(site.text)}
            if any(start <= site.start < end and roots & names for start, end, names in bindings):
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
                # A `make` that already spelled the site through its namespace (`alias-file`) needs no second pass.
                already = f'{schema}.{qualified}' in declaration or (scope == 'schema' and qualified in declaration)
                if qualified != site.text and not already:
                    declaration = declaration.replace(site.text, qualified if scope == 'schema' else f'{schema}.{qualified}')
        # A helper that a public or package schema's spelling names needs that access too, or the rewrite is no
        # longer the same program — unless the aliased type itself is `fileprivate` or `private` (e.g. a `fileprivate`
        # `routed:` payload inside a public schema).
        access = re.search(r'\b(public|package)\s+(?:\w+\s+)*enum\s+`?' + re.escape(schema) + r'\b', text) if schema else None
        restricted = set(re.findall(r'\b(?:fileprivate|private)\s+(?:struct|enum|class|protocol|typealias)\s+`?(\w+)`?', text))
        uses_restricted = any(re.search(r'(?<![\w.`])' + re.escape(name) + r'(?![\w`])', site.text) for name in restricted)
        if uses_restricted:
            if scope == 'file':
                continue
            declaration = re.sub(r'(^\s*|\{\s*|;\s*)(typealias|enum|struct)\b', lambda m: f'{m.group(1)}fileprivate {m.group(2)}',
                                 declaration, flags=re.M)
        elif access:
            declaration = re.sub(r'(^\s*|\{\s*|;\s*)(typealias|enum|struct)\b', lambda m: f'{m.group(1)}{access.group(1)} {m.group(2)}',
                                 declaration, flags=re.M)
        new = text[:site.start] + spelling + text[site.end:]
        new = insert_in_schema(new, declaration, site.start) if scope == 'schema' else insert_at_file_scope(new, declaration)
        if new:
            results.append((new, dict(site=repr(site), role=site_role(site))))
    return results


def type_lookup_roots(spelling):
    """Matches for unqualified root identifiers in a type spelling, excluding tuple labels, member names, and module
    selectors."""
    code = ''.join(char if visible else ' ' for char, visible in zip(spelling, code_mask(spelling)))
    delimiters = []
    for match in re.finditer(r'->|[()[\]<>]|`[^`]+`|[^\W\d]\w*', code):
        token = match.group(0)
        if token in ('(', '[', '<'):
            delimiters.append(token)
        elif token in (')', ']', '>'):
            if delimiters:
                delimiters.pop()
        elif token != '->':
            before, after = code[:match.start()].rstrip(), code[match.end():].lstrip()
            tuple_label = (delimiters[-1:] == ['('] and before.endswith(('(', ','))
                           and after.startswith(':') and not after.startswith('::'))
            if not tuple_label and not before.endswith(('.', '::')) and not after.startswith('::'):
                yield match


def qualify_for_file_scope(text, site):
    line = text.count('\n', 0, site.start) + 1
    scope = next(((a, b, path) for (a, b), path in zip(schema_lines(text), schema_path_list(text))
                  if a <= line <= b), None)
    if scope is None:
        return site.text
    start, end, path = scope
    schema = path.rsplit('.', 1)[-1]
    body = '\n'.join(text.split('\n')[start:end - 1])
    members = declared_types(body) | set(re.findall(r'typealias\s+`?(\w+)', body))

    pieces, last = [], 0
    for match in type_lookup_roots(site.text):
        name = match.group(0).strip('`')
        if name in ('Self', schema):
            qualified = path
        elif name in members and name not in STANDARD:
            qualified = f'{path}.{match.group(0)}'
        else:
            continue
        pieces.extend((site.text[last:match.start()], qualified))
        last = match.end()
    return ''.join(pieces) + site.text[last:]


@rewrite('alias-local', 'eq', 'With `typealias Unit = Void` in the schema')
def _(text, rng):
    return alias_rewrite(text, lambda t, s: ('FuzzAlias', f'typealias FuzzAlias = {s.text}', 'schema'), phases=True)


@rewrite('alias-generic', 'eq', 'A generic alias the schema declares reads with its arguments')
def _(text, rng):
    return alias_rewrite(text, lambda t, s: (f'FuzzIdentity<{s.text}>', 'typealias FuzzIdentity<FuzzT: ~Copyable> = FuzzT', 'schema'), hoists=False)


@rewrite('alias-chain', 'eq', 'An alias chain of any length reads through to the type it names')
def _(text, rng):
    return alias_rewrite(text, lambda t, s: ('FuzzChain0', f'typealias FuzzChain0 = FuzzChain1\n    typealias FuzzChain1 = FuzzChain2\n    typealias FuzzChain2 = {s.text}', 'schema'))


@rewrite('alias-nested', 'eq', 'inside the nongeneric types the schema declares')
def _(text, rng):
    def make(t, s):
        rhs = s.text
        schema, namespace = enclosing_namespace(t, s.start)
        # Inside `enum FuzzSpace`, `Self` names `FuzzSpace`, not the enclosing schema. When `s` stands at schema
        # scope (not inside a nested namespace whose `Self.` `alias_rewrite` qualifies to that namespace), rewrite
        # root `Self` to the schema's name so the nested alias keeps Swift's original type lookup.
        if schema and namespace is None:
            rhs = re.sub(r'(?<![\w.`])Self(?=\s*\.|\s*\)\s*\.)', schema, rhs)
        alias_name = 'FuzzTarget' if re.search(r'(?<![\w`])Alias(?![\w`])', rhs) else 'Alias'
        return (f'FuzzSpace.{alias_name}', f'enum FuzzSpace {{ typealias {alias_name} = {rhs} }}', 'schema')
    return alias_rewrite(text, make)


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
    match = re.fullmatch(r'\[([^\[\]]+)\]', stripped)
    if match:
        element = match.group(1).strip()
        syntax = ''.join(c if present else ' ' for c, present in zip(element, code_mask(element)))
        syntax = re.sub(r'`[^`]*`|::', lambda m: '_' * len(m.group()), syntax)
        if re.search(r'\sof\s', syntax):
            return None
        end = scan_type_end(syntax, 0, ':')
        if not syntax[end:].strip():
            return f'Array<{element}>'
        if syntax[end:].lstrip().startswith(':'):
            colon = syntax.index(':', end)
            return f'Dictionary<{element[:colon].strip()}, {element[colon + 1:].strip()}>'
        return None
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
    for match in re.finditer(r'@(Transition|Route|Operation|Restoration|Active|StateMachine|PhaseSet)\(([^()\n]*(?:\([^()\n]*\)[^()\n]*)*)\)', text):
        arguments = match.group(2)
        spaced = re.sub(r':\s*', ': /* fuzz */ ', arguments).replace(', ', ' /* fuzz */ ,\n        ')
        new = text[:match.start(2)] + '\n        ' + spaced + '\n    ' + text[match.end(2):]
        results.append((new, dict(site=match.group(0), role='attribute')))
    return results


@rewrite('module-attribute', 'eq', 'An attribute may include its module name, as in `@StateMachine.Transition`')
def _(text, rng):
    results = []
    for match in re.finditer(r'@(Transition|Route|Operation|Restoration|Active|Initial|Terminal|Event|PhaseSet)\b', text):
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
        if top and (stripped.startswith((')', '}', ']', 'where ')) or stripped.startswith('->')):
            # A schema nested in another declaration has no member at this indentation.
            if current is not None:
                current.append(line)
        elif top and (stripped.startswith('//') or re.fullmatch(r'@[\w.:`]+(\(.*\))?', stripped)):
            pending.append(line)
        elif top and re.match(r'@[\w.:`]+\(', stripped) and stripped.count('(') > stripped.count(')'):
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
    '''Reverses the list an attribute argument spells, as `starts: [A.self, B.self]` or `@PhaseSet([A.self, B.self])`.'''
    results = []
    mask = code_mask(text)
    for match in re.finditer(r'\b(starts|emits|cancels|invalidates|requires|activeIn|allows|only|from|in):\s*\[([^\[\]]+)\]', text):
        if not mask[match.start()]:
            continue
        items = [i.strip() for i in match.group(2).split(',') if i.strip()]
        if len(items) < 2:
            continue
        new = text[:match.start(2)] + ', '.join(reversed(items)) + text[match.end(2):]
        results.append((new, dict(site=f'{match.group(1)} reversed', role='value')))
    for match in re.finditer(r'@(?:`?StateMachine`?\s*(?:::|\.)\s*)?`?PhaseSet`?\s*\(\s*\[([^\[\]]+)\]\s*\)', text):
        if not mask[match.start()]:
            continue
        items = [i.strip() for i in match.group(1).split(',') if i.strip()]
        if len(items) < 2:
            continue
        new = text[:match.start(1)] + ', '.join(reversed(items)) + text[match.end(1):]
        results.append((new, dict(site='PhaseSet reversed', role='value')))
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
        if first != source or (source and site_role(site) != 'phase'):
            continue
        before = text[:site.start]
        if not source and re.search(r'(?<![\w`])`?routed`?\s+`?\w+`?\s*:\s*' + MODIFIERS + r'$', before):
            # Adding ownership to a `routed:` parameter intentionally marks `Route.<Router>` `~Copyable` (covered by
            # `routed-convention`), so `shared-param` targets trigger/request payloads.
            continue
        if re.search(r'(borrowing|consuming|__owned|__shared|sending|@escaping|inout)\s+$', before):
            continue
        new = before + '__shared ' + text[site.start:]
        results.append((new, dict(site=repr(site), role=site_role(site))))
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
        # A static property named like the schema shadows the schema type in expression position (`Hold.Idle()`).
        shadowed_value = schema and re.search(r'\bstatic\s+(?:let|var)\s+`?' + re.escape(schema) + r'`?(?![\w`])', text)
        candidates = (f'Self.{callee}', callee) if shadowed_value else (f'Self.{callee}', f'{schema}.{callee}', callee)
        for new_call in candidates:
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
    """Renames the identifier `old` everywhere outside comments, string literals, module selectors, and built-in attributes."""
    mask = code_mask(text)
    pieces, last = [], 0
    for match in re.finditer(r'(?<![\w`])(`?)' + re.escape(old) + r'\1(?![\w`])', text):
        if not mask[match.start()]:
            continue
        before = text[:match.start()].rstrip()
        if before.endswith('::') or (before.endswith('@') and old in STANDARD):
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
    operations = set(re.findall(r'@(?:StateMachine(?:::|\.))?(?:Operation|Event)\b[^\n]*\n\s*(?:\w+\s+)*enum\s+`?(\w+)', text))
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
        if name not in seen and not name.startswith(('Fuzz', 'fuzz', '_')):
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
    excluded = phase_payloads(text) | phase_set_names(text)
    for kind, name in renamable(text):
        if kind not in ('type', 'alias') or name in excluded:
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
    # A phase case's whole payload, a plain name, with its default: the default goes with the payload, so the
    # program stays valid Swift and only the graph is refused.
    phase_case = r'^(    (?:@[\w.]+\s+)*case\s+\w+\()([A-Za-z_]\w*)(\s*=\s*[\w.]+(?:\([^()\n]*\))?)?(?=\))'
    payloads = [m.group(2) for m in re.finditer(phase_case, text, re.M)]
    access = re.search(r'^\s*(public|package)\s+(?:\w+\s+)*enum\s+\w+', text, re.M)
    for number, name in enumerate(payloads):
        for flavor in ('nfd', 'fresh'):
            base, alias = text, 'FuzzPhase'
            if flavor == 'nfd':
                # The struct spelled with a precomposed letter; the alias the case names with a combining mark.
                base = rename(text, name, name + '\u00e9')
                alias = name + 'e\u0301'
            line = list(re.finditer(phase_case, base, re.M))[number]
            new = base[:line.start(2)] + alias + base[line.end(3) if line.group(3) else line.end(2):]
            new = insert_in_schema(new, f'{access.group(1) + " " if access else ""}typealias {alias} = Swift.Int')
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
        phase = re.search(r'case\s+`?(\w+)', line)
        refusal = (rf"Phase '{re.escape(phase.group(1))}' has no outgoing transitions; mark it '@Terminal' or declare a transition from it\."
                   if phase else None)
        results.append((text[:match.start()] + text[match.end():], dict(site='remove @Terminal', role='value', refusal=refusal)))
    for match in re.finditer(r'^    @Initial\s+case(?=\s+`?(\w+))', text, re.M):
        if '@Terminal' in text[match.start():text.find('\n', match.start())]:
            continue
        refusal = (rf"Terminal phase '{re.escape(match.group(1))}' cannot have an outgoing (transition|router) '[^']*'; "
                   r"remove '@Terminal', or remove the (transition|router)\.|"
                   rf"Terminal phase '{re.escape(match.group(1))}' in @PhaseSet '[^']*' cannot have an outgoing transition '[^']*'; "
                   r"remove '@Terminal', remove '[^']*\.self' from '[^']*', or remove the transition\.|"
                   rf"Operation '[^']*' cannot be active in terminal phase '{re.escape(match.group(1))}'(, because its scope '[^']*' spans every phase)?; "
                   r"remove [^ ]+\.self from the phases where it is active, or remove '@Terminal'\.")
        results.append((text[:match.start()] + '    @Initial @Terminal case' + text[match.end():],
                        dict(site='add @Terminal to initial', role='value', refusal=refusal)))

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
            # A leading + keeps the parameter's own modifiers and adds the rest, unless they already hold it.
            if spelling.startswith('+') and modifiers and spelling[1:].strip() in modifiers.group(0):
                continue
            new = (before + spelling[1:] if spelling.startswith('+') else head + spelling) + text[site.start:]
            results.append((new, dict(site=f'{spelling.strip()} {site.text}', role='value')))
    return results



# --- Where the macro derives a name or decides a role ------------------------------------------------------------------

def authored_functions_at(text):
    """Each static function an attribute marks: (attribute, name, index of its name, index after its parameters, the
    text between the parameters and `{`, plus optional generic clause and `from:`/`routed:` metadata)."""
    found = []
    pattern = (r'@(?:StateMachine(?:::|\.))?(Transition|Route|Restoration)\b[^\n]*\n'
               r'(?:\s*@[^\n]*\n)*'
               r'\s*((?:\w+\s+)*)static func\s+`?(\w+)`?\s*(?:(<[^>]*>)\s*)?\(')
    for match in re.finditer(pattern, text):
        depth, index = 1, match.end()
        while depth and index < len(text):
            depth += {'(': 1, ')': -1}.get(text[index], 0)
            index += 1
        brace = text.find('{', index)
        attr_text = text[match.start():match.start(2)]
        params_text = text[match.end():index - 1]
        found.append(dict(attribute=match.group(1), attribute_at=match.start(), modifiers=match.group(2), name=match.group(3), name_at=match.start(3),
                          func_at=text.rfind('static func', 0, match.start(3)), after=index, effects=text[index:brace],
                          generic=match.group(4), generic_at=match.start(4) if match.group(4) else None,
                          generic_end=match.end(4) if match.group(4) else None,
                          params_start=match.end(), params_end=index - 1,
                          has_from=bool(re.search(r'(?<![\w`])`?from`?\s*:', attr_text)),
                          has_routed=bool(re.search(r'(?:^|,)\s*`?routed`?\s+`?\w+`?\s*:', params_text))))
    return found


GENERATED_NAMES = ['Owned', 'Observed', 'Snapshot', 'Prepared', 'Effect', 'Route', 'Change', 'Advance', 'Phase', 'Local',
                   'Shared', 'ActorHost', 'MainActorHost', 'IsolatedHost', 'PreparationRejection', 'Restoration',
                   'Completion', 'PendingCompletion', 'Configuration', 'CompletionPolicy', 'Outcome', 'Rejection',
                   '_StateMachineSchema', '_StateMachineGraph', '_StateMachineEngine', '_StateMachineScopeID', '_StateMachineKey']


@rewrite('reserved-member', 'eq', 'Generated member names are reserved')
def _(text, rng):
    """An unused member named as something the macro generates for this schema, or for another one. An owner type the
    schema does not select is not reserved, so `unreserved-owner` declares those, where no allowance applies."""
    names = [n for n in GENERATED_NAMES if n not in unselected_owner_types(text)]
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


def unselected_owner_types(text):
    """The owner types the first schema does not select, which the guide lets it declare for itself."""
    owners = selected_owners(text)
    return [] if not owners else [t for t in OWNER_TYPES.values() if t not in owners[0][1]]


@rewrite('unreserved-owner', 'eq', 'A schema that lists only `.local` may declare its own type named `Shared`')
def _(text, rng):
    """An unused member named like an owner type the schema does not select: which names are reserved depends on what
    the schema generates, so the case compiles as the seed does."""
    results = []
    for name in unselected_owner_types(text):
        if name in identifier_tokens(text):
            continue
        new = insert_in_schema(text, f'struct {name}: Sendable {{}}')
        if new:
            results.append((new, dict(site=f'struct {name}', role='value', added=[rf'^(static )?Fz\.(\w+\.)*{name}\.'])))
    return results


OWNER_VERBS = ['send', 'commit', 'deliver', 'snapshot', 'observe', 'reset', 'withValue', 'takeValue', 'value', 'revision',
               'consume', 'cancel', 'reconcile', 'discardPending', 'shutdown', 'graph', 'effect', 'owned', 'restore']


@rewrite('verb-edge-name', 'dist', 'an edge or router may share one with a member of the phase wrappers, unless its generated method would redeclare that member')
def _(text, rng):
    """An edge or router renamed as an owner's or wrapper's verb, with the effect and choice types named after it."""
    results = []
    tokens = identifier_tokens(text)
    # An edge named as an operation's or event's effect case shares that case's spelling; renaming one renames both.
    effect_cases = {n[0].lower() + n[1:] for n in re.findall(r'@(?:StateMachine(?:::|\.))?(?:Operation|Event)\b[^\n]*\n\s*(?:\w+\s+)*enum\s+`?(\w+)', text)}
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
            # A deprecation `renamed: "<old>"` names the replacement edge inside a string literal.
            variant = re.sub(r'(\brenamed\s*:\s*")' + re.escape(old) + r'"', lambda m: f'{m.group(1)}{verb}"', variant)
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
    return next((span for span, name, path in zip(schema_lines(text), schema_names(text), schema_path_list(text))
                 if path == name), None)


def nest_schema(text, opener, closer, prefix, extra=''):
    """Wraps the first schema in `opener \u2026 closer` and names it `prefix.<Schema>` outside its body."""
    span = schema_span(text)
    if not span or '// fuzz-outer:' in text or 'fuzzLocalSchema' in text:
        return None
    lines = text.split('\n')
    start, end = span[0] - 1, span[1] - 1
    schema = schema_names('\n'.join(lines[start:end + 1]))[0]
    outside = '\n'.join(lines[:start]), '\n'.join(lines[end + 1:])
    def qualify(chunk):
        mask = code_mask(chunk)
        name = r'(?<![\w`])(?:`' + re.escape(schema) + r'`|' + re.escape(schema) + r')(?![\w`])'
        declarations = {m.start(1) for m in re.finditer(
            r'\b(?:struct|enum|class|actor|protocol|typealias|func|case|var|let)\s+(' + name + ')', chunk)}

        def replace(match):
            at = match.start()
            before = chunk[:at].rstrip()
            if mask[at] and at not in declarations and not before.endswith(('.', '::')):
                # An existing extension must remain visible to the schema inside a generic enclosing type.
                # Specialize references from ordinary code, but keep the extension itself unspecialized.
                enclosing = prefix.partition('<')[0] if re.search(r'\bextension$', before) else prefix
                return f'{enclosing}.{match.group(0)}'
            return match.group(0)

        return re.sub(name, replace, chunk)

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
    param = fresh_identifier(text, 'FuzzOuterT')
    nested = nest_schema(text, f'nonisolated enum FuzzOuter<{param}> {{', '}', 'FuzzOuter<Int>')
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
        # Multi-source `from:` transitions support a single generic `<Source>` parameter (covered by
        # `generic-source-invalid`); single-source transitions, routers, and restorations remain nongeneric.
        if function['generic'] or function['has_from']:
            continue
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
    taken = identifier_tokens(text)
    helper = 'FuzzNotes'
    suffix = 2
    while helper in taken:
        helper = f'FuzzNotes{suffix}'
        suffix += 1
    names = [n for n in public_types(text) if n not in ('Input', 'Scope') and n not in schema_names(text)] or sorted(phase_payloads(text))
    for name in names[:4]:
        for declaration in (f'private enum {helper} {{ struct {name} {{}} }}', f'private struct {helper} {{ typealias {name} = Swift::Int }}'):
            new = insert_in_schema(text, declaration)
            if new:
                results.append((new, dict(site=declaration, role='value', added=[rf'Fz\.(\w+\.)*{helper}\b'])))
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
            # A public or package schema's payload names the alias, which needs that access too.
            access = re.search(r'\b(public|package)\s+(?:\w+\s+)*enum\s+`?' + re.escape(schema) + r'\b', text)
            prefix = f'{access.group(1)} ' if access else ''
            new = append_to_module(new, f'extension {path}.Input {{\n    {prefix}typealias FuzzMoved = {spelled}\n}}')
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


@rewrite('split-payload', 'eq', 'on one line without comments')
def _(text, rng):
    """A phase case's payload continued on the next line, and a comment between the case name and its payload: the
    export joins the payload onto one line without the comment."""
    results = []
    for match in list(re.finditer(r'^(    (?:@[\w.]+(?:\([^)\n]*\))?\s+)*case\s+`?\w+`?\()(\w+)', text, re.M))[:2]:
        split = text[:match.end(1)] + '\n        ' + text[match.start(2):]
        results.append((split, dict(site=f'payload {match.group(2)} on its own line', role='phase')))
        commented = text[:match.end(1)] + '/* decoy ) */ ' + text[match.start(2):]
        results.append((commented, dict(site=f'comment before payload {match.group(2)}', role='phase')))
    return results


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
            results.append((variant, dict(site=f'phase {case} -> {word}', role='value', control=text, mapping={case: word})))
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


def universal_availability(text):
    """Each `@available(*, …)`: the span of its options after `*,` and the options, as written."""
    found = []
    for match in re.finditer(r'@available\(\s*\*\s*,', text):
        depth, index, quoted = 1, match.end(), False
        while index < len(text) and depth:
            char = text[index]
            if char == '"' and text[index - 1] != '\\':
                quoted = not quoted
            elif not quoted:
                depth += {'(': 1, ')': -1}.get(char, 0)
            index += 1
        options = [o.strip() for o in split_top(text[match.end():index - 1])]
        found.append((match.end(), index - 1, options))
    return found


@rewrite('permute-availability', 'eq', '`@available(*, deprecated)` with at most one `message:` and one `renamed:`')
def _(text, rng):
    """The options of a universal deprecation in another order, which Swift reads as the same attribute."""
    results = []
    for start, end, options in universal_availability(text):
        for order in itertools.permutations(options):
            if list(order) == options:
                continue
            new = text[:start] + ' ' + ', '.join(order) + text[end:]
            results.append((new, dict(site=f"@available(*, {', '.join(order)})", role='value')))
    return results


@rewrite('qualify-renamed', 'break', 'the bare name of another edge, or of another router')
def _(text, rng):
    """A deprecation's replacement spelled qualified or with argument labels: the generated methods repeat the
    deprecation as written, where such a name means nothing, so the macro must refuse it at the string."""
    results = []
    schema = (schema_names(text) or ['Schema'])[0]
    for match in re.finditer(r'renamed:\s*"(\w+)"', text):
        name = match.group(1)
        for spelling in (f'{schema}.{name}', f'{name}(_:)', f'{schema}.{name}(_:)', f'Self.{name}'):
            new = text[:match.start(1)] + spelling + text[match.end(1):]
            results.append((new, dict(site=f'renamed: "{spelling}"', role='value', keep_client=True)))
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
        new = text[:marker + 1] + '    #if true\n    @inline(__always)\n    #endif\n' + text[marker + 1:]
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
        results.append((repeated, dict(site=f'{site.text} with {members[0]} twice', role=site_role(site))))
        aliased = text[:site.start] + prefix + ' & '.join(['FuzzPair'] + members[2:]) + text[site.end:]
        aliased = insert_in_schema(aliased, f'typealias FuzzPair = {members[0]} & {members[1]}', site.start)
        results.append((aliased, dict(site=f'{site.text} through FuzzPair', role=site_role(site))))
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


def phase_of_type(text, payload, span=None):
    """The phase case name whose payload's core type is `payload` (handling `Self.`, schema qualification,
    parentheses, comments, backticks, and nested schemas)."""
    mask = code_mask(text)
    for declaration, end in schema_bounds(text, mask):
        if span is not None:
            start_line = text.count('\n', 0, declaration.start()) + 1
            end_line = text.count('\n', 0, end) + 1
            if (start_line, end_line) != span:
                continue
        body = text[declaration.end():end]
        for case_name, _, spelled in direct_case_items(body):
            if spelled is not None and core_name(spelled) == payload:
                return case_name
    return None


def starts_eligible(attribute, schema, destination):
    """Whether literal `@Transition`, `@Operation`, and `Scope` metadata confirm every started operation is active
    in `destination`. Returns `True` when nothing is started and `False` when eligibility cannot be confirmed."""
    metatype = r'`?(\w+)`?\s*\.\s*`?self`?'
    scope_name = r'`?Scope`?\s*\.\s*`?(\w+)`?'

    def arguments(attribute):
        return {key.strip().strip('`'): value.strip() for item in split_top(attribute)
                for key, separator, value in [item.partition(':')] if separator}

    def code(source):
        return ''.join(char if visible or char == '\n' else ' ' for char, visible in zip(source, code_mask(source)))

    def references(value, pattern):
        if not re.fullmatch(r'\[[^\[\]]*\]', value):
            return None
        matches = [re.fullmatch(pattern, item.strip()) for item in split_top(value[1:-1]) if item.strip()]
        return [match[1] for match in matches] if all(matches) else None

    head = re.match(r'@(?:StateMachine\.)?Transition\s*\((.*)\)', code(attribute))
    if not head:
        return False
    starts = references(arguments(head[1]).get('starts', '[]'), metatype)
    if not starts:
        return starts == []

    schema = code(schema)
    scope_enum = re.search(r'^    (?:\w+\s+)*enum\s+`?Scope`?\s*(?::[^{]*)?\{', schema, re.M)
    scopes = body_of(schema, scope_enum) if scope_enum else ''

    def scope_allows(name):
        if not scopes:
            return False
        if not re.search(r'\bActive\b', scopes):
            return True
        active = re.search(r'@(?:StateMachine\.)?`?Active`?\(\s*`?in`?\s*:\s*(\[[^\]]*\])\s*\)\s*case\s+`?'
                           + re.escape(name) + r'`?(?!\w)', scopes)
        return bool(active and destination in (references(active[1], metatype) or []))

    for start in starts:
        declarations = re.findall(r'^    @(?:StateMachine\.)?`?Operation`?\(([^\n]*)\)\s*(?:\w+\s+)*enum\s+`?'
                                  + re.escape(start) + r'`?(?!\w)', schema, re.M)
        if len(declarations) != 1:
            return False
        metadata = arguments(declarations[0])
        needed = references(metadata.get('requires', '[]'), scope_name)
        primary = re.fullmatch(scope_name, metadata.get('scope', ''))
        if primary:
            needed = [primary[1]] + needed if needed is not None else None
        elif destination not in (references(metadata.get('activeIn', ''), metatype) or []):
            return False
        if needed is None or not all(scope_allows(scope) for scope in needed):
            return False
    return True


@rewrite('redirect-entrance', 'break', 'every phase must be reachable from the initial phase')
def _(text, rng):
    """The sole transition into a phase leads to another phase instead; the body becomes `fatalError()`."""
    if '@Restoration' in text:
        return []
    results = []
    destinations = edge_destinations(text)
    initial_payloads = set()
    for declaration, end in schema_bounds(text):
        body = text[declaration.end():end]
        direct = direct_member_text(body)
        for init_match in re.finditer(r'@(?:StateMachine(?:::|\.))?Initial\b[^\n]*?\bcase\s+`?\w+`?\s*\(', direct):
            p_end = scan_type_end(body, init_match.end(), ',=')
            initial_payloads.add(core_name(strip_comments(body[init_match.end():p_end])))
    lines = text.split('\n')
    spans = [(a, b) for a, b in schema_lines(text)]
    schema_at = lambda index: next((s for s in spans if s[0] <= text.count('\n', 0, index) + 1 <= s[1]), None)
    for function, destination, (start, end) in destinations:
        if sum(1 for _, d, _ in destinations if d == destination) != 1 or destination in initial_payloads:
            continue
        span = schema_at(function['func_at'])
        schema = '\n'.join(lines[span[0] - 1:span[1]]) if span else ''
        attribute = text[function['attribute_at']:function['func_at']]
        # A changed destination can make an operation's start ineligible before the graph is checked.
        other = next((d for f, d, _ in destinations if d != destination and schema_at(f['func_at']) == span
                      and starts_eligible(attribute, schema, d)), None)
        if other is None:
            continue
        brace = text.find('{', function['after'])
        body = body_of(text, re.compile(r'\{').match(text, brace))
        new = text[:start] + other + text[end:brace] + '{ fatalError() }' + text[brace + len(body) + 2:]
        lost = phase_of_type(text, destination, span)
        refusal = (rf"Phase '{re.escape(lost)}' is unreachable from the initial phase '[^']*'( or a phase @Restoration can restore)?; "
                   r"declare a transition into it, or remove it\." if lost else None)
        results.append((new, dict(site=f'{function["name"]} into {other} instead of {destination}', role='value', refusal=refusal)))
    return results


def route_blocks(text):
    """Each router: (start of its attribute line, end of its body, name)."""
    found = []
    for match in re.finditer(r'^    @(?:StateMachine(?:::|\.))?Route\([^\n]*\)\s*\n\s*(?:\w+\s+)*static func\s+`?(\w+)`?', text, re.M):
        brace = text.find('{', match.end())
        body = body_of(text, re.compile(r'\{').match(text, brace))
        found.append((match.start(), brace + len(body) + 2, match.group(1)))
    return found


@rewrite('router-delete', 'break', 'declare exactly one @Route when multiple edges match')
def _(text, rng):
    """The only router for two matching candidates removed."""
    # Only a router that chooses among candidates; one that only rejects leaves a valid graph when removed.
    results = []
    for start, end, name in route_blocks(text):
        head = text[start:end].split('{')[0]
        if not re.search(r'->\s*(Self\.)?Route\.', head):
            continue
        source = re.search(r'\(\s*_\s+\w+:\s*(?:borrowing\s+|consuming\s+)?(\w+)', head)
        phase = phase_of_type(text, source.group(1)) if source else None
        # The finding names the source by its payload type or its case.
        names = '|'.join(re.escape(n) for n in ([source.group(1)] if source else []) + ([phase] if phase else []))
        trig = re.search(r'(on|onSuccess|onFailure)\s*:\s*([\w.]+)', head)
        has_routed_candidate = trig and any(
            f['attribute'] == 'Transition' and f['has_routed']
            and re.search(rf'{trig.group(1)}\s*:\s*{re.escape(trig.group(2))}', text[f['attribute_at']:f['func_at']])
            for f in authored_functions_at(text)
        )
        refusal = (rf"(?:Ambiguous routing from '({names})' for .*; declare exactly one @Route when multiple edges match\.|"
                   rf"Transition '[^']*' takes a routed: parameter, but no @Route selects it from '({names})'(?:; every source phase in from: must be routed, or remove routed:)?\.)"
                   if names else None)
        token = r'routed' if has_routed_candidate else None
        results.append((text[:start] + text[end + 1:], dict(site=f'router {name} removed', role='value', refusal=refusal, token=token)))
    return results


@rewrite('router-duplicate', 'break', 'declare exactly one @Route when multiple edges match')
def _(text, rng):
    """A second router for the same phase and trigger."""
    results = []
    for start, end, name in route_blocks(text):
        capital = name[0].upper() + name[1:]
        copy = re.sub(r'(\bstatic func\s+)(`?)' + re.escape(name) + r'\2(?![\w`])',
                      lambda m: f'{m.group(1)}{m.group(2)}{name}Again{m.group(2)}', text[start:end], count=1)
        copy = re.sub(
            r'((?:\(?\s*`?Route`?\s*\)?)\s*\.\s*(?:(?:\(?\s*`?\w+`?\s*\)?)\s*\.\s*)?)(`?)' + re.escape(capital) + r'\2(?![\w`])',
            lambda m: f'{m.group(1)}{m.group(2)}{capital}Again{m.group(2)}',
            copy,
        )
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
            refusal = (rf"Operation '{re.escape(operation)}' is never started: no transition lists it in starts:; start it from a transition, or remove it\.|"
                       r"This transition starts no operation, cancels no work, and emits no event.*")
            results.append((new, dict(site=f'start of {operation} removed', role='value', breaking='operation-drop-start', refusal=refusal)))
        for outcome in ('Success', 'Failure'):
            handlers = [f for f in functions if re.search(rf'@(?:StateMachine\.)?(?:Transition|Route)\(on{outcome}:\s*{operation}\.self', text[f['func_at'] - 200:f['func_at']].split('\n\n')[-1])]
            handlers = [f for f in handlers if re.search(rf'on{outcome}:\s*{operation}\.self', text[text.rfind(chr(10) + '    @', 0, f['func_at']):f['func_at']])]
            if len(handlers) == 1:
                start, end = function_block(text, handlers[0])
                kind = 'Output' if outcome == 'Success' else 'Failure'
                # Dropping a phase's only completion edge can leave the phase without an exit instead.
                refusal = (rf"Operation '{re.escape(operation)}' can start but (never complete: .*|its {outcome.lower()} is never accepted: .*)|"
                           r"Phase '[^']*' has no outgoing transitions; mark it '@Terminal' or declare a transition from it\.|"
                           rf"Operation '{re.escape(operation)}' has no on{outcome}: edge or router, so the macro reads its {kind} as Never, .*")
                results.append((text[:start] + text[end + 1:], dict(site=f'on{outcome} of {operation} removed', role='value',
                                                                    breaking=f'operation-drop-{outcome.lower()}', refusal=refusal)))
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
                refusal = (rf"Started operation '{re.escape(operation.group(2))}' and every required scope must be eligible in destination '[^']*'\.|"
                           rf"Operation '{re.escape(operation.group(2))}' can never run: .*")
                results.append((new, dict(site=f'{scope} not active in {destination}', role='value', refusal=refusal)))
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


# --- Boundaries the older families leave out ----------------------------------------------------------------------

ATTRIBUTE_HEAD = re.compile(r'@(?:StateMachine(?:::|\.))?(StateMachine|Operation|Transition|Route|Active|Restoration|Event|PhaseSet)\(')


@rewrite('label-backtick', 'eq', 'an argument label may be escaped with backticks, nested ones included')
def _(text, rng):
    """One argument label inside a macro attribute, at any depth (`.parallel(`limit`: 2)` too), escaped; the callee,
    the argument, and the declaration stay as they are. Swift may warn that the escape is redundant, and a consumer
    need not make that warning an error, so the case compiles without `-warnings-as-errors`."""
    results = []
    mask = code_mask(text)
    nested = []
    for head in ATTRIBUTE_HEAD.finditer(text):
        if not mask[head.start()]:
            continue
        depth, index = 1, head.end()
        while index < len(text) and depth:
            depth += {'(': 1, ')': -1}.get(text[index], 0)
            index += 1
        inside = text[head.end():index - 1]
        for label in re.finditer(r'(?<![\w`.])([a-z]\w*)\s*:(?!:)', inside):
            start = head.end() + label.start(1)
            end = head.end() + label.end(1)
            depth = inside[:label.start(1)].count('(') - inside[:label.start(1)].count(')')
            (nested if depth > 0 else results).append((text[:start] + f'`{label.group(1)}`' + text[end:], dict(
                site=f'`{label.group(1)}:` in @{head.group(1)}', role='value', flags=['-no-warnings-as-errors'])))
    # Nested labels first, so a spread of sites always holds one.
    return nested + results


@rewrite('callee-backtick', 'eq', 'an argument label may be escaped with backticks, nested ones included')
def _(text, rng):
    """A nested callee inside a macro attribute escaped with backticks (`.`parallel`(limit: 2)`), its labels left
    as they are. Swift may warn that the escape is redundant, so the case compiles without `-warnings-as-errors`."""
    results = []
    mask = code_mask(text)
    for head in ATTRIBUTE_HEAD.finditer(text):
        if not mask[head.start()]:
            continue
        depth, index = 1, head.end()
        while index < len(text) and depth:
            depth += {'(': 1, ')': -1}.get(text[index], 0)
            index += 1
        for callee in re.finditer(r'(?<![\w`])\.([a-z]\w*)\(', text[head.end():index - 1]):
            start, end = head.end() + callee.start(1), head.end() + callee.end(1)
            results.append((text[:start] + f'`{callee.group(1)}`' + text[end:], dict(
                site=f'.`{callee.group(1)}`( in @{head.group(1)}', role='value', flags=['-no-warnings-as-errors'])))
    return results


@rewrite('schema-named-value', 'eq', 'a static property named like the schema changes nothing')
def _(text, rng):
    """A static property named like the schema, declared directly inside it or in an extension of it: a value cannot
    shadow the schema's name where a type is expected, so both compile alike."""
    results = []
    paths = schema_path_list(text)
    mask = code_mask(text)
    for index, declaration in enumerate(schema_declarations(text)):
        schema = declaration.group(1)
        path = paths[index] if index < len(paths) else None
        bodies = [body_of(text, declaration)]
        if path:
            extensions = re.finditer(r'\bextension\s+' + re.escape(path) + r'\s*\{', text)
            bodies.extend(body_of(text, m) for m in extensions if mask[m.start()])
        property_name = re.compile(r'\s*(?:\w+\s+)*static\s+(?:let|var)\s+`?' + re.escape(schema) + r'`?(?!\w)')
        if any(property_name.match(line) for body in bodies for line in direct_lines(body)):
            continue
        opened = declaration.end()
        member = f'    static var {schema}: Swift::Int {{ 0 }}'
        added = [rf'\.{re.escape(schema)}\.{re.escape(schema)}\b', rf'\b{re.escape(schema)}\.getter : Swift\.Int']
        results.append((text[:opened] + '\n' + member + text[opened:], dict(site=f'static var {schema} inside {schema}', role='value', added=added)))
        if path:
            results.append((append_to_module(text, f'extension {path} {{ static var {schema}: Swift::Int {{ 0 }} }}'),
                            dict(site=f'static var {schema} in an extension', role='value', added=added)))
    return results


@rewrite('leaf-access', 'safe', 'Each declaration of the schema that one of those spellings names needs that access too')
def _(text, rng):
    """A public leaf named through a public namespace alias loses its access, spelled through the alias and through
    its own type's name: the macro must refuse both alike, at the leaf."""
    results = []
    # The alias may name a specialization (`Box<Swift::Int>`), whose leaf is the generic base's member.
    for alias in re.finditer(r'^\s*public typealias (\w+) = (\w+)(<[^>\n]*>)?$', text, re.M):
        name, target, arguments = alias.group(1), alias.group(2), alias.group(3) or ''
        base = re.search(r'\benum ' + target + r'\b', text)
        leaf = re.search(r'public struct (\w+)', text[base.start():]) if base else None
        if not leaf:
            continue
        lowered = text.replace(f'public struct {leaf.group(1)}', f'struct {leaf.group(1)}', 1)
        results.append((lowered, dict(site=f'{name}.{leaf.group(1)} internal', role='value', expect='schema-access')))
        direct = re.sub(r'\b' + name + r'\.' + leaf.group(1) + r'\b', f'{target}{arguments}.{leaf.group(1)}', lowered)
        results.append((direct, dict(site=f'{target}{arguments}.{leaf.group(1)} internal', role='value', expect='schema-access')))
    return results


@rewrite('schema-named-type', 'safe', 'The schema name is reserved or shadowed by a direct member')
def _(text, rng):
    """The negative control of `schema-named-value`: a nested type named like the schema shadows it where a type is
    expected, which the macro refuses at that type's name."""
    results = []
    paths = schema_paths(text)
    for schema in schema_names(text):
        opened, closed = schema_opening(text, schema)
        if opened is None:
            continue
        body = text[opened:closed]
        mask = code_mask(body)
        nested = [(m.start(), m.end() + len(body_of(body, m))) for m in re.finditer(
            r'\b(?:struct|enum|class|actor|protocol)\s+`?\w+`?[^;{}\n]*\{', body) if mask[m.start()]]

        def preserve_reference(match):
            at = match.start()
            if not mask[at] or body[:at].rstrip().endswith(('.', '::')):
                return match.group(0)
            # Keep authored references pointing at the schema after inserting the shadow. Use `Self` at direct
            # schema scope so the macro still reads phase types syntactically, and `Fz::<path>` inside nested types.
            if any(start <= at <= end for start, end in nested):
                return 'Fz::' + paths.get(schema, schema)
            return 'Self'

        body = re.sub(r'(?<![\w`])(?:`' + re.escape(schema) + r'`|' + re.escape(schema) + r')(?=\s*\.)',
                      preserve_reference, body)
        results.append((text[:opened] + f'\n    struct {schema}: Swift::Sendable {{}}' + body + text[closed:],
                        dict(site=f'struct {schema} inside {schema}', role='value', expect='reserved-names')))
    return results


@rewrite('rebind-alias', 'valid', 'what an unchanged spelling names follows its declaration')
def _(text, rng):
    """An alias the schema declares keeps its name and changes what it names (`Swift::Int` to `Swift::Int64`), so
    every exported spelling that uses it is unchanged and names another type: the spelling probes must see it."""
    # Leave aliases unchanged when they reach edge signatures, enum case payloads, or operation
    # aliases (`Input`, `Output`, `Failure`, `Key`, `Request`), including through alias chains.
    fixed = {'Input', 'Output', 'Failure', 'Key', 'Request'}
    for site in type_sites(text):
        if site.context == 'edge' or site.kind in ('case', 'phase-case'):
            fixed.update(identifier_tokens(site.text))
    mask = code_mask(text)
    aliases = [(alias, text[alias.end():scan_type_end(text, alias.end(), ';\n')])
               for alias in re.finditer(r'\btypealias\s+`?(\w+)`?(?:<[^>=]*>)?\s*=\s*', text) if mask[alias.start()]]
    dependencies = collections.defaultdict(set)
    for alias, target in aliases:
        dependencies[alias.group(1)].update(identifier_tokens(target))
    guarded_aliases = set()
    literal = re.compile(r'\s*\(\s*(?:"(?:[^"\\\n]|\\\((?:[^()]|\([^()]*\))*\)|\\.)*"|-?[0-9][\da-fA-Fboxo_]*)\s*\)')
    aliases_by_start = {alias.start(): (alias, target) for alias, target in aliases}
    event_head = r'@(?:StateMachine(?:\.|::))?Event\b\s*(?:\(\s*\)\s*)?(?:\w+\s+)*enum\s+`?(\w+)`?[^{}\n]*\{'
    case_pattern = re.compile(r'\bcase\b\s*(?:(?:let|var)\s+)?(?:`?\w+`?\s*\.\s*)*'
                              r'(?:`?\w+`?\s*)?$')
    visible_text = ''.join(char if visible else ' ' for char, visible in zip(text, mask))
    for event in re.finditer(event_head, visible_text):
        event_name = event.group(1)
        run = next((i for i, char in enumerate(event_name) if not char.isupper()), len(event_name))
        if 1 < run < len(event_name) and event_name[run].islower():
            run -= 1
        effect_name = unicodedata.normalize('NFC', event_name[:run].lower() + event_name[run:])
        mentions = re.finditer(r'\.\s*`?' + re.escape(effect_name) + r'`?(?![\w`])', text)
        producers = (mention for mention in mentions if mask[mention.start()]
                     and not case_pattern.search(visible_text, 0, mention.start()))
        if all(literal.match(text, producer.end()) for producer in producers):
            continue
        # Only an event used with context-inferred literals can safely change its payload here. Protect the aliases
        # an event reads inside its namespace first, then follow any dependencies outside that namespace.
        body = body_of(text, event)
        local_aliases, local_types, depth = {}, set(), 0
        for member in re.finditer(r'[{}]|\b(?:typealias|struct|enum|class|actor|protocol)\s+`?(\w+)', body):
            start = event.end() + member.start()
            if not mask[start]:
                continue
            if member.group(1) is None:
                depth += 1 if member.group(0) == '{' else -1
            elif depth == 0:
                if start in aliases_by_start:
                    local_aliases[member.group(1)] = aliases_by_start[start]
                else:
                    local_types.add(member.group(1))
        if 'Payload' not in local_aliases:
            continue
        pending = ['Payload']
        seen = set()
        while pending:
            name = pending.pop()
            if name in seen:
                continue
            seen.add(name)
            if name in local_aliases:
                alias, target = local_aliases[name]
                guarded_aliases.add(alias.start())
                target = re.sub(r'(?<![\w.])(?:Self|' + re.escape(event_name) + r')\s*\.\s*', '', target)
                qualified = re.findall(r'\b\w+\s*(?:\.|::)\s*`?(\w+)', target)
                fixed.update(qualified)
                pending.extend(identifier_tokens(target) - set(qualified))
            elif name not in local_types:
                fixed.add(name)
    pending = list(fixed)
    while pending:
        names = dependencies[pending.pop()] - fixed
        fixed.update(names)
        pending.extend(names)

    results = []
    for alias in re.finditer(r'\btypealias\s+`?(\w+)`?\s*=\s*(Swift::)?(Int|String)\b(?!\s*[.<])', text):
        if not mask[alias.start()] or alias.group(1) in fixed or alias.start() in guarded_aliases:
            continue
        other = {'Int': 'Swift::Int64', 'String': 'Swift::Substring'}[alias.group(3)]
        start = alias.start(2) if alias.group(2) else alias.start(3)
        results.append((text[:start] + other + text[alias.end(3):], dict(site=f'{alias.group(1)} = {other}', role='value')))
    return results


@rewrite('schema-to-file', 'eq', 'a schema may be declared in any file of its module')
def _(text, rng):
    """The whole top-level schema moved into another source file of its module."""
    results = []
    if FILE_MARKER.search(text) or 'func fuzzLocalSchema()' in text or '// fuzz-outer:' in text:
        return results
    module, client = (text.split(CLIENT_MARKER, 1) + [None])[:2] if CLIENT_MARKER in text else (text, None)
    mask = code_mask(module)
    for match in re.finditer(r'^(?:@available\([^)]*\)\s*\n)?@StateMachine\(', module, re.M):
        start = match.start()
        if not mask[start]:
            continue
        depth = sum((1 if ch == '{' else -1) for ch, code in zip(module[:start], mask[:start]) if code and ch in '{}')
        if depth != 0:
            continue
        opened = module.find('{', start)
        end = opened + len(body_of(module, re.compile(r'\{').match(module, opened))) + 2
        moved = module[start:end]
        rest = module[:start] + module[end:]
        new = rest.rstrip('\n') + '\n// fuzz-file: Other.swift\nimport StateMachine\n\n' + moved + '\n'
        results.append((new + (CLIENT_MARKER + client if client is not None else ''), dict(site='schema in Other.swift', role='value')))
    return results


@rewrite('comment-decoy', 'eq', 'comments and string literals hold no declarations')
def _(text, rng):
    """Declaration-like text inside a nested block comment, a raw string, and a multiline string."""
    decoys = [
        '/* outer /* inner */ @StateMachine(mode: .shared) enum Decoy {} */',
        'let fuzzDecoyRaw = #"@Transition(on: Input.go) enum Fake { case x(Int) } "# + "\\"#"',
        'let fuzzDecoyLines = """\n@Operation(activeIn: [Idle.self])\nenum Fake {}\n"""',
    ]
    return [(append_to_module(text, decoy), dict(site=f'decoy {index}', role='value', added=[r'fuzzDecoy']))
            for index, decoy in enumerate(decoys)]


@rewrite('nfc-body', 'valid', 'The macro skips opaque function and closure bodies')
def _(text, rng):
    """A decomposed name used only inside an authored function's body, which the macro never reads."""
    results = []
    for function in authored_functions_at(text)[:2]:
        brace = text.find('{', function['after'])
        if brace < 0:
            continue
        body = body_of(text, re.compile(r'\{').match(text, brace))
        name = 'caféLocal'
        if 'return' in body:
            prefix = f' let {name} = 0; _ = {name};'
        elif '\n' not in body.strip() and not re.match(r'\s*(throw|if|switch|do|guard|let|var|_ =|fatalError)\b', body):
            # A single-expression body returns its expression, so a statement before it needs the return written.
            prefix = f' let {name} = 0; _ = {name}; return'
        else:
            continue
        results.append((text[:brace + 1] + prefix + text[brace + 1:],
                        dict(site=f'decomposed local in {function["name"]}', role='value')))
    return results


@rewrite('nfc-read', 'safe', 'The macro therefore refuses a name that is not in that form anywhere it reads one')
def _(text, rng):
    """The same decomposed name moved where the macro reads it: an Input case."""
    results = []
    opened = re.search(r'enum Input: (?:Swift::)?Sendable \{ case ', text)
    if opened:
        results.append((text[:opened.end()] + 'caféCase, ' + text[opened.end():],
                        dict(site='decomposed Input case', role='value', expect='nfc-refusal')))
    return results


@rewrite('parameter-restriction', 'break', 'Use a synchronous nongeneric static function with nonvariadic parameters and no defaults')
def _(text, rng):
    """A defaulted or variadic extra parameter on an authored transition, which the macro refuses at that parameter."""
    results = []
    for function in authored_functions_at(text)[:2]:
        if function['attribute'] != 'Transition':
            continue
        close = text.rfind(')', function['func_at'], function['after'])
        if close < 0:
            continue
        for extra in (', _ fuzzCount: Swift::Int = 1', ', _ fuzzRest: Swift::Int...'):
            results.append((text[:close] + extra + text[close:], dict(
                site=f'{extra.strip(", ")} on {function["name"]}', role='value',
                refusal=r"Use a synchronous nongeneric static function with (unlabeled, )?nonvariadic parameters and no defaults.*")))
    return results


@rewrite('duplicate-marker', 'break', 'Mark exactly one phase case with @Initial')
def _(text, rng):
    """A second `@Initial`, or a dependency repeated in `requires:`."""
    results = []
    for case in re.finditer(r'^    (@Terminal )?case\s+`?\w+`?\(', text, re.M):
        if '@Initial' in text[case.start():text.find('\n', case.start())]:
            continue
        results.append((text[:case.start()] + '    @Initial ' + text[case.start() + 4:], dict(
            site='a second @Initial', role='value', refusal=r'Mark exactly one phase case with @Initial\.')))
        break
    for requires in re.finditer(r'requires:\s*\[(Scope\.\w+)', text):
        results.append((text[:requires.end(1)] + ', ' + requires.group(1) + text[requires.end(1):], dict(
            site='a repeated dependency', role='value', refusal=r'Remove duplicate references from this metadata list\.')))
    return results


@rewrite('numeric-valid', 'valid', 'admission: .parallel(limit: N) with N of at least 1')
def _(text, rng):
    """`.parallel(limit:)` at its lowest valid value."""
    # A chain of phases that only enough parallel executions reach needs its limit; it is left alone.
    if 'enum Chain' in text:
        return []
    return [(text[:m.start(1)] + '1' + text[m.end(1):], dict(site='limit 1', role='value', behaviour=False))
            for m in re.finditer(r'\.parallel\(limit:\s*([0-9_]+)\)', text)]


@rewrite('numeric-invalid', 'break', 'admission: .parallel(limit: N) with N of at least 1')
def _(text, rng):
    """`.parallel(limit:)` past its validity boundaries: zero spelled in hexadecimal, and a literal one above `Int.max`."""
    results = []
    for match in re.finditer(r'\.parallel\(limit:\s*([0-9_]+)\)', text):
        for value in ('0x0', '9223372036854775808'):
            results.append((text[:match.start(1)] + value + text[match.end(1):], dict(
                site=f'limit {value}', role='value', refusal=r'Use \.parallel\(limit: N\).*|Admission must be .*')))
    return results


# --- `@PhaseSet` rewrites ---------------------------------------------------------------------------------------------

def fresh_identifier(text, base):
    taken = identifier_tokens(text)
    if base not in taken:
        return base
    return next(f'{base}{n}' for n in range(2, 1000) if f'{base}{n}' not in taken)


def line_indent(text, offset):
    start = text.rfind('\n', 0, offset) + 1
    end = start
    while end < len(text) and text[end] in ' \t':
        end += 1
    return text[start:end]


def find_phase_set_decls(text):
    """Direct `@PhaseSet([...])` empty nested enum declarations inside each schema in `text`, with their spans,
    members, enclosing schema bounds, and `from: <Set>.self` uses in that schema."""
    mask = code_mask(text)
    decls = []
    ident = re.compile(IDENT_TOKEN)
    attr = re.compile(r'@' + IDENT_TOKEN + r'(?:\s*(?:::|\.)\s*' + IDENT_TOKEN + r')*')
    transition_attr = re.compile(r'@(?:`?StateMachine`?\s*(?:::|\.)\s*)?`?Transition`?(?![\w`])\s*\(')
    for declaration, schema_end in schema_bounds(text, mask):
        schema_start = declaration.end()
        body = text[schema_start:schema_end]
        direct = direct_member_text(body)
        # Collect every `from: <Name>.self` use in this schema's direct transitions.
        uses_by_name = collections.defaultdict(list)
        for tr in transition_attr.finditer(direct):
            tr_end = scan_type_end(direct, tr.end(), '')
            if tr_end >= len(direct) or direct[tr_end] != ')':
                continue
            args = direct[tr.end():tr_end]
            from_use = re.search(r'(?<![\w`])`?from`?\s*:\s*(' + IDENT_TOKEN + r')\s*\.\s*`?self`?(?![\w`])', args)
            if from_use:
                expr_start = schema_start + tr.end() + from_use.start(1)
                expr_end = schema_start + tr.end() + from_use.end()
                uses_by_name[from_use.group(1).strip('`')].append((expr_start, expr_end, schema_start + tr.start()))
        for match in PHASE_SET_ATTR.finditer(direct):
            arg_end = scan_type_end(direct, match.end(), '')
            if arg_end >= len(direct) or direct[arg_end] != ')':
                continue
            arg_text = direct[match.end():arg_end]
            members = parse_phase_set_members(arg_text)
            if not members:
                continue
            bracket = re.search(r'\[.*\]', arg_text, re.S)
            if not bracket:
                continue
            cursor = arg_end + 1
            enum_name, name_span = None, None
            while cursor < len(direct):
                while cursor < len(direct) and direct[cursor].isspace():
                    cursor += 1
                if cursor >= len(direct):
                    break
                if direct[cursor] == '@':
                    found = attr.match(direct, cursor)
                    if not found:
                        break
                    cursor = found.end()
                    while cursor < len(direct) and direct[cursor].isspace():
                        cursor += 1
                    if cursor < len(direct) and direct[cursor] == '(':
                        cursor = scan_type_end(direct, cursor + 1, '') + 1
                    continue
                word = ident.match(direct, cursor)
                if not word:
                    break
                token = word.group(0)
                cursor = word.end()
                if token == 'enum':
                    while cursor < len(direct) and direct[cursor].isspace():
                        cursor += 1
                    name_match = ident.match(direct, cursor)
                    if name_match and direct[name_match.end():].lstrip()[:1] != '<':
                        enum_name = name_match.group(0).strip('`')
                        name_span = (schema_start + name_match.start(), schema_start + name_match.end())
                        cursor = name_match.end()
                    break
                if token in DECL_STOP_KEYWORDS:
                    break
            if enum_name is None:
                continue
            open_brace = direct.find('{', cursor)
            if open_brace < 0:
                continue
            close_brace = direct.find('}', open_brace + 1)
            if close_brace < 0:
                continue
            attr_start = schema_start + match.start()
            line_start = text.rfind('\n', 0, attr_start) + 1
            decl_start = line_start if not text[line_start:attr_start].strip() else attr_start
            decl_end = schema_start + close_brace + 1
            if decl_end < len(text) and text[decl_end] == '\n':
                decl_end += 1
            decls.append(dict(
                schema_start=schema_start, schema_end=schema_end,
                decl_start=decl_start, decl_end=decl_end,
                attr_start=attr_start, attr_end=schema_start + arg_end + 1,
                attr_head_end=schema_start + match.end() - 1,
                list_start=schema_start + match.end() + bracket.start(),
                list_end=schema_start + match.end() + bracket.end(),
                name=enum_name, name_start=name_span[0], name_end=name_span[1],
                body_open=schema_start + open_brace, body_close=schema_start + close_brace,
                members=members, indent=line_indent(text, attr_start),
                uses=uses_by_name.get(enum_name, []),
            ))
    return decls


def insert_at_schema_bottom(text, schema_end, block):
    """Insert a member block right before the schema's closing brace at `schema_end`."""
    line_start = text.rfind('\n', 0, schema_end) + 1
    prefix = '' if text[line_start:schema_end].strip() == '' else '\n'
    return text[:line_start] + prefix + block.rstrip('\n') + '\n' + text[line_start:]


@rewrite('phase-set-extract', 'eq', 'A @PhaseSet expands to the exact ordered list of phases it names')
def _(text, rng):
    """Extracts an inline `@Transition(from: [A.self, ...])` list into a `@PhaseSet` enum declared before or after
    the transition."""
    results = []
    mask = code_mask(text)
    transition_attr = re.compile(r'@(?:`?StateMachine`?\s*(?:::|\.)\s*)?`?Transition`?(?![\w`])\s*\(')
    for declaration, schema_end in schema_bounds(text, mask):
        schema_start = declaration.end()
        body = text[schema_start:schema_end]
        direct = direct_member_text(body)
        for tr in transition_attr.finditer(direct):
            tr_end = scan_type_end(direct, tr.end(), '')
            if tr_end >= len(direct) or direct[tr_end] != ')':
                continue
            args = direct[tr.end():tr_end]
            source_list = re.search(r'(?<![\w`])`?from`?\s*:\s*(\[[^\]]*\])', args)
            if not source_list:
                continue
            members = parse_phase_set_members(source_list.group(1))
            if not members:
                continue
            set_name = fresh_identifier(text, 'FuzzPhaseSet')
            indent = line_indent(text, schema_start + tr.start())
            raw_list = text[schema_start + tr.end() + source_list.start(1):schema_start + tr.end() + source_list.end(1)]
            decl_block = f'{indent}@PhaseSet({raw_list})\n{indent}fileprivate enum {set_name} {{}}\n'
            list_abs_start = schema_start + tr.end() + source_list.start(1)
            list_abs_end = schema_start + tr.end() + source_list.end(1)
            replaced = text[:list_abs_start] + f'{set_name}.self' + text[list_abs_end:]
            delta = len(f'{set_name}.self') - (list_abs_end - list_abs_start)
            # Insert near top of schema (before transition).
            top_at = schema_start + (1 if text[schema_start:schema_start + 1] == '\n' else 0)
            before = replaced[:top_at] + decl_block + replaced[top_at:]
            results.append((before, dict(site=f'extract {raw_list} to @PhaseSet before', role='value')))
            # Insert near bottom of schema (after transition).
            after = insert_at_schema_bottom(replaced, schema_end + delta, decl_block)
            results.append((after, dict(site=f'extract {raw_list} to @PhaseSet after', role='value')))
    return results


@rewrite('phase-set-inline', 'eq', 'A @PhaseSet expands to the exact ordered list of phases it names')
def _(text, rng):
    """Replaces `@Transition(from: SetName.self)` with the inline array literal, both keeping and removing the
    `@PhaseSet` enum."""
    results = []
    for decl in find_phase_set_decls(text):
        if not decl['uses']:
            continue
        inline = '[' + ', '.join(f'{member}.self' for member in decl['members']) + ']'
        first_start, first_end, _ = decl['uses'][0]
        kept = text[:first_start] + inline + text[first_end:]
        results.append((kept, dict(site=f'inline {decl["name"]} keeping decl', role='value')))
        edits = [(start, end, inline) for start, end, _ in decl['uses']]
        edits.append((decl['decl_start'], decl['decl_end'], ''))
        removed = text
        for start, end, replacement in sorted(edits, key=lambda item: -item[0]):
            removed = removed[:start] + replacement + removed[end:]
        results.append((removed, dict(site=f'inline {decl["name"]} removing decl', role='value')))
    return results


@rewrite('phase-set-move', 'eq', 'A set may be declared before or after the transitions that name it')
def _(text, rng):
    """Moves a `@PhaseSet` enum declaration to the top or bottom of its schema body."""
    results = []
    for decl in find_phase_set_decls(text):
        block = text[decl['decl_start']:decl['decl_end']]
        stripped = text[:decl['decl_start']] + text[decl['decl_end']:]
        removed_len = decl['decl_end'] - decl['decl_start']
        top_at = decl['schema_start'] + (1 if text[decl['schema_start']:decl['schema_start'] + 1] == '\n' else 0)
        if decl['decl_start'] > top_at:
            moved_top = stripped[:top_at] + block + stripped[top_at:]
            results.append((moved_top, dict(site=f'move @PhaseSet {decl["name"]} to top', role='value')))
        bottom_target = decl['schema_end'] - removed_len
        if text[decl['decl_end']:decl['schema_end']].strip():
            moved_bottom = insert_at_schema_bottom(stripped, bottom_target, block)
            results.append((moved_bottom, dict(site=f'move @PhaseSet {decl["name"]} to bottom', role='value')))
    return results


@rewrite('phase-set-spelling', 'eq', 'Write @StateMachine.PhaseSet or @StateMachine::PhaseSet when the schema declares its own type named PhaseSet')
def _(text, rng):
    """Qualification (`@StateMachine.PhaseSet`, `@StateMachine::PhaseSet`, including beside a schema-owned
    `enum PhaseSet {}`), comments, and backticks on `@PhaseSet` declarations and uses."""
    results = []
    decls = find_phase_set_decls(text)
    shadowed_schemas = set()
    for decl in decls:
        attr_head = text[decl['attr_start']:decl['attr_head_end']]
        if 'StateMachine' not in attr_head:
            for qualifier in ('@StateMachine.PhaseSet', '@StateMachine::PhaseSet'):
                new = text[:decl['attr_start']] + qualifier + text[decl['attr_head_end']:]
                results.append((new, dict(site=f'{qualifier} on {decl["name"]}', role='attribute')))
            if decl['schema_start'] not in shadowed_schemas and 'PhaseSet' not in declared_types(text):
                shadowed_schemas.add(decl['schema_start'])
                same_schema = [d for d in decls if d['schema_start'] == decl['schema_start']]
                qualified = text
                for item in sorted(same_schema, key=lambda d: -d['attr_start']):
                    qualified = qualified[:item['attr_start']] + '@StateMachine::PhaseSet' + qualified[item['attr_head_end']:]
                top_at = decl['schema_start'] + (1 if text[decl['schema_start']:decl['schema_start'] + 1] == '\n' else 0)
                shadowed = qualified[:top_at] + f"{decl['indent']}enum PhaseSet {{}}\n" + qualified[top_at:]
                results.append((shadowed, dict(site=f'@StateMachine::PhaseSet beside enum PhaseSet', role='attribute')))
        # Backticks and comments on the `@PhaseSet` member list, enum name, and `from:` uses.
        commented_list = '/* fuzz */ [ ' + ', '.join(f'/* p */ `{member}`.self' for member in decl['members']) + ' /* end */ ]'
        edits = [
            (decl['list_start'], decl['list_end'], commented_list),
            (decl['name_start'], decl['name_end'], f'`{decl["name"]}`'),
        ]
        for use_start, use_end, _ in decl['uses']:
            edits.append((use_start, use_end, f'/* set */ `{decl["name"]}`.self'))
        spelled = text
        for start, end, replacement in sorted(edits, key=lambda item: -item[0]):
            spelled = spelled[:start] + replacement + spelled[end:]
        results.append((spelled, dict(site=f'backticks and comments on @PhaseSet {decl["name"]}', role='value')))
    return results


@rewrite('phase-set-decl-invalid', 'break', 'A @PhaseSet must be an empty nested enum directly inside the schema')
def _(text, rng):
    """Invalid `@PhaseSet` declarations: empty list, duplicate phase, nested `@PhaseSet`, non-empty enum body,
    non-phase member, and non-enum declaration."""
    results = []
    decls = find_phase_set_decls(text)
    by_schema = collections.defaultdict(list)
    for decl in decls:
        by_schema[decl['schema_start']].append(decl)
    for schema_start, schema_decls in by_schema.items():
        decl = schema_decls[0]
        name = decl['name']
        first = decl['members'][0]
        indent = decl['indent']
        schema_body_text = text[schema_start:decl['schema_end']]
        top_at = schema_start + (1 if text[schema_start:schema_start + 1] == '\n' else 0)
        # 1. Empty `@PhaseSet([])`.
        empty = text[:decl['list_start']] + '[]' + text[decl['list_end']:]
        results.append((empty, dict(
            site=f'empty @PhaseSet {name}', role='value',
            refusal=r'List at least one phase in @PhaseSet\(\[\.\.\.\]\)\.')))
        # 2. Duplicate phase in `@PhaseSet([...])`.
        dup = text[:decl['list_end'] - 1] + f', {first}.self]' + text[decl['list_end']:]
        results.append((dup, dict(
            site=f'duplicate {first} in @PhaseSet {name}', role='value',
            refusal=rf"List each phase once in @PhaseSet '{re.escape(name)}'; '{re.escape(first)}' appears twice\.",
            token=rf'`?{re.escape(first)}`?\.self')))
        # 3. Nested `@PhaseSet` reference inside `@PhaseSet([...])`.
        if len(schema_decls) > 1:
            nested_name = schema_decls[1]['name']
            nested = text[:decl['list_end'] - 1] + f', {nested_name}.self]' + text[decl['list_end']:]
        else:
            nested_name = fresh_identifier(text, 'FuzzInnerSet')
            nested = text[:decl['list_end'] - 1] + f', {nested_name}.self]' + text[decl['list_end']:]
            nested = nested[:top_at] + f'{indent}@PhaseSet([{first}.self])\n{indent}fileprivate enum {nested_name} {{}}\n' + nested[top_at:]
        results.append((nested, dict(
            site=f'nested @PhaseSet {nested_name} in {name}', role='value',
            refusal=rf"'{re.escape(nested_name)}' is a @PhaseSet; nested phase sets are unsupported\. List phase payload types directly as <Phase>\.self\.",
            token=rf'`?{re.escape(nested_name)}`?\.self')))
        # 4. Non-empty `@PhaseSet` enum body.
        extra_type = fresh_identifier(text, 'FuzzExtra')
        non_empty = text[:decl['body_open'] + 1] + f' struct {extra_type} {{}} ' + text[decl['body_close']:]
        results.append((non_empty, dict(
            site=f'non-empty @PhaseSet {name}', role='value',
            refusal=rf"@PhaseSet enum '{re.escape(name)}' must be empty; remove its members\.",
            token=r'struct')))
        # 5. Non-phase member (`@Operation`, `@Event`, or plain struct) inside `@PhaseSet`.
        ops = re.findall(r'@(?:StateMachine(?:::|\.))?Operation\b[^\n]*\n\s*(?:\w+\s+)*enum\s+`?(\w+)`?', schema_body_text)
        if ops:
            op = ops[0]
            wrong_role = text[:decl['list_end'] - 1] + f', {op}.self]' + text[decl['list_end']:]
            results.append((wrong_role, dict(
                site=f'@Operation {op} in @PhaseSet {name}', role='value',
                refusal=rf"'{re.escape(op)}' is an @Operation, not a phase payload type declared in this schema\.",
                token=rf'`?{re.escape(op)}`?\.self')))
        else:
            not_phase = fresh_identifier(text, 'FuzzNotPhase')
            with_member = text[:decl['list_end'] - 1] + f', {not_phase}.self]' + text[decl['list_end']:]
            with_member = with_member[:top_at] + f'{indent}fileprivate struct {not_phase} {{}}\n' + with_member[top_at:]
            results.append((with_member, dict(
                site=f'non-phase {not_phase} in @PhaseSet {name}', role='value',
                refusal=rf"'{re.escape(not_phase)}' is not a phase payload type declared in this schema\.",
                token=rf'{re.escape(not_phase)}\.self')))
        # 6. `@PhaseSet` on a non-enum declaration inside the schema.
        bad_struct = fresh_identifier(text, 'FuzzNonEnumSet')
        non_enum = text[:top_at] + f'{indent}@PhaseSet([{first}.self]) fileprivate struct {bad_struct} {{}}\n' + text[top_at:]
        results.append((non_enum, dict(
            site=f'@PhaseSet on struct {bad_struct}', role='value',
            refusal=r'@PhaseSet must mark an empty nested enum\.',
            token=r'@(?:StateMachine(?:::|\.))?PhaseSet')))
    return results


@rewrite('phase-set-use-invalid', 'break', 'from: takes either an inline array literal or a bare <Set>.self')
def _(text, rng):
    """Invalid `@PhaseSet` uses: non-`@PhaseSet` enum in `from:`, bare phase payload in `from:`, `@PhaseSet` inside
    inline `from: [...]`, qualified `from: Self.<Set>.self`, `@Terminal` phase reached through `@PhaseSet`, and
    `@PhaseSet` placed outside `@StateMachine`."""
    results = []
    decls = find_phase_set_decls(text)
    by_schema = collections.defaultdict(list)
    for decl in decls:
        if decl['uses']:
            by_schema[decl['schema_start']].append(decl)
    for schema_start, schema_decls in by_schema.items():
        decl = schema_decls[0]
        name = decl['name']
        first = decl['members'][0]
        indent = decl['indent']
        use_start, use_end, _ = decl['uses'][0]
        top_at = schema_start + (1 if text[schema_start:schema_start + 1] == '\n' else 0)
        # 1. Unknown / non-`@PhaseSet` type in `from:`.
        not_a_set = fresh_identifier(text, 'FuzzNotASet')
        unknown = text[:use_start] + f'{not_a_set}.self' + text[use_end:]
        unknown = unknown[:top_at] + f'{indent}fileprivate enum {not_a_set} {{}}\n' + unknown[top_at:]
        results.append((unknown, dict(
            site=f'from: non-set {not_a_set}.self', role='value',
            refusal=rf"'{re.escape(not_a_set)}' is not a @PhaseSet declared directly inside this schema\.",
            token=rf'{re.escape(not_a_set)}\.self')))
        # 2. Bare phase payload in `from:`.
        bare_phase = text[:use_start] + f'{first}.self' + text[use_end:]
        results.append((bare_phase, dict(
            site=f'from: bare phase {first}.self', role='value',
            refusal=rf"'{re.escape(first)}' is a phase payload type, not a @PhaseSet; write from: \[{re.escape(first)}\.self\], or reference a declared @PhaseSet enum as <Set>\.self\.",
            token=rf'`?{re.escape(first)}`?\.self')))
        # 3. `@PhaseSet` listed inside inline `from: [...]`.
        mixed = text[:use_start] + f'[{first}.self, {name}.self]' + text[use_end:]
        results.append((mixed, dict(
            site=f'from: mixed array with {name}.self', role='value',
            refusal=rf"'{re.escape(name)}' is a @PhaseSet and cannot be listed inside a from: array literal; pass from: {re.escape(name)}\.self directly or list its phase payload types inline\.",
            token=rf'`?{re.escape(name)}`?\.self')))
        # 4. Qualified `from: Self.<Set>.self`.
        qualified = text[:use_start] + f'Self.{name}.self' + text[use_end:]
        results.append((qualified, dict(
            site=f'from: qualified Self.{name}.self', role='value',
            refusal=r'Use an array literal of <Phase>\.self references or a @PhaseSet reference as <Set>\.self\.',
            token=rf'Self\.`?{re.escape(name)}`?\.self')))
        # 5. `@Terminal` phase reached through `from: <Set>.self`.
        body = text[schema_start:decl['schema_end']]
        term_match = re.search(r'@(?:StateMachine(?:::|\.))?Terminal\b[^\n]*\bcase\s+`?(\w+)`?\(\s*(' + IDENT_TOKEN + r')', body)
        if term_match:
            term_case = term_match.group(1)
            term_type = core_name(term_match.group(2))
            if term_type not in decl['members']:
                with_terminal = text[:decl['list_end'] - 1] + f', {term_type}.self]' + text[decl['list_end']:]
                results.append((with_terminal, dict(
                    site=f'@Terminal {term_case} in used @PhaseSet {name}', role='value',
                    refusal=rf"Terminal phase '{re.escape(term_case)}' in @PhaseSet '{re.escape(name)}' cannot have an outgoing transition '[^']*'; remove '@Terminal', remove '{re.escape(term_type)}\.self' from '{re.escape(name)}', or remove the transition\.",
                    token=rf'`?{re.escape(name)}`?\.self')))
        # 6. `@PhaseSet` placed outside `@StateMachine`.
        outside_name = fresh_identifier(text, 'FuzzOutsideSet')
        outside = insert_at_file_scope(text, f'@PhaseSet([Swift::Int.self])\nfileprivate enum {outside_name} {{}}')
        results.append((outside, dict(
            site=f'@PhaseSet outside schema ({outside_name})', role='value',
            refusal=r'Place @PhaseSet directly inside a @StateMachine enum\.',
            token=r'@PhaseSet')))
    return results


# --- `routed:` and generic `<Source>` multi-source rewrites -----------------------------------------------------------

def find_routed_params(text):
    """Each authored `routed:` parameter on a `@Transition` with its function metadata and exact spans."""
    found = []
    for function in authored_functions_at(text):
        if function['attribute'] != 'Transition' or not function['has_routed']:
            continue
        cursor = function['params_start']
        params_end = function['params_end']
        param_index = 0
        while cursor < params_end:
            p_end = scan_type_end(text, cursor, ',')
            if p_end > params_end:
                p_end = params_end
            segment = text[cursor:p_end]
            match = re.match(r'\s*(`?routed`?)\s+(`?\w+`?)\s*:\s*(' + MODIFIERS + r')', segment)
            if match:
                type_start = cursor + match.end()
                type_end = scan_type_end(text, type_start, ',=')
                if type_end > p_end:
                    type_end = p_end
                found.append(dict(
                    function=function,
                    param_index=param_index,
                    param_start=cursor + match.start(1),
                    param_end=p_end,
                    label_start=cursor + match.start(1),
                    label_end=cursor + match.end(1),
                    name=match.group(2).strip('`'),
                    modifiers=match.group(3),
                    modifiers_start=cursor + match.start(3),
                    type_start=type_start,
                    type_end=type_end,
                    type_text=text[type_start:type_end].strip(),
                ))
            cursor = p_end + 1
            param_index += 1
    return found


@rewrite('routed-spelling', 'eq', 'Parentheses, backticks, comments, and schema qualification on `routed:` change nothing')
def _(text, rng):
    """Equivalent spellings on a candidate's `routed:` parameter: backticked label, comments, parentheses, and
    `Self.`/`<Schema>.` qualification for schema-local routed payload types."""
    results = []
    local_types = schema_types(text)
    for item in find_routed_params(text):
        func_name = item['function']['name']
        raw_type = text[item['type_start']:item['type_end']]
        # 1. Backticked `routed` label + comments around label and parenthesized type.
        wrapped_type = raw_type if raw_type.startswith('(') and raw_type.endswith(')') else f'({raw_type})'
        replacement = f'/* fuzz */ `routed` {item["name"]}: {item["modifiers"]}/* r */ {wrapped_type}'
        spelled = text[:item['param_start']] + replacement + text[item['type_end']:]
        results.append((spelled, dict(site=f'backtick/comment routed on {func_name}', role='value')))
        # 2. Schema qualification when the routed type is a bare schema-local nominal type.
        bare = item['type_text'].strip('`')
        schema = schema_of(text, item['param_start'])
        if is_simple_name(bare) and bare in local_types and schema and not bare.startswith(('Self.', schema + '.')):
            for prefix in ('Self.', f'{schema}.'):
                qualified = text[:item['type_start']] + prefix + raw_type + text[item['type_end']:]
                results.append((qualified, dict(site=f'{prefix}{bare} routed on {func_name}', role='value')))
    return results


@rewrite('routed-convention', 'valid', 'A candidate may pass its `routed:` payload with borrowing, consuming, or sending')
def _(text, rng):
    """Valid ownership/convention variations on a plain Copyable `routed:` parameter (`borrowing`, `consuming`,
    `__shared`, `__owned`, and `sending` for Sendable types)."""
    results = []
    for item in find_routed_params(text):
        if item['modifiers'].strip():
            continue
        type_text = item['type_text']
        func_name = item['function']['name']
        conventions = ['borrowing ', 'consuming ', '__shared ', '__owned ']
        if re.fullmatch(r'(?:Swift::)?(?:Int|String|Bool)', type_text):
            conventions.append('sending ')
        for conv in conventions:
            new = text[:item['modifiers_start']] + conv + text[item['modifiers_start']:]
            results.append((new, dict(site=f'{conv.strip()} routed {type_text} on {func_name}', role='value')))
    return results


@rewrite('routed-invalid', 'break', 'Only a candidate @Transition selected by a @Route may take a single final non-Never routed: parameter')
def _(text, rng):
    """Invalid `routed:` forms with exact macro diagnostics and anchors: unrouted transition, `@Route` taking
    `routed:`, `routed:` not last (including before `request:`), duplicate `routed:`, confirmed `Never`,
    `.ownedOnly`, public `@Route` leaking a `fileprivate` routed struct, and partially routed multi-source `from:`."""
    results = []
    functions = authored_functions_at(text)
    routed_items = find_routed_params(text)
    is_owned_only = bool(re.search(r'@StateMachine\([^)]*mode:\s*\.ownedOnly', text))
    # 1. `routed:` on `.ownedOnly` transition.
    if is_owned_only:
        for fn in functions:
            if fn['attribute'] == 'Transition' and not fn['has_routed']:
                sep = ', ' if text[fn['params_start']:fn['params_end']].strip() else ''
                new = text[:fn['params_end']] + f'{sep}routed fuzzTag: Swift::Int' + text[fn['params_end']:]
                results.append((new, dict(
                    site=f'routed: in .ownedOnly on {fn["name"]}', role='value',
                    refusal=r'routed: requires a @Route, which is unavailable in \.ownedOnly\.',
                    token=r'routed')))
                break
    # 2. `routed:` on an unrouted `@Transition`.
    if not is_owned_only:
        routes_on = set()
        for fn in functions:
            if fn['attribute'] == 'Route':
                attr = text[fn['attribute_at']:fn['func_at']]
                m = re.search(r'(on|onSuccess|onFailure)\s*:\s*([\w.]+)', attr)
                if m:
                    routes_on.add((m.group(1), m.group(2)))
        for fn in functions:
            if fn['attribute'] != 'Transition' or fn['has_routed'] or fn['has_from']:
                continue
            attr = text[fn['attribute_at']:fn['func_at']]
            m = re.search(r'(on|onSuccess|onFailure)\s*:\s*([\w.]+)', attr)
            if m and (m.group(1), m.group(2)) in routes_on:
                continue
            sep = ', ' if text[fn['params_start']:fn['params_end']].strip() else ''
            new = text[:fn['params_end']] + f'{sep}routed fuzzExtra: Swift::Int' + text[fn['params_end']:]
            results.append((new, dict(
                site=f'routed: on unrouted {fn["name"]}', role='value',
                refusal=rf"Transition '{re.escape(fn['name'])}' takes a routed: parameter, but no @Route selects it from '[^']*'\.",
                token=r'routed')))
            break
    # 3. `routed:` on a `@Route` function.
    for fn in functions:
        if fn['attribute'] == 'Route':
            sep = ', ' if text[fn['params_start']:fn['params_end']].strip() else ''
            new = text[:fn['params_end']] + f'{sep}routed fuzzBad: Swift::Int' + text[fn['params_end']:]
            results.append((new, dict(
                site=f'routed: on @Route {fn["name"]}', role='value',
                refusal=r'Only a candidate @Transition selected by a @Route may take a routed: parameter\.',
                token=r'routed')))
            break
    # 4. Mutations of an existing `routed:` candidate: not last (including before `request:`), duplicate, Never,
    #    public `@Route` exposing `fileprivate` routed type, and partially routed `from:`.
    did_not_last_payload, did_not_last_request, did_dup, did_never, did_public_leak, did_partial_from = (False,) * 6
    for item in routed_items:
        fn = item['function']
        # 4a. `routed:` before the preceding parameter (both payload + `routed:` and `request:` + `routed:` ordering).
        if item['param_index'] >= 1:
            params_text = text[fn['params_start']:fn['params_end']]
            parts = [p.strip() for p in split_top(params_text)]
            if len(parts) >= 2 and parts[-1].lstrip().startswith(('routed ', '`routed` ')):
                prev_label = parts[-2].split(':')[0].strip()
                is_request = prev_label.strip('`') == 'request'
                if (is_request and not did_not_last_request) or (not is_request and not did_not_last_payload):
                    swapped = parts[:-2] + [parts[-1], parts[-2]]
                    new = text[:fn['params_start']] + ', '.join(swapped) + text[fn['params_end']:]
                    results.append((new, dict(
                        site=f'routed: before {prev_label} on {fn["name"]}', role='value',
                        refusal=r'Take the routed payload last, labeled routed:\.',
                        token=r'routed')))
                    if is_request:
                        did_not_last_request = True
                    else:
                        did_not_last_payload = True
        # 4b. Duplicate `routed:` parameter.
        if not did_dup:
            new = text[:fn['params_end']] + ', routed fuzzSecond: Swift::Int' + text[fn['params_end']:]
            results.append((new, dict(
                site=f'duplicate routed: on {fn["name"]}', role='value',
                refusal=r'Take the routed payload once, in the last parameter, labeled routed:\.',
                token=r'routed')))
            did_dup = True
        # 4c. Confirmed `Swift::Never` routed payload via schema alias (strip parameter ownership and replace body so
        #     the macro anchors directly at `FuzzNever` and Swift emits no unrelated body/ownership errors).
        if not did_never:
            never_alias = fresh_identifier(text, 'FuzzNever')
            brace = text.find('{', fn['after'])
            body_end = brace + len(body_of(text, re.compile(r'\{').match(text, brace))) + 2 if brace > 0 else fn['after']
            new = text[:item['modifiers_start']] + never_alias + text[item['type_end']:brace] + '{ fatalError() }' + text[body_end:]
            new = insert_in_schema(new, f'fileprivate typealias {never_alias} = Swift::Never', item['param_start'])
            if new:
                results.append((new, dict(
                    site=f'routed: {never_alias} (Never) on {fn["name"]}', role='value',
                    refusal=rf"Transition '{re.escape(fn['name'])}' cannot take a routed: payload of type Never\.",
                    token=re.escape(never_alias))))
                did_never = True
        # 4d. Promoting a `fileprivate @Route` to `public` when a candidate takes a `fileprivate` routed struct in a
        #     `public` schema.
        if not did_public_leak:
            schema = schema_of(text, item['param_start'])
            bare = item['type_text'].strip('`')
            if (schema and re.search(r'\bpublic\s+(?:\w+\s+)*enum\s+`?' + re.escape(schema) + r'\b', text)
                    and re.search(rf'\bfileprivate\s+(?:struct|enum)\s+`?{re.escape(bare)}`?\b', text)):
                attr = text[fn['attribute_at']:fn['func_at']]
                trig = re.search(r'(on|onSuccess|onFailure)\s*:\s*([\w.]+)', attr)
                route_fn = next((r for r in functions if r['attribute'] == 'Route'
                                 and trig and re.search(rf'{trig.group(1)}\s*:\s*{re.escape(trig.group(2))}', text[r['attribute_at']:r['func_at']])
                                 and 'fileprivate' in r['modifiers']), None)
                if route_fn:
                    mod_start = text.rfind('fileprivate', route_fn['attribute_at'], route_fn['func_at'])
                    if mod_start >= 0:
                        new = text[:mod_start] + 'public' + text[mod_start + len('fileprivate'):]
                        results.append((new, dict(
                            site=f'public @Route {route_fn["name"]} exposes fileprivate {bare}', role='value',
                            refusal=rf"Declare '{re.escape(bare)}' public: the public schema '{re.escape(schema)}' generates public members that name it.*",
                            token=re.escape(bare))))
                        did_public_leak = True
        # 4e. Partially routed multi-source `from:` transition with `routed:`: add an unrouted phase to `from:`.
        if not did_partial_from and fn['has_from']:
            attr_start, attr_end = fn['attribute_at'], fn['func_at']
            attr = text[attr_start:attr_end]
            from_list = re.search(r'(?<![\w`])`?from`?\s*:\s*\[([^\]]+)\]', attr)
            if from_list:
                listed = [re.sub(r'\.\s*`?self`?\s*$', '', s).strip().strip('`') for s in split_top(from_list.group(1))]
                # Find a non-terminal phase in the same schema not in `listed` and not routed for this trigger.
                schema = schema_of(text, attr_start)
                body = schema_body(text, schema) if schema else ''
                direct = direct_member_text(body)
                term_cases = set(re.findall(r'@Terminal[^\n]*\bcase\s+`?(\w+)`?', direct))
                candidates = [core_name(p) for name, _, p in direct_case_items(body, direct)
                              if p is not None and name not in term_cases and core_name(p) not in listed]
                if candidates:
                    extra = candidates[0]
                    abs_close = attr_start + from_list.end(1)
                    new = text[:abs_close] + f', {extra}.self' + text[abs_close:]
                    results.append((new, dict(
                        site=f'partially routed from: +{extra} on {fn["name"]}', role='value',
                        refusal=rf"Transition '{re.escape(fn['name'])}' takes a routed: parameter, but no @Route selects it from '{re.escape(extra)}'; every source phase in from: must be routed, or remove routed:\.",
                        token=r'routed')))
                    did_partial_from = True
    return results


def find_generic_from_functions(text):
    """Multi-source `@Transition(from: ...)` functions declaring a single generic `<Source...>` type parameter."""
    found = []
    for fn in authored_functions_at(text):
        if fn['attribute'] != 'Transition' or not fn['has_from'] or not fn['generic']:
            continue
        inner = fn['generic'][1:-1].strip()
        parts = split_top(inner)
        if len(parts) != 1 or parts[0].strip().startswith('each '):
            continue
        param_name, sep, constraint = parts[0].partition(':')
        param_name = param_name.strip().strip('`')
        constraint = constraint.strip() if sep else ''
        where_match = re.search(r'\bwhere\s+([^\n{]+)', fn['effects'])
        found.append(dict(
            function=fn,
            param=param_name,
            constraint=constraint,
            where_match=where_match,
        ))
    return found


@rewrite('generic-source-where', 'eq', 'A generic multi-source transition may constrain its source inline or in a where clause, under any parameter name')
def _(text, rng):
    """Equivalent rewrites of a generic `<Source>` multi-source transition: moving the constraint between `<Source: P>`
    and trailing `where Source: P`, and renaming the generic source parameter `<Source>` -> `<FuzzPhaseSource>`."""
    results = []
    for item in find_generic_from_functions(text):
        fn = item['function']
        param = item['param']
        constraint = item['constraint']
        where_match = item['where_match']
        # 1. Move inline constraint `<Source: P>` to trailing `where Source: P` (only when not `~Copyable`, which Swift
        #    forbids in trailing `where` clauses).
        if constraint and not where_match and '~' not in constraint:
            brace = text.find('{', fn['after'])
            if brace > 0:
                new = (text[:fn['generic_at']] + f'<{param}>' + text[fn['generic_end']:brace].rstrip()
                       + f' where {param}: {constraint} ' + text[brace:])
                results.append((new, dict(site=f'move {param}: {constraint} to where on {fn["name"]}', role='value')))
        # 2. Move trailing `where Source: P` inline into `<Source: P>`.
        if where_match and not constraint:
            where_clause = where_match.group(1).strip()
            simple = re.fullmatch(rf'`?{re.escape(param)}`?\s*:\s*(.+)', where_clause)
            if simple:
                w_start = fn['after'] + where_match.start()
                w_end = fn['after'] + where_match.end()
                before_w = text[fn['generic_end']:w_start].rstrip()
                after_w = text[w_end:]
                new = text[:fn['generic_at']] + f'<{param}: {simple.group(1).strip()}>' + before_w + ' ' + after_w.lstrip()
                results.append((new, dict(site=f'inline where {where_clause} on {fn["name"]}', role='value')))
        # 3. Rename the generic source parameter `<Source>` -> `<FuzzPhaseSource>` inside the function declaration.
        fresh = fresh_identifier(text, 'FuzzPhaseSource')
        start, end = function_block(text, fn)
        block = text[start:end]
        renamed_block = re.sub(r'(?<![\w.`])' + re.escape(param) + r'(?![\w`])', fresh, block)
        if renamed_block != block:
            results.append((text[:start] + renamed_block + text[end:], dict(site=f'rename <{param}> -> <{fresh}> on {fn["name"]}', role='value')))
    return results


@rewrite('generic-source-invalid', 'break', 'A multi-source transition may declare at most one generic source parameter used only for its source and same-phase destination')
def _(text, rng):
    """Invalid generic `<Source>` multi-source forms with exact macro diagnostics and token anchors."""
    results = []
    items = find_generic_from_functions(text)
    if not items:
        return results
    did_multi, did_pack, did_first, did_payload, did_throws, did_routed, did_advance, did_ineligible = (False,) * 8
    for item in items:
        fn = item['function']
        param = item['param']
        brace = text.find('{', fn['after'])
        body_end = brace + len(body_of(text, re.compile(r'\{').match(text, brace))) + 2 if brace > 0 else fn['after']
        is_noncopyable = '~' in item['constraint']
        # 1. Multiple generic parameters `<Source, FuzzExtra>` (use `FuzzExtra` in a parameter so Swift emits no
        #    `#NoUsage` warning beside the macro refusal).
        if not did_multi:
            extra = fresh_identifier(text, 'FuzzExtra')
            sep = ', ' if text[fn['params_start']:fn['params_end']].strip() else ''
            new = (text[:fn['generic_end'] - 1] + f', {extra}' + text[fn['generic_end'] - 1:fn['params_end']]
                   + f'{sep}_ fuzzExtra: {extra}' + text[fn['params_end']:brace] + '{ fatalError() }' + text[body_end:])
            results.append((new, dict(
                site=f'two generics <{param}, {extra}> on {fn["name"]}', role='value',
                refusal=r'A multi-source transition may declare at most one generic type parameter for its source phase\.',
                token=re.escape(extra))))
            did_multi = True
        # 2. Parameter pack `<each Source>` (keep valid Swift pack syntax in the signature and body so only the
        #    macro refusal fires).
        if not did_pack:
            payloads = sorted(phase_payloads(text))
            ret_type = payloads[0] if payloads else 'Swift::Void'
            new = text[:fn['generic_at']] + f'<each {param}>(_ source: repeat each {param}) -> {ret_type} {{ fatalError() }}' + text[body_end:]
            results.append((new, dict(
                site=f'pack <each {param}> on {fn["name"]}', role='value',
                refusal=r"A multi-source transition's generic parameter must be a single type parameter for its source phase\.",
                token=r'each')))
            did_pack = True
        # 3. Concrete phase payload in first parameter instead of generic `Source`.
        if not did_first:
            payloads = sorted(phase_payloads(text))
            if payloads:
                concrete = payloads[0]
                params_text = text[fn['params_start']:fn['params_end']]
                first_param = re.search(r'(:\s*' + MODIFIERS + r')' + re.escape(param) + r'(?![\w`])', params_text)
                if first_param:
                    abs_start = fn['params_start'] + first_param.end(1)
                    abs_end = abs_start + len(param)
                    new = text[:abs_start] + concrete + text[abs_end:brace] + '{ fatalError() }' + text[body_end:]
                    results.append((new, dict(
                        site=f'concrete first param {concrete} on generic {fn["name"]}', role='value',
                        refusal=rf"Use the generic source parameter '{re.escape(param)}' as the first parameter of this multi-source transition\.",
                        token=re.escape(concrete))))
                    did_first = True
        # 4. Trigger payload parameter referencing generic `Source`.
        if not did_payload and not fn['has_routed']:
            params_text = text[fn['params_start']:fn['params_end']]
            parts = split_top(params_text)
            if len(parts) == 2:
                second_offset = fn['params_start'] + len(parts[0]) + 1
                m = re.match(r'\s*(?:`?\w+`?\s+)?`?\w+`?\s*:\s*' + MODIFIERS, parts[1])
                if m:
                    t_start = second_offset + m.end()
                    t_end = fn['params_end']
                    replacement = f'borrowing {param}' if is_noncopyable else param
                    new = text[:t_start] + replacement + text[t_end:brace] + '{ fatalError() }' + text[body_end:]
                    results.append((new, dict(
                        site=f'payload references {param} on {fn["name"]}', role='value',
                        refusal=rf"A trigger payload parameter cannot reference the generic source parameter '{re.escape(param)}'\.",
                        token=r'borrowing' if is_noncopyable else re.escape(param))))
                    did_payload = True
        # 5. Thrown failure type referencing generic `Source` (only when `Source` is `Copyable`, since `Error` requires
        #    `Copyable`; constrain `Source: Swift::Error` so Swift itself accepts `throws(Source)`).
        if not did_throws and not is_noncopyable and 'throws' not in fn['effects']:
            arrow = fn['effects'].find('->')
            if arrow >= 0:
                at = fn['after'] + arrow
                if item['constraint']:
                    head = text[:fn['generic_end'] - 1] + ' & Swift::Error' + text[fn['generic_end'] - 1:at]
                else:
                    head = text[:fn['generic_end'] - 1] + ': Swift::Error' + text[fn['generic_end'] - 1:at]
                new = head + f'throws({param}) ' + text[at:brace] + '{ fatalError() }' + text[body_end:]
                results.append((new, dict(
                    site=f'throws({param}) on {fn["name"]}', role='value',
                    refusal=rf"A thrown failure type cannot reference the generic source parameter '{re.escape(param)}'\.",
                    token=r'throws')))
                did_throws = True
        # 6. `routed:` parameter referencing generic `Source`.
        if not did_routed and fn['has_routed']:
            routed_item = next((r for r in find_routed_params(text) if r['function']['func_at'] == fn['func_at']), None)
            if routed_item:
                new = text[:routed_item['type_start']] + param + text[routed_item['type_end']:brace] + '{ fatalError() }' + text[body_end:]
                results.append((new, dict(
                    site=f'routed: references {param} on {fn["name"]}', role='value',
                    refusal=rf"A routed: parameter cannot reference the generic source parameter '{re.escape(param)}'\.",
                    token=re.escape(param))))
                did_routed = True
        # 7. `.ownedOnly` `Advance<ConcretePhase, Source, ...>` using concrete phase as before-type.
        if not did_advance:
            adv = re.search(rf'\bAdvance<\s*({re.escape(param)})\s*,', fn['effects'])
            payloads = sorted(phase_payloads(text))
            if adv and payloads:
                concrete = payloads[0]
                abs_start = fn['after'] + adv.start(1)
                abs_end = fn['after'] + adv.end(1)
                new = text[:abs_start] + concrete + text[abs_end:brace] + '{ fatalError() }' + text[body_end:]
                results.append((new, dict(
                    site=f'Advance<{concrete}, ...> on generic {fn["name"]}', role='value',
                    refusal=rf"Use the generic source parameter '{re.escape(param)}' as the source type of Advance\.",
                    token=re.escape(concrete))))
                did_advance = True
        # 8. Same-phase `-> Change<Source, ...>` starting an `@Operation` ineligible in one of `from:`'s phases.
        if not did_ineligible and re.search(rf'\bChange<\s*{re.escape(param)}\s*,', fn['effects']):
            attr_start, attr_end = fn['attribute_at'], fn['func_at']
            attr = text[attr_start:attr_end]
            schema = schema_of(text, attr_start)
            body = schema_body(text, schema) if schema else ''
            direct = direct_member_text(body)
            sets = phase_sets(direct)
            from_list = re.search(r'(?<![\w`])`?from`?\s*:\s*\[([^\]]+)\]', attr)
            from_set = re.search(r'(?<![\w`])`?from`?\s*:\s*(' + IDENT_TOKEN + r')\s*\.\s*`?self`?(?![\w`])', attr)
            phases = ([core_name(re.sub(r'\.\s*`?self`?\s*$', '', s)) for s in split_top(from_list.group(1))] if from_list
                      else sets.get(from_set.group(1).strip('`'), []) if from_set else [])
            if len(phases) >= 2 and 'starts:' not in attr:
                op_name = fresh_identifier(text, 'FuzzLimitedOp')
                active_first, missing_second = phases[0], phases[1]
                access = re.search(r'\b(public|package)\s+(?:\w+\s+)*enum\s+`?' + re.escape(schema) + r'\b', text) if schema else None
                acc = f'{access.group(1)} ' if access else ''
                op_decl = f'@Operation(activeIn: [{active_first}.self])\n    {acc}enum {op_name} {{}}'
                # Insert `starts: [FuzzLimitedOp.self]` before `emits:`/`cancels:`/`invalidates:` to preserve
                # `@Transition` argument order, and replace the body so Swift does not emit an extra `Effect` error.
                emits_match = re.search(r'\b(?:emits|cancels|invalidates)\s*:', text[attr_start:attr_end])
                close_paren = text.find(')', attr_start, attr_end)
                brace = text.find('{', fn['after'])
                body_end = brace + len(body_of(text, re.compile(r'\{').match(text, brace))) + 2 if brace > 0 else fn['after']
                if emits_match:
                    insert_at = attr_start + emits_match.start()
                    new = text[:insert_at] + f'starts: [{op_name}.self], ' + text[insert_at:brace] + '{ fatalError() }' + text[body_end:]
                elif close_paren > 0:
                    new = text[:close_paren] + f', starts: [{op_name}.self]' + text[close_paren:brace] + '{ fatalError() }' + text[body_end:]
                else:
                    new = None
                if new:
                    new = insert_in_schema(new, op_decl, attr_start)
                if new:
                    results.append((new, dict(
                        site=f'same-phase starts [{op_name}.self] ineligible in {missing_second}', role='value',
                        refusal=rf"Started operation '{re.escape(op_name)}' and every required scope must be eligible in destination '{re.escape(missing_second)}'\.",
                        token=rf'{re.escape(op_name)}\.self')))
                    did_ineligible = True
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
    """Each schema's name as file-scope code spells it: `FuzzOuter.Flow` for one a rewrite nested, `Left.Flow` for one
    declared in an extension of an enclosing type, none for one declared in a function body."""
    return {path.split('.')[-1]: path for path in schema_path_list(text)}


def schema_path_list(text):
    """Every schema's path, in declaration order, two schemas of one basename in different enclosing types kept apart."""
    paths = []
    if 'func fuzzLocalSchema()' in text:
        return paths
    mask = code_mask(text)
    for match in re.finditer(r'(?:// fuzz-outer: (\S+)\n[^\n]*\n)?(?:@available\([^)]*\)\s*\n)?(@StateMachine)\([^)]*\)\s*(?:@\w+(?:\([^)]*\))?\s*)*(?:\w+\s+)*enum\s+`?(\w+)`?', text):
        if not mask[match.start(2)]:
            continue
        if match.group(1):
            paths.append(f'{match.group(1)}.{match.group(3)}')
            continue
        # The enclosing types the declaration stands in, outermost first, from the braces open before it.
        stack = []
        identifier = r'(?:`[^`\n]+`|\w+)'
        path = identifier + r'(?:\.' + identifier + r')*'
        for opener in re.finditer(r'\b(?:extension|enum|struct|class|actor)\s+(' + path + r')[^{;]*\{|[{}]', text[:match.start()]):
            if not mask[opener.start()]:
                continue
            token = opener.group(0)
            if token == '{':
                stack.append(None)
            elif token == '}':
                if stack:
                    stack.pop()
            else:
                stack.append(opener.group(1))
        enclosing = [s for s in stack if s]
        paths.append('.'.join(enclosing + [match.group(3)]))

    return paths


def module_text(text):
    """Every source file of the schema's module, joined, without the client section."""
    files, _ = split_case(text)
    return '\n'.join(files.values())


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
# Graph names that decoded metadata can carry and a Swift identifier cannot: an entity-like ampersand, a backslash,
# and a quotation mark, each of which a DOT header must quote so that the grammar reads the name itself.
NAMED_GRAPHS = ['R&D', 'R&amp;D', 'a\\b', 'say "hi"']


def graph_accessor(text, paths):
    """Return a module-level `fuzzGraphs()` accessor for `paths`, wrapped in any `#available` guard `text` requires."""
    graphs = ', '.join(f'{schema}.graph' for schema in paths)
    guard = availability_guard(text)
    body = f'if #available({guard}) {{ return [{graphs}] }}; return []' if guard and graphs else f'[{graphs}]'
    return '\n' + HARNESS_MARKER + f'func fuzzGraphs() -> [StateMachine::StateMachineGraph] {{ {body} }}\n'


def harness(text):
    """A main, in its own module, that prints every schema's graph and both renderings, and the seed's report."""
    body = ['        for graph in Fz::fuzzGraphs() { fuzzPrint(graph) }']
    if re.search(r'^func fuzzReport\(\)', text, re.M):
        body.append('        Swift::print("report:", Fz::fuzzReport())')
    # A report that waits for a managed owner's drivers.
    asynchronous = re.search(r'^@MainActor func fuzzReportAsync\(\)', text, re.M) is not None
    if asynchronous:
        body.append('        Swift::print("report:", await Fz::fuzzReportAsync())')
    guard = availability_guard(text)
    if guard:
        body = [f'        if #available({guard}) {{'] + ['    ' + line for line in body] + ['        }']
    return '\n'.join(['@testable import Fz', 'import StateMachine', 'import Foundation', '',
                      '@main struct FuzzMain {', f"    @MainActor static func main(){' async' if asynchronous else ''} {{"] + body + ['    }', '}', '',

                      'func fuzzPrint(_ graph: StateMachine::StateMachineGraph) {',
                      '    let encoder = Foundation::JSONEncoder()',
                      '    encoder.outputFormatting = [.sortedKeys]',
                      '    Swift::print("graph:", Swift::String(decoding: try! encoder.encode(graph), as: Swift::UTF8.self))',
                      '    Swift::print("mermaid:", Swift::String(decoding: try! encoder.encode(graph.mermaid()), as: Swift::UTF8.self))',
                      '    Swift::print("dot:", Swift::String(decoding: try! encoder.encode(graph.dot()), as: Swift::UTF8.self))',
                      # The graph decoded under names no Swift identifier spells, which the DOT header must quote as
                      # themselves.
                      f'    for name in {json.dumps(NAMED_GRAPHS)} {{',
                      '        guard let named = fuzzRenamed(graph, name) else { Swift::print("named: unreadable"); continue }',
                      '        Swift::print("named:", Swift::String(decoding: try! encoder.encode([named.name, named.dot()]), as: Swift::UTF8.self))',
                      '    }',
                      '}', '',
                      'func fuzzRenamed(_ graph: StateMachine::StateMachineGraph, _ name: Swift::String) -> StateMachine::StateMachineGraph? {',
                      '    guard let data = try? Foundation::JSONEncoder().encode(graph),',
                      '        var object = (try? Foundation::JSONSerialization.jsonObject(with: data)) as? [Swift::String: Any]',
                      '    else { return nil }',
                      '    object["name"] = name',
                      '    guard let renamed = try? Foundation::JSONSerialization.data(withJSONObject: object) else { return nil }',
                      '    return try? Foundation::JSONDecoder().decode(StateMachine::StateMachineGraph.self, from: renamed)',
                      '}']) + '\n'


class Toolchain:
    def __init__(self, plugin, modules, link, jobs, timeout, run):
        self.swiftc = subprocess.check_output(['xcrun', '--find', 'swiftc'], text=True).strip()
        self.sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
        self.plugin, self.modules, self.link, self.timeout, self.run = plugin, modules, link, timeout, run
        self.spelling_scope = 'written'
        self.testing_link = []

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
            # A flag replaces the default it overrides: `-default-isolation=MainActor`, `-O`, `-no-warnings-as-errors`.
            if flag.startswith('-default-isolation='):
                command[command.index('-default-isolation') + 1] = flag.split('=', 1)[1]
            elif flag == '-O':
                command[command.index('-Onone')] = '-O'
            elif flag == '-no-warnings-as-errors':
                command.remove('-warnings-as-errors')

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


def is_authored_static(line, authored, schemas=None):
    """Whether a demangled symbol is an authored static function directly on a schema."""
    if not authored:
        return False
    funcs = '|'.join(map(re.escape, authored))
    if schemas:
        paths = '|'.join(re.escape(path.replace('`', '')) for path in schemas)
        return re.match(rf'static Fz\.(?:{paths})\.(?:{funcs})(?:<|\()', line) is not None
    generated = '|'.join(set(OWNER_TYPES.values()) | {'Observed', 'Route', 'Effect', 'Prepared', 'Snapshot', 'Receipt',
                                                      'Completion', 'PendingCompletion', 'Restoration', 'Drivers', 'Command'})
    return re.match(rf'static Fz\.(?:(?!({generated})\.)[^.(]+\.)+(?:{funcs})(?:<|\()', line) is not None


def demangled_fingerprint(objects, authored, schemas=None):
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
        # A private declaration's context carries its file's discriminator, `(engine in _8D3A…)`, a hash of the file
        # name: it goes first, so the same member reads alike in any file and a discriminator that happens to
        # start with a letter is not taken for an underscored name.
        line = re.sub(r'\((\S+) in _[0-9A-F]+\)', r'\1', line)
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
        # The authored static functions themselves, on the schema (at any enclosing-type depth), are not generated.
        if is_authored_static(line, authored, schemas):
            continue
        keep.add(line)
    return sorted(keep)


def authored_functions(text):
    return sorted({m.group(1) for m in re.finditer(r'static func\s+`?([^\s(`<]+)`?', text)})


def schema_lines(text):
    """Line ranges of the schemas' declarations in a source."""
    return [(text.count('\n', 0, declaration.start()) + 1, text.count('\n', 0, end) + 1)
            for declaration, end in schema_bounds(text)]


def classify_located(text, schema_spans=None):
    """Errors with where they arise: the macro's diagnostics, its expansion, the schema's own declarations, or client
    code outside the schema, which an equivalent rewrite can break only by changing what the macro generates. Each is
    (place, message, file name, line)."""
    errors = []
    for path, line, column, message in ERROR.findall(text):
        macro = '(from macro' in message
        # Without the macro's suffix and the compiler's diagnostic group (`[#NoUsage]`).
        message = re.sub(r'\s*\[#\w+(?:::\w+)*\]$', '', re.sub(r'\s*\(from macro \'\w+\'\)', '', message).strip())
        name = os.path.basename(path)
        place = 'macro' if macro else ('expansion' if '@__swiftmacro' in path or 'macro expansion' in path else 'authored')
        if place == 'authored':
            in_schema = (name == 'Case.swift' if schema_spans is None else
                         any(a <= int(line) <= b for a, b in schema_spans.get(name, ())))
            if not in_schema:
                place = 'client'
        if name in ('Main.swift',) and place == 'client':
            place = 'harness'
        error = (place, message, name, int(line))
        if error not in errors:
            errors.append(error)
    return errors


def columns_of(text):
    """Each error's (message without the macro's suffix, file name, line) with its column, in the order reported."""
    found = []
    for path, line, column, message in ERROR.findall(text):
        message = re.sub(r'\s*\[#\w+(?:::\w+)*\]$', '', re.sub(r'\s*\(from macro \'\w+\'\)', '', message).strip())
        found.append(((message, os.path.basename(path), int(line)), int(column)))

    return found


def classify(text, schema_spans=None):
    unique = []
    for place, message, _, _ in classify_located(text, schema_spans):
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
        source = module_text(text)
        graph_paths = schema_path_list(source)
        harness_from = files['Case.swift'].count('\n') + 2
        files['Case.swift'] += graph_accessor(source, graph_paths)
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
    spans = {name: schema_lines(source) for name, source in files.items()}
    located = [(('harness' if harness_from and name == 'Case.swift' and line >= harness_from else place), message, name, line)
               for place, message, name, line in classify_located(log, spans)]
    outcome = dict(seconds=round(elapsed, 2), errors=[(p, m) for p, m, _, _ in located], located=located, command=command,
                   peak_mb=result.peak_mb, columns=columns_of(log),
                   client_sites=[(name, line) for place, _, name, line in located if place == 'client' and name in files])
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
    outcome['fingerprint'] = demangled_fingerprint([output], authored_functions(text), schema_path_list(module_text(text)))
    outcome['label_problems'] = label_order_problems(outcome['fingerprint'], text)
    if toolchain.run:
        # The harness and the client section form a module of their own that imports the schema's module, so the
        # client sees the schema as another module does.
        (directory / 'Main.swift').write_text(harness(text))
        mains = [directory / 'Main.swift']
        if client is not None:
            (directory / 'Client.swift').write_text(order_client_arguments(client, text.split(CLIENT_MARKER, 1)[0]))
            mains.append(directory / 'Client.swift')
        # A client may call a deprecated generated member, whose warning the fix-it oracle reads.
        linker = (toolchain.base('FzMain') + ['-Wwarning', 'DeprecatedDeclaration', '-I', str(module_directory)]
                  + [str(m) for m in mains] + [str(output)] + toolchain.link
                  + (toolchain.testing_link if re.search(r'^\s*import StateMachineTesting\b', text, re.M) else [])
                  + ['-o', str(directory / 'case')])
        linked = watched(linker, toolchain.timeout)
        if linked.verdict != 'ok' or linked.returncode != 0:
            located = classify_located(linked.stdout)
            outcome['located'] = outcome['located'] + located
            outcome['errors'] = [(p, m) for p, m, _, _ in located] or [('link', linked.stdout[-300:])]
            outcome['client_sites'] = [(name, line) for p, _, name, line in located if p == 'client']
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
        if client is not None and 'is deprecated' in linked.stdout:
            outcome['fixit_problems'] = fixit_problems(toolchain, directory, module_directory, mains)
        ran = watched([str(directory / 'case')], 60)
        (directory / 'case').unlink(missing_ok=True)
        if ran.verdict != 'ok' or ran.returncode != 0:
            outcome['status'] = {'timeout': 'run-timeout', 'memory': 'run-memory'}.get(ran.verdict, 'run-failed')
            outcome['crash'] = f'the program {ran.verdict if ran.verdict != "ok" else "exited " + str(ran.returncode)}: {ran.stdout[-300:]}'
            outcome['errors'] = [('run', outcome['crash'])]
            return outcome
        graphs = raw_graphs(ran.stdout)
        outcome['run'] = normalize_run(ran.stdout)
        outcome['graph_paths'] = graph_paths
        outcome['report'] = next((line[len('report: '):] for line in ran.stdout.splitlines() if line.startswith('report: ')), None)
        outcome['spellings'] = sorted({json.dumps(g, sort_keys=True) for g in graphs})
        outcome['diagram_problems'] = diagram_problems(ran.stdout)
        outcome['text_problems'] = exported_text_problems(text, graphs)
        if probe is True or (callable(probe) and probe(outcome['spellings'], text)):
            outcome['spelling_problems'] = check_spellings(toolchain, directory, text, graphs, flags)
    outcome['inventory_problems'] = inventory_problems(text, outcome, toolchain.run)
    output.unlink(missing_ok=True)
    return outcome


# --- Deprecation fix-its ------------------------------------------------------------------------------------------
# A generated member that repeats a rename must offer a fix-it its caller can apply: the client section, with every
# fix-it of a deprecation warning applied as the compiler prints it, must compile without that warning.

DEPRECATION = re.compile(r"^(?P<file>[^\n:]+):(?P<line>\d+):(?P<column>\d+): warning: '[^']*' is deprecated(?P<rest>[^\n]*)$", re.M)


def fixit_edits(log, name='Client.swift'):
    """(renaming deprecations, edits) in `name` from an `-diagnostic-style llvm` log: each deprecation warning that
    names a replacement, and each edit of a `use '…' instead` note, as (line, column, length, replacement), read from
    the note's range markers and the replacement line beneath them."""
    lines = log.split('\n')
    renaming, edits = [], []
    for index, line in enumerate(lines):
        warning = DEPRECATION.match(line)
        if warning and warning.group('file').endswith(name) and re.search(r': (renamed to|replaced by) ', warning.group('rest')):
            renaming.append((int(warning.group('line')), int(warning.group('column'))))
        note = re.match(r"^([^\n:]+):(\d+):(\d+): note: use '[^']*' instead", line)
        if not note or not note.group(1).endswith(name) or index + 3 >= len(lines):
            continue
        markers, replacement = lines[index + 2], lines[index + 3]
        runs = list(re.finditer(r'[\^~]+', markers))
        for number, run in enumerate(runs):
            end = runs[number + 1].start() if number + 1 < len(runs) else len(replacement)
            text = replacement[run.start():end].rstrip()
            edits.append((int(note.group(2)), run.start() + 1, len(run.group()), text))
    return renaming, edits


def apply_edits(text, edits):
    """`text` with each (line, column, length, replacement) edit applied, later columns first."""
    lines = text.split('\n')
    for line, column, length, replacement in sorted(edits, key=lambda e: (e[0], -e[1])):
        if 0 < line <= len(lines):
            current = lines[line - 1]
            lines[line - 1] = current[:column - 1] + replacement + current[column - 1 + length:]
    return '\n'.join(lines)


def fixit_judgement(renaming, edits, after_code, after_log, name='Client.swift'):
    """Problems of a client whose deprecation fix-its were applied: every renaming deprecation offers one, and the
    client then compiles without a renaming deprecation."""
    problems = []
    if renaming and not edits:
        problems.append(f'deprecation fix-it: a renamed generated member at {renaming[0]} offers no fix-it')
    if after_code != 0:
        first = next((m for _, _, _, m in ERROR.findall(after_log)), after_log.strip()[-200:])
        problems.append(f'deprecation fix-it: the client does not compile with the fix-it applied: {first}')
    elif fixit_edits(after_log, name)[0]:
        problems.append('deprecation fix-it: the client still calls a renamed deprecated member once the fix-it is applied')
    return problems


def fixit_problems(toolchain, directory, module_directory, mains):
    """Applies the client's deprecation fix-its and typechecks the result."""
    client = directory / 'Client.swift'
    command = (toolchain.base('FzMain') + ['-Wwarning', 'DeprecatedDeclaration', '-diagnostic-style', 'llvm', '-I',
               str(module_directory), '-typecheck'])
    before = watched(command + [str(m) for m in mains], toolchain.timeout)
    if before.verdict != 'ok':
        return [f'deprecation fix-it: the client typecheck {before.verdict}']
    renaming, edits = fixit_edits(before.stdout)
    fixed = directory / 'Fixed.swift'
    fixed.write_text(apply_edits(client.read_text(), edits))
    after = watched(command + [str(m) for m in mains if m != client] + [str(fixed)], toolchain.timeout)
    if after.verdict != 'ok':
        return [f'deprecation fix-it: the fixed client typecheck {after.verdict}']
    return fixit_judgement(renaming, edits, after.returncode, after.stdout, 'Fixed.swift')


# --- What the input declares --------------------------------------------------------------------------------------
# Counted from the source, so an output that leaves a schema, a field, or a symbol out cannot remove its own check.

def schema_body(text, schema):
    """The body of the schema `schema` (a basename), or None."""
    opened, closed = schema_opening(text, schema)
    return None if opened is None else text[opened:closed]


def direct_lines(body):
    """The lines of `body` at its own brace depth, without comments."""
    out, depth = [], 0
    for line in strip_comments(body).split('\n'):
        if depth == 0:
            out.append(line)
        depth += line.count('{') - line.count('}')
    return out


def declared_inventory(text, schema):
    """What a schema declares: its phases, Input cases, operations, and events, by name, in declaration order."""
    body = schema_body(text, schema)
    if body is None:
        return None
    phases, initial, terminal, pending = [], [], [], ''
    for line in direct_lines(body):
        found = re.match(r'(\s*(?:@[\w.]+(?:\([^)]*\))?\s+)*)case\s+(.*)$', line)
        if found:
            # A marker applies to every case of its declaration, written on the line or on lines of its own above.
            markers = pending + found.group(1)
            pending = ''
            for item in split_top(found.group(2)):
                named = re.match(r'\s*`?(\w+)`?\s*\(', item)
                if named:
                    phases.append(named.group(1))
                    if re.search(r'@(?:StateMachine\.)?Initial\b', markers):
                        initial.append(named.group(1))
                    if re.search(r'@(?:StateMachine\.)?Terminal\b', markers):
                        terminal.append(named.group(1))
        elif re.fullmatch(r'\s*(?:@[\w.]+(?:\([^)]*\))?\s*)+', line):
            pending += line + ' '
        elif line.strip():
            pending = ''
    inputs = []
    opened = re.search(r'enum\s+Input\b[^{]*\{', body)
    if opened:
        for case in re.finditer(r'\bcase\s+([^\n;}]+)', strip_comments(body_of(body, opened))):
            inputs += [re.match(r'\s*`?(\w+)', item).group(1) for item in split_top(case.group(1)) if re.match(r'\s*`?\w', item)]
    for extension in re.finditer(r'extension\s+(?:\w+\.)*' + re.escape(schema.partition('#')[0]) + r'\.Input\b[^{]*\{', text):
        for case in re.finditer(r'\bcase\s+([^\n;}]+)', strip_comments(body_of(text, extension))):
            inputs += [re.match(r'\s*`?(\w+)', item).group(1) for item in split_top(case.group(1)) if re.match(r'\s*`?\w', item)]
    def namespaces(marker):
        found, plain = [], strip_comments(body)
        for head in re.finditer(r'@(?:StateMachine(?:::|\.))?' + marker + r'\b', plain):
            index = head.end()
            if plain[index:index + 1] == '(':
                depth = 0
                while index < len(plain):
                    depth += {'(': 1, ')': -1}.get(plain[index], 0)
                    index += 1
                    if depth == 0:
                        break
            named = re.match(r'\s*(?:@[\w.]+(?:\([^)]*\))?\s*)*(?:\w+\s+)*enum\s+`?(\w+)', plain[index:])
            if named:
                found.append(named.group(1))
        return found
    return dict(phases=phases, inputs=inputs, operations=namespaces('Operation'), events=namespaces('Event'),
                initial=initial, terminal=terminal)


def inventory_problems(text, outcome, ran=True):
    """A compiled case's output measured against its input: symbol extraction succeeded, every schema the module
    declares printed a graph, and each graph holds every phase, Input case, operation, and event the schema declares.
    An empty outcome is a failure."""
    if outcome.get('status') != 'ok':
        return []
    problems = []
    if not outcome.get('fingerprint'):
        problems.append('inventory: no generated symbol was extracted')
    if not ran:
        return problems
    source = module_text(text)
    paths = schema_path_list(source)
    graphs = [json.loads(line[7:]) for line in outcome.get('run', []) if line.startswith('graph: ')]
    if not outcome.get('run') and (paths or re.search(r'^func fuzzReport\(\)', text, re.M)):
        problems.append('inventory: the program printed nothing')
    names = collections.Counter(g.get('name') for g in graphs)
    wanted = collections.Counter(path.split('.')[-1] for path in paths)
    if names != wanted:
        problems.append(f'inventory: the module declares the schemas {sorted(wanted.elements())}, the run printed graphs of {sorted(names.elements())}')
    for graph, key in zip(graphs, graph_keys(graphs)):
        declared = declared_inventory(source, key)
        if declared is None:
            continue
        for field, key in (('phases', 'phases'), ('inputs', 'inputs'), ('operations', 'operations'), ('events', 'events')):
            got = sorted(record['id'] for record in graph.get(key, []))
            if got != sorted(declared[field]):
                problems.append(f"inventory {graph.get('name')} {field}: declared {sorted(declared[field])}, exported {got}")
        # The markers, read from the source, so a consistently wrong initial or terminal phase cannot agree with itself.
        if len(declared['initial']) == 1 and graph.get('initial') != declared['initial'][0]:
            problems.append(f"inventory {graph.get('name')} initial: declared {declared['initial'][0]!r}, exported {graph.get('initial')!r}")
        if sorted(graph.get('terminal', [])) != sorted(declared['terminal']):
            problems.append(f"inventory {graph.get('name')} terminal: declared {sorted(declared['terminal'])}, exported {sorted(graph.get('terminal', []))}")
    return problems


# --- Exported text ----------------------------------------------------------------------------------------------------
# Each exported type spelling is the author's own text, on one line without comments (ExportingAGraph.md). The expected
# text comes from the source: the payload as the case writes it, the alias an operation or event namespace declares, or
# `Swift::Void` and `Swift::Never` for one it omits.

def one_line(spelling):
    return ' '.join(strip_comments(spelling).split())


def namespace_member(text, schema, namespace, member):
    """The text a namespace of the schema gives `member`: its alias's right-hand side, the member's own name for a
    nested type, or None."""
    bodies = []
    opening = find_schema(text, schema)
    if opening:
        inner = re.search(r'enum\s+`?' + re.escape(namespace) + r'`?\s*(?::[^{]*)?\{', body_of(text, opening))
        if inner:
            bodies.append(body_of(body_of(text, opening), inner))
    for extension in re.finditer(r'extension\s+(?:\w+\.)*' + re.escape(schema.partition('#')[0]) + r'\.' + re.escape(namespace) + r'\b[^{]*\{', text):
        bodies.append(body_of(text, extension))
    for body in bodies:
        for line in direct_lines(body):
            alias = re.search(r'\btypealias\s+`?' + re.escape(member) + r'`?\s*=\s*(.*?)\s*(?:;|$)', line)
            if alias:
                return alias.group(1).rstrip('}').strip()
            if re.search(r'\b(?:struct|enum|class|actor)\s+`?' + re.escape(member) + r'\b', line):
                return member
    return None


def expected_texts(text, graph, key=None):
    """The text each spelled field of a graph must export, by site; `key` tells apart schemas of one basename."""
    schema = key or graph.get('name', '')
    phases, inputs = authored_payloads(text, schema)
    expected = {}
    for phase in graph.get('phases', []):
        if phase['id'] in phases:
            expected[f"{schema} phase {phase['id']} payload"] = (phase.get('payload'), phases[phase['id']])
    for case in graph.get('inputs', []):
        if case['id'] in inputs:
            expected[f"{schema} input {case['id']} payload"] = (case.get('payload'), inputs[case['id']])
    for operation in graph.get('operations', []):
        for field, member, default in (('input', 'Input', 'Swift::Void'), ('output', 'Output', 'Swift::Void'),
                                       ('failure', 'Failure', 'Swift::Never'), ('key', 'Key', None)):
            authored = namespace_member(text, schema, operation['id'], member) or default
            expected[f"{schema} operation {operation['id']} {field}"] = (operation.get(field), authored)
    for event in graph.get('events', []):
        authored = namespace_member(text, schema, event['id'], 'Payload') or 'Swift::Void'
        expected[f"{schema} event {event['id']} payload"] = (event.get('payload'), authored)
    return expected


def exported_text_problems(text, graphs):
    """Each spelled field whose exported text is not the author's own, on one line without comments."""
    source = module_text(text)
    problems = []
    keys = graph_keys(graphs)
    for graph in graphs:
        for site, (exported, authored) in sorted(expected_texts(source, graph, keys[graphs.index(graph)]).items()):
            # Only the source is normalized: the export itself must already be the one-line text.
            if (exported is None) != (authored is None) or (exported is not None and exported != one_line(authored)):
                problems.append(f'{site}: exported text {exported!r}, the author wrote {authored!r}')
    return problems


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


def direct_member_text(body):
    """Mask nested brace bodies, comments, and literals with spaces, preserving newlines and direct-member offsets."""
    depth, out = 0, []
    for char, code in zip(body, code_mask(body)):
        if code and char == '}':
            depth -= 1
        out.append(char if (code and depth == 0) or char == '\n' else ' ')
        if code and char == '{':
            depth += 1
    return ''.join(out)


def direct_case_items(body, direct=None):
    """Each direct enum case's name, offset, and optional payload spelling, including multiline case lists."""
    if direct is None:
        direct = direct_member_text(body)
    name = re.compile(r'\s*`?(\w+)`?\s*')
    separator = re.compile(r'\s*,')
    for declaration in re.finditer(r'\bcase\s+', direct):
        index = declaration.end()
        while match := name.match(direct, index):
            index, payload = match.end(), None
            if direct[index:index + 1] == '(':
                start = index + 1
                depth, index = 1, start
                while index < len(direct) and depth:
                    depth += {'(': 1, ')': -1}.get(direct[index], 0)
                    index += 1
                payload = split_top(strip_comments(body[start:index - 1]))[0].split('=')[0].strip()
            yield match.group(1), match.start(1), payload
            comma = separator.match(direct, index)
            if not comma:
                break
            index = comma.end()


def case_namespace(body, direct, name):
    opened = re.search(r'\benum\s+`?' + name + r'`?(?![\w`])[^{]*\{', direct)
    return body_of(body, opened) if opened else ''


def authored_payloads(text, schema):
    """The authored payload spellings of a schema's phases and Input cases, by case name."""
    body = schema_body(text, schema) or ''
    inputs = case_namespace(body, direct_member_text(body), 'Input')
    return tuple({name: payload for name, _, payload in direct_case_items(source) if payload is not None}
                 for source in (body, inputs))


def strip_comments(text):
    return re.sub(r'/\*.*?\*/', ' ', re.sub(r'//[^\n]*', '', text), flags=re.S)


def scope_members(text, schema, scope):
    """Names declared directly in a namespace of the schema (`Input`, or an operation), which a spelling written there
    finds before the schema's own members."""
    opening = find_schema(text, schema)
    if not opening:
        return set()
    inner = re.search(r'enum\s+`?' + re.escape(scope) + r'`?\s*(?::[^{]*)?\{', body_of(text, opening))
    if not inner:
        return set()
    bodies = [body_of(body_of(text, opening), inner)]
    # Members an extension of the namespace declares are members too.
    for extension in re.finditer(r'extension\s+(?:\w+\.)*' + re.escape(schema.partition('#')[0]) + r'\.' + re.escape(scope) + r'\b[^{]*\{', text):
        bodies.append(body_of(text, extension))
    return {name for body in bodies for name in re.findall(r'(?:struct|enum|class|typealias|protocol)\s+`?([^\s`<:=({]+)`?', body)}


def qualify_in(spelling, members, prefix):
    """Spells at schema scope what `spelling` means inside the namespace `prefix` declaring `members`."""
    spelling = re.sub(r'(?<![\w.`])Self(?=\s*\.|\s*\)\s*\.)', prefix, spelling)
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


def find_schema(text, schema):
    """The declaration of the schema `schema` up to its opening brace: `Flow` names the first schema of that basename,
    `Flow#1` the second, so two schemas of one basename in different enclosing types stay apart."""
    name, _, occurrence = schema.partition('#')
    matches = [m for m in schema_declarations(text) if m.group(1) == name]
    index = int(occurrence or 0)
    if index < len(matches):
        return matches[index]
    return re.search(r'enum\s+`?' + re.escape(name) + r'`?[^{]*\{', text) if index == 0 else None


def graph_keys(graphs):
    """Each graph's schema key, in order: its name, with `#k` for the k-th later graph of the same name."""
    seen = collections.Counter()
    keys = []
    for graph in graphs:
        name = graph.get('name', '')
        keys.append(name if not seen[name] else f'{name}#{seen[name]}')
        seen[name] += 1
    return keys


def schema_opening(text, schema):
    """The index just past the `{` of the schema's body, and the index of its closing brace."""
    match = find_schema(text, schema)
    if match is None or '@StateMachine' not in match.group(0):
        return None, None
    return match.end(), match.end() + len(body_of(text, match))


def spelling_probes(text, graphs, scope='written', keys=None, start=0):
    """Probes that read each type spelling a graph exports, exactly as exported, in the scope the guide says it is
    meant in, beside the authored type read where it is declared. Returns the probe source, their labels, and the
    records no probe could be made for. With `scope='schema'`, every exported spelling is read at the schema's scope
    instead: the contract the macro documented before exported spellings followed the scope they are written in."""
    insertions, labels, missing = [], [], []
    keys = keys or graph_keys(graphs)
    for graph, key in zip(graphs, keys):
        schema = graph.get('name')
        if not schema:
            continue
        opened, closed = schema_opening(text, key)
        if opened is None:
            missing.append(f'{schema}: no schema declaration to probe')
            continue
        phases, inputs = authored_payloads(text, key)

        def add(site, exported, exported_at, authored, authored_at):
            if exported_at is None or authored_at is None:
                missing.append(f'{site}: no scope to read it in')
                return
            index = start + len(labels)
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
            members = scope_members(text, key, operation['id'])
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
            authored = 'Payload' if 'Payload' in scope_members(text, key, event['id']) else 'Swift::Void'
            add(f"{schema} event {event['id']} payload", event['payload'], at, authored, at)
    # Counted from what the schemas declare, not from what the graphs hold, so a graph that drops a record cannot
    # drop its probe.
    expected = 0
    for g, key in zip(graphs, keys):
        declared = declared_inventory(text, key) or dict(phases=[], inputs=[], operations=[], events=[])
        _, payloads = authored_payloads(text, key)
        keyed = sum(1 for o in declared['operations'] if 'Key' in scope_members(text, key, o))
        expected += (len(declared['phases']) + sum(1 for i in declared['inputs'] if i in payloads)
                     + 3 * len(declared['operations']) + keyed + len(declared['events']))
    if len(labels) + len(missing) < expected:
        missing.append(f'graph records: {expected} spelled fields declared, {len(labels)} probed')
    source = text
    for at, probe in sorted(insertions, key=lambda item: -item[0]):
        source = source[:at] + '\n        ' + probe + '\n' + source[at:]
    return source, labels, missing


def check_spellings(toolchain, directory, text, graphs, flags=()):
    """Compiles the case with spelling probes, with the case's own flags; returns problems, each `site: detail`: a
    spelling that names another type, one that names none, a probe that is missing, or probes that do not compile."""
    files, _ = split_case(text)
    # Each graph is probed in the file that declares its schema: the k-th schema of its basename in the module, in
    # file order.
    found, counts = {name: [] for name in files}, collections.Counter()
    for graph in graphs:
        name, k = graph.get('name', ''), counts[graph.get('name', '')]
        counts[name] += 1
        for file, content in files.items():
            here = sum(1 for _ in re.finditer(r'@StateMachine\([^)]*\)\s*(?:@\w+(?:\([^)]*\))?\s*)*(?:\w+\s+)*enum\s+`?' + re.escape(name) + r'`?[^{]*\{', content))
            if k < here:
                found[file].append((graph, name if k == 0 else f'{name}#{k}'))
                break
            k -= here
        else:
            found['Case.swift'].append((graph, name))
    probed_files, labels, missing = {}, [], []
    for file, content in files.items():
        chosen = found[file]
        source, more, absent = spelling_probes(content, [g for g, _ in chosen], toolchain.spelling_scope, [k for _, k in chosen], len(labels))
        probed_files[file] = source
        labels += more
        missing += absent
    problems = list(missing)
    if not labels:
        return problems
    sources = []
    for name, content in files.items():
        (directory / f'Probe-{name}').write_text(probed_files[name])
        sources.append(directory / f'Probe-{name}')
    plain = Toolchain.__new__(Toolchain)
    plain.__dict__.update(toolchain.__dict__)
    command = plain.command(sources, directory / 'Spellings.o', link=False, flags=flags)
    command.remove('-dump-macro-expansions')
    command.remove('-Xfrontend')
    command.insert(command.index('-c'), '-wmo')
    result = watched(command, toolchain.timeout)
    if result.verdict != 'ok':
        return problems + [f'spelling probes: the compilation {result.verdict} ({result.seconds}s, {result.peak_mb} MB)']
    if result.returncode != 0:
        named = []
        for path, line, column, message in ERROR.findall(result.stdout):
            file = os.path.basename(path)[len('Probe-'):] if os.path.basename(path).startswith('Probe-') else None
            lines = probed_files.get(file, '').split('\n')
            source_line = lines[int(line) - 1] if file and int(line) <= len(lines) else ''
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
        elif not line.startswith(('mermaid: ', 'dot: ', 'named: ')):
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
    # A Swift identifier such as `x` followed by U+05B0 keeps an alphabetic combining mark that NFC leaves
    # decomposed, which the library writes as itself; so a letter's combining marks are accepted too.
    plain = all(c.isalnum() or c == '_' or unicodedata.category(c) in ('Mn', 'Mc') for c in re.sub(r'#\d+;', '', text))
    if not plain or re.search('[\u00df\ufb02]', text):
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


def dot_id(text):
    """A DOT quoted identifier's text, as the grammar reads it: `\\"` is a quotation mark, and every other character,
    a backslash or an entity included, is itself. Entities and the other escapes are read only in labels."""
    out, index = [], 0
    while index < len(text):
        pair = text[index:index + 2]
        if pair == '\\"':
            out.append('"')
            index += 2
        elif pair == '\\\\':
            # Graphviz's scanner takes two backslashes as a pair and keeps both, so a quotation mark after them
            # ends the string.
            out.append(pair)
            index += 2
        else:
            out.append(text[index])
            index += 1
    return ''.join(out)


def dot_string(text):
    """A DOT quoted label's text as Graphviz renders it, or None for an escape it would not read as itself."""
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
    """(name, nodes as (label, terminal), edges as (source, destination, label, dashed)) or a problem string. Every
    phase is a node `p0`, `p1`, ... in declaration order, labeled with its name; the entry point is the point node
    `entry`, which an edge names as the source `None`."""
    if not text.endswith('\n'):
        return 'dot: the rendering does not end with a line break'
    lines = text[:-1].split('\n')
    head = re.fullmatch(r'digraph ' + DOT_STRING + r' \{', lines[0])
    if not head or lines[-1] != '}' or len(lines) < 3 or lines[1] != '    entry [shape=point];':
        return f'dot: unreadable frame {lines[0]!r} … {lines[-1]!r}'
    name, nodes, edges, labels = dot_id(head.group(1)), [], [], {}
    for number, line in enumerate(lines[2:-1], 3):
        match = re.fullmatch(r'    (p\d+) \[label=' + DOT_STRING + r'(, peripheries=2)?\];', line)
        if match:
            if match.group(1) != f'p{len(nodes)}' or edges:
                return f'dot line {number}: node {match.group(1)!r} out of declaration order'
            labels[match.group(1)] = dot_string(match.group(2))
            nodes.append((labels[match.group(1)], bool(match.group(3))))
            continue
        match = re.fullmatch(r'    (entry|p\d+) -> (p\d+)(?: \[label=' + DOT_STRING + r'(, style=dashed)?\])?;', line)
        if not match:
            return f'dot line {number}: unreadable line {line!r}'
        if match.group(1) != 'entry' and match.group(1) not in labels or match.group(2) not in labels:
            return f'dot line {number}: an edge names an undeclared node'
        edges.append((None if match.group(1) == 'entry' else labels[match.group(1)], labels[match.group(2)],
                      dot_string(match.group(3)) if match.group(3) is not None else None, bool(match.group(4))))
    if None in [name] + [n for n, _ in nodes] + [x for e in edges for x in e[1:3] if x is not None]:
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
        # Every phase is declared once, in declaration order, with an internal identifier of its own and the authored
        # name as its label; a transition names states only by those identifiers.
        undeclared = sorted({t for a, b, _ in transitions for t in (a, b) if t != '[*]' and t not in states})
        if undeclared:
            problems.append(f'{name} mermaid: transitions name undeclared states {undeclared[:4]}')
        if list(states.values()) != [p['id'] for p in graph['phases']]:
            problems.append(f'{name} mermaid: declares the states {list(states.values())}, the graph {[p["id"] for p in graph["phases"]]}')
        if any(identifier in [p['id'] for p in graph['phases']] and identifier != label for identifier, label in states.items()):
            problems.append(f'{name} mermaid: an internal state identifier is another phase\'s name')
        label = lambda token: None if token == '[*]' else states.get(token, f'<undeclared {token}>')
        got = [(label(a), label(b), l) for a, b, l in transitions]
        if got != expected:
            problems.append(f'{name} mermaid: describes {got[:6]} …, the graph {expected[:6]} …')
    read = read_dot(dot)
    if isinstance(read, str):
        problems.append(f'{name} {read}')
    else:
        title, nodes, edges = read
        # A restoration entrance is the dashed edge from the entry point; every other edge is solid.
        got = [(a, b, l, dashed) for a, b, l, dashed in edges]
        want = [(a, b, l, a is None and l == 'restored') for a, b, l in expected if b is not None]
        if title != name or nodes != [(p['id'], p['id'] in graph.get('terminal', [])) for p in graph['phases']] or got != want:
            problems.append(f'{name} dot: describes {title!r} {nodes[:4]} {got[:4]} …, the graph {want[:4]} …')
    return problems


def named_dot_problems(name, dot):
    """Problems of the DOT rendering of a graph decoded under `name`: its header must name the graph itself."""
    read = read_dot(dot)
    if isinstance(read, str):
        return [f'named graph {name!r} {read}']
    if read[0] != name:
        return [f'named graph {name!r} dot: the header names the graph {read[0]!r}']
    return []


def diagram_problems(stdout):
    lines = stdout.splitlines()
    problems = []
    for line in lines:
        if line.startswith('named: '):
            if line == 'named: unreadable':
                problems.append('named graph: a graph decoded under another name was refused')
            else:
                name, dot = json.loads(line[len('named: '):])
                problems += named_dot_problems(name, dot)
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


OWNER_TYPES = {'.owned': 'Owned', '.local': 'Local', '.shared': 'Shared', '.actorHost': 'ActorHost',
               '.mainActorHost': 'MainActorHost', '.isolatedHost': 'IsolatedHost'}
MANAGED = {'Shared', 'ActorHost', 'MainActorHost', 'IsolatedHost'}


def selected_owners(text):
    """Each schema's path with the owner types its attribute selects, from the source."""
    # The attribute's arguments are read as Swift reads them: across lines, in any spacing, with escaped labels.
    found = []
    for match in re.finditer(r'@StateMachine\s*\(', text):
        depth, index = 1, match.end()
        while index < len(text) and depth:
            depth += {'(': 1, ')': -1}.get(text[index], 0)
            index += 1
        arguments = {}
        for argument in split_top(strip_comments(text[match.end():index - 1])):
            label, _, value = argument.partition(':')
            arguments[label.strip().strip('`')] = ' '.join(value.split())
        if 'mode' not in arguments:
            continue
        listed = re.fullmatch(r'\[(.*)\]', arguments.get('owners', ''))
        owners = [o.strip() for o in (listed.group(1) if listed else '').split(',') if o.strip()] or DEFAULT_OWNERS.get(arguments['mode'], ['.owned'])
        name = re.search(r'enum\s+`?(\w+)', text[index:])
        if name:
            found.append((name.group(1), [OWNER_TYPES[o] for o in owners if o in OWNER_TYPES]))
    return found


def label_order_problems(fingerprint, text):
    """Each initializer whose driver and handler labels are not in the order the guide documents: one driver per
    operation, in the order the operations are declared, then one handler per event, in theirs; and each managed
    owner of a schema with operations or events that has no initializer taking all of them."""
    problems = []
    for line in fingerprint:
        order, movable = movable_labels(line, text)
        if movable and [l for _, l in movable] != [l for l in order if l in {m for _, m in movable}]:
            problems.append(f"labels {line.split('(')[0]}: {[l for _, l in movable]}, declared {[l for l in order if l in {m for _, m in movable}]}")
    source = module_text(text) if CLIENT_MARKER in text or FILE_MARKER.search(text) else text
    reachable = {path.split('.')[-1] for path in schema_path_list(source)}
    for schema, owners in selected_owners(source):
        declared = declared_inventory(source, schema)
        # A schema in a function body generates no symbol a module exports.
        if not declared or schema not in reachable:
            continue
        wanted = [f'{lower_first(o)}Driver' for o in declared['operations']] + [f'on{e}' for e in declared['events']]
        if not wanted:
            continue
        drivers = [f'{lower_first(o)}Driver' for o in declared['operations']]
        handlers = [f'on{e}' for e in declared['events']]
        bundle = [lower_first(o) for o in declared['operations']]
        takes = lambda line, labels: [l for l in re.findall(r'(\w+):', line.split('init(', 1)[-1]) if l in labels] == labels
        for owner in sorted(set(owners) & MANAGED):
            inits = [l for l in fingerprint if re.search(r'\b' + re.escape(schema) + r'\.' + owner + r'\.(?:__allocating_)?init\(', l)]
            bundles = [l for l in fingerprint if re.search(r'\b' + re.escape(schema) + r'\.' + owner + r'\.Drivers\.(?:__allocating_)?init\(', l)]
            # One initializer takes one driver per operation, directly or as the owner's `Drivers` bundle, and one
            # handler per event, together: a driver-only and a handler-only initializer do not make one.
            direct = any(takes(l, drivers + handlers) for l in inits)
            bundled = (bool(drivers) and any(takes(l, bundle) for l in bundles)
                       and any(takes(l, ['drivers'] + handlers) for l in inits))
            if not inits or not (direct or bundled):
                problems.append(f'labels {schema}.{owner}: no initializer takes {drivers or bundle} and {handlers}')
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
    return [n.lstrip('@.').strip('`') for n in re.findall(r"'([^']+)'", message)]


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
    files, _ = split_case(case['text'])
    if name not in files:
        return None
    lines = files[name].split('\n')
    if not 0 < line <= len(lines):
        return None
    changed, _ = diagnostic_changes(case, name)
    if line in changed:
        return 'token line'
    if declaration_span(lines, line) & changed:
        return 'enclosing declaration'
    source = lines[line - 1]
    if ('nest-generic' in case['rewrites'] and source.lstrip().startswith('@StateMachine(')
            and re.fullmatch(DIAG_EXPECT['nest-generic'], message) and line - 1 in changed
            and re.fullmatch(r'\s*(?:\w+\s+)*enum\s+\w+<[^>]+>\s*\{', lines[line - 2])):
        return 'generic enclosing type'
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


TOKEN = re.compile(r"@?`[^`]+`|@?[^\W\d][\w.]*|#if\b|\.\w+")
# Refusals of a whole schema, which stand at its attribute or its name rather than at a token a rewrite changed.
SCHEMA_WIDE = r"Generic schemas|The macro cannot read this schema|@StateMachine requires"


def anchored_token(case, name, line, column, message, token=None):
    """Whether the diagnostic stands at the token it names: the token at its line and column is one the message
    quotes (an attribute with its `@`, a member with its leading dot), or matches the entry's `token`. A
    diagnostic whose column is unknown, or one in a file the case does not hold, does not stand at a token."""
    if column is None:
        return False
    files, _ = split_case(case['text'])
    if name not in files:
        return False
    lines = files[name].split('\n')
    if not 0 < line <= len(lines):
        return False
    source_line = lines[line - 1]
    # The compiler counts columns in UTF-8 bytes; the line is read in characters.
    column = len(source_line.encode('utf-8')[:column - 1].decode('utf-8', errors='ignore')) + 1
    # A diagnostic stands at the start of a token, never inside one.
    word = lambda character: character.isalnum() or character == '_'
    if column > 1 and word(source_line[column - 2:column - 1] or ' ') and word(source_line[column - 1:column] or ' '):
        return False
    # At text the rewrite changed, character by character, or at the token whose inside it changed: a generic clause
    # it added, a list it emptied.
    changed, columns = diagnostic_changes(case, name)
    ranges = columns.get(line, [])
    if any(a - 1 <= column <= b for a, b in ranges):
        return token is None or (TOKEN.match(source_line, column - 1) and re.fullmatch(token, TOKEN.match(source_line, column - 1).group(0)))
    # A string literal stands for its contents: a diagnostic at its opening quote is at the token when the rewrite
    # changed text inside it.
    if source_line[column - 1:column] == '"':
        closing = source_line.find('"', column)
        if closing > 0 and any(column < a and b <= closing + 1 for a, b in ranges):
            return token is None
    # A bracketed expression, or a declaration's name with its parameter or argument list (spanning one or more
    # lines), stands for the whole of it: the diagnostic is at the token when the rewrite changed something inside,
    # or when the extent names what the message names.
    start = column - 1
    end = start + (TOKEN.match(source_line, start).end() - start if TOKEN.match(source_line, start) else 0)
    if source_line[end:end + 1] in ('(', '<', '[') or source_line[start:start + 1] in ('(', '['):
        opener = source_line[end] if source_line[end:end + 1] in ('(', '<', '[') else source_line[start]
        closer = {'(': ')', '<': '>', '[': ']'}[opener]
        depth, cursor, current_line = 0, end if source_line[end:end + 1] == opener else start, line
        parts = []
        while current_line <= len(lines):
            text_line = lines[current_line - 1]
            piece_start = start if current_line == line else 0
            while cursor < len(text_line):
                depth += (text_line[cursor] == opener) - (text_line[cursor] == closer)
                cursor += 1
                if depth == 0:
                    break
            parts.append((current_line, piece_start, cursor, text_line[piece_start:cursor]))
            if depth == 0:
                break
            current_line += 1
            cursor = 0
        if depth == 0:
            extent = '\n'.join(part for _, _, _, part in parts)
            for span_line, span_start, span_end, _ in parts:
                line_ranges = columns.get(span_line, [])
                if any(span_start + 1 <= a and b <= span_end + 1 for a, b in line_ranges):
                    return token is None
            payloads = dict(re.findall(r'\bcase\s+`?(\w+)`?\s*\(\s*(\w+)', case['text']))
            declared = set(re.findall(r'\b(?:struct|enum|class|actor|typealias|protocol|case|func)\s+`?(\w+)', case['text']))
            named = set(quoted_names(message)) | {payloads[n] for n in quoted_names(message) if n in payloads}
            named |= set(re.findall(r'\b[A-Z]\w*\b', message)) & declared
            if token is None and any(re.search(r'(?<![\w])' + re.escape(n) + r'(?![\w])', extent) for n in named if n):
                return True
    found = TOKEN.match(source_line, column - 1)
    if not found:
        return False
    text = found.group(0)
    # A member expression (`.parallel(limit: 0x0)`) whose arguments the rewrite changed.
    if text.startswith('.') and source_line[found.end():found.end() + 1] == '(':
        depth, end = 0, found.end()
        while end < len(source_line):
            depth += {'(': 1, ')': -1}.get(source_line[end], 0)
            end += 1
            if depth == 0:
                break
        if any(column <= a and b <= end + 1 for a, b in ranges):
            return True
    if token is not None:
        return re.fullmatch(token, text) is not None
    bare = text.lstrip('@.').strip('`')
    # A qualified token (`Box.Hidden`) stands at its first component.
    if bare in quoted_names(message) or bare.split('.')[0] in quoted_names(message):
        return True
    # A phase metatype (`Ready.self`) stands for a quoted phase whose payload it names, when the message names that metatype.
    if bare.endswith('.self') and re.search(r'(?<![\w])' + re.escape(bare) + r'(?![\w])', message):
        payloads = dict(re.findall(r'\bcase\s+`?(\w+)`?\s*\(\s*(\w+)', case['text']))
        if bare[:-len('.self')] in {payloads[n] for n in quoted_names(message) if n in payloads}:
            return True
    # A `Scope.<case>` reference stands at its case when the message quotes that scope name.
    if bare.startswith('Scope.') and bare.split('.', 1)[1] in quoted_names(message):
        return True
    # A refusal of the whole schema stands at its attribute or its name.
    if re.match(SCHEMA_WIDE, message) and (text == '@StateMachine' or bare in schema_names(case['text'])):
        return True
    # A parameter whose type names a quoted phase, by its name or its payload: a source parameter.
    parameter = re.match(r'(?:_|\w+)(?:\s+\w+)?\s*:\s*([^,)]*)', source_line[column - 1:])
    if parameter:
        payloads = dict(re.findall(r'\bcase\s+`?(\w+)`?\s*\(\s*(\w+)', case['text']))
        named = set(quoted_names(message)) | {payloads[n] for n in quoted_names(message) if n in payloads}
        if any(re.search(r'(?<![\w])' + re.escape(n) + r'(?![\w])', parameter.group(1)) for n in named):
            return True
    # Or at text the rewrite wrote, which the seed nowhere holds: the payload a phase alias replaced, for one.
    seed = SEED_TEXTS.get(case.get('seed'), None)
    if seed is None or line not in changed:
        return False
    if re.search(r'(?<![\w])' + re.escape(text) + r'(?![\w])', seed) is None:
        return True
    # Or at a default value's construction on a changed line, which a refusal of the construction names by the
    # type it returns ("… returns FuzzAlias …"), declared on that line.
    declared = set(re.findall(r'\b(?:struct|enum|class|actor|typealias|protocol|case|func)\s+`?(\w+)', case['text']))
    named = set(re.findall(r'\b[A-Za-z_]\w*\b', message)) & declared
    default = source_line[:column - 1].rstrip().endswith('=')
    return default and any(re.search(r'(?<![\w])' + re.escape(n) + r'(?![\w])', source_line) for n in named)




_DIAGNOSTIC_CHANGES = {}


def diagnostic_changes(case, name):
    """Return `(lines, columns)` of 1-based changed line numbers and inclusive column spans in `name` relative to
    the seed. Diffs compiled argument order for `Client.swift`, and places the moved seed schema in the same
    module file under `schema-to-file`."""
    import difflib
    moved_schema = 'schema-to-file' in case['rewrites']
    key = (case.get('seed'), case['text'], name, moved_schema)
    if key in _DIAGNOSTIC_CHANGES:
        return _DIAGNOSTIC_CHANGES[key]
    base = SEED_TEXTS.get(case.get('seed'), '')
    seeds, seed_client = split_case(base)
    files, client = split_case(case['text'])
    if name == 'Client.swift' and client is not None:
        # compile_case writes Client.swift through order_client_arguments. Diff that compiled text.
        source_before = order_client_arguments(seed_client or '', base.split(CLIENT_MARKER, 1)[0])
        source_after = order_client_arguments(client, case['text'].split(CLIENT_MARKER, 1)[0])
    elif name in files:
        source_before = seeds.get(name, '')
        source_after = files[name]
    else:
        return set(), {}
    if moved_schema and name in files:
        # Move the same seed schema before diffing so its unchanged lines do not count as changed merely by moving.
        for moved, _ in REWRITE_BY_NAME['schema-to-file'].function(base, None):
            moved_files, _ = split_case(moved)
            if schema_names(moved_files['Other.swift']) == schema_names(files.get('Other.swift', '')):
                source_before = moved_files.get(name, '')
                break
    seed = source_before.split('\n')
    text = source_after.split('\n')
    lines, columns = set(), {}
    for tag, a1, a2, b1, b2 in difflib.SequenceMatcher(None, seed, text, autojunk=False).get_opcodes():
        if tag == 'equal':
            continue
        lines.update(range(b1 + 1, b2 + 1))
        for offset, index in enumerate(range(b1, b2)):
            before = seed[a1 + offset] if tag == 'replace' and a1 + offset < a2 else None
            after = text[index]
            if before is None:
                columns[index + 1] = [(1, len(after) + 1)]
                continue
            spans = []
            for op, c1, c2, d1, d2 in difflib.SequenceMatcher(None, before, after, autojunk=False).get_opcodes():
                if op != 'equal':
                    spans.append((d1 + 1, max(d2, d1 + 1)))
            columns[index + 1] = spans
    _DIAGNOSTIC_CHANGES[key] = (lines, columns)
    return lines, columns


def column_of(variant, message, name, line):
    return next((column for key, column in variant.get('columns', []) if key == (message, name, line)), None)


def refusal_matches(pattern, case, variant, exact=False, token=None, consequent=None):
    """Whether the variant is refused with a diagnostic whose whole message matches `pattern`, at the changed site and
    at the token it names; with `exact`, also that every other diagnostic and error is the same refusal, one the
    refused expansion leaves behind (CASCADE), a listed consequence (`consequent`), or a documented consequence of
    the case's other rewrites."""
    located = variant.get('located', [])
    macro = [(m, line, name) for p, m, name, line in located if p == 'macro']
    primary = [(m, line, name) for m, line, name in macro if re.fullmatch(pattern, m) and at_site(case, line, m, name)
               and anchored_token(case, name, line, column_of(variant, m, name, line), m, token)]
    if not primary:
        return False
    if not exact:
        return True
    entries = [e for e in LIMITS if any(re.search(e['rewrites'], n) for n in case['rewrites'])]
    documented = [e['pattern'] for e in entries] + [e['consequent'] for e in entries if e.get('consequent')]
    allowed = lambda m: (re.fullmatch(pattern, m) or CASCADE.search(m) or (consequent and re.fullmatch(consequent, m))
                         or any(re.fullmatch(d, m) for d in documented))
    return all(allowed(m) for p, m, name, line in located)


def outside_never_throws(case, variant, pattern):
    """Whether every primary diagnostic matching `pattern` stands on a `throws(...)` clause whose thrown type resolves
    to `Never` through a file-scope alias declared outside the schema, never a literal `Never` or local alias alone."""
    files, _ = split_case(case['text'])
    file_aliases, local_aliases = {}, {}
    for content in files.values():
        spans = schema_lines(content)
        for line_no, raw in enumerate(content.split('\n'), 1):
            in_schema = any(a <= line_no <= b for a, b in spans)
            if not in_schema:
                match = re.match(r'\s*(?:(?:public|package|internal|fileprivate|private)\s+)?typealias\s+`?([A-Za-z_]\w*)`?\s*=\s*(.+?)\s*$', raw)
                if match:
                    file_aliases[match.group(1)] = strip_comments(match.group(2)).strip()
            else:
                nested = re.match(r'\s*(?:(?:public|package|internal|fileprivate|private)\s+)?enum\s+`?([A-Za-z_]\w*)`?\s*\{\s*(?:(?:public|package|internal|fileprivate|private)\s+)?typealias\s+`?([A-Za-z_]\w*)`?\s*=\s*([^}]+)\}', raw)
                if nested:
                    local_aliases[f'{nested.group(1)}.{nested.group(2)}'] = strip_comments(nested.group(3)).strip()
                else:
                    match = re.match(r'\s*(?:(?:public|package|internal|fileprivate|private)\s+)?typealias\s+`?([A-Za-z_]\w*)`?\s*=\s*(.+?)\s*$', raw)
                    if match:
                        local_aliases[match.group(1)] = strip_comments(match.group(2)).strip()

    def unwrap(text):
        text = strip_comments(text).strip()
        while text.startswith('(') and text.endswith(')') and scan_type_end(text, 1, '') == len(text) - 1:
            text = text[1:-1].strip()
        return text

    def resolves_through_file_alias_to_never(spelling):
        current = unwrap(spelling).strip('`')
        seen, used_file = set(), False
        while current not in seen:
            seen.add(current)
            if current in file_aliases:
                used_file = True
                target = unwrap(file_aliases[current])
            elif current in local_aliases:
                target = unwrap(local_aliases[current])
            else:
                return False
            if re.fullmatch(r'(?:Swift(?:\.|::))?`?Never`?', target):
                return used_file
            current = target.strip('`')
        return False

    primaries = [(m, line, name) for p, m, name, line in variant.get('located', [])
                 if p == 'macro' and re.fullmatch(pattern, m)]
    if not primaries:
        return False
    for message, line, name in primaries:
        column = column_of(variant, message, name, line)
        if column is None or name not in files:
            return False
        lines = files[name].split('\n')
        if not 0 < line <= len(lines):
            return False
        source_line = lines[line - 1]
        char_col = len(source_line.encode('utf-8')[:column - 1].decode('utf-8', errors='ignore')) + 1
        rest = '\n'.join([source_line[char_col - 1:]] + lines[line:line + 3])
        throws_match = re.match(r'throws\s*\(', rest)
        if not throws_match:
            return False
        inner_start = throws_match.end()
        inner_end = scan_type_end(rest, inner_start, '')
        if inner_end >= len(rest) or rest[inner_end] != ')':
            return False
        if not resolves_through_file_alias_to_never(rest[inner_start:inner_end]):
            return False
    return True


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
            if refusal_matches(entry['pattern'], case, variant, entry.get('exact', False), entry.get('token')):
                if entry['id'] == 'outside-never-owned' and not outside_never_throws(case, variant, entry['pattern']):
                    continue
                return entry['id']
            continue
        # Every line of the difference must be the documented one: each message, or for an interface each signature
        # added matches the pattern and each one removed reappears, respelled, among those added, so that no member
        # is lost beside the documented change.
        details = detail if isinstance(detail, list) else [detail]
        if observed == 'client-error':
            pattern = entry.get('client_pattern')
            if pattern and details and all(re.fullmatch(pattern, message) for message in details):
                return entry['id']
            continue
        if observed == 'interface' and details and all(d[:1] in '+-' for d in details):
            added = [d[1:] for d in details if d.startswith('+')]
            removed = [d[1:] for d in details if d.startswith('-')]
            # Each removed member reappears as its own respelling: the same name and argument labels, one added
            # signature for each, so another overload of that name cannot stand in for a lost one.
            spare = collections.Counter(member_key(a) for a in added)
            paired = True
            for r in removed:
                if spare[member_key(r)] <= 0:
                    paired = False
                    break
                spare[member_key(r)] -= 1
            if added and all(re.search(entry['pattern'], a) for a in added) and paired:
                return entry['id']
            continue
        consequent = entry.get('consequent')
        if details and any(re.search(entry['pattern'], d) for d in details) and all(
            re.search(entry['pattern'], d) or (consequent and re.fullmatch(consequent, d)) for d in details):
            return entry['id']
    return None


def member_key(line):
    """A demangled signature's member: its qualified name and its argument labels, without their types."""
    head, _, rest = line.partition('(')
    depth, end = 1, 0
    for end, char in enumerate(rest):
        depth += {'(': 1, ')': -1}.get(char, 0)
        if depth == 0:
            break
    labels = tuple(p.split(':', 1)[0].strip() for p in split_top(rest[:end]) if ':' in p)
    return head, labels


def split_owned_signature(signature):
    """For an `Owned` method signature, return `(prefix_including_open_paren, [params], suffix_from_close_paren)`, else None."""
    member = re.match(r'Fz\.[\w.]+\.Owned\.[^\s.<(]+', signature)
    if member is None:
        return None
    opening = signature.find('(', member.end())
    if opening < 0:
        return None
    close = scan_type_end(signature, opening + 1, '')
    if close >= len(signature) or signature[close] != ')':
        return None
    raw = signature[opening + 1:close]
    params = [p.strip() for p in split_top(raw)] if raw.strip() else []
    return signature[:opening + 1], params, signature[close:]


def shared_params_match(before_params, after_params, require_change=True):
    """Whether every parameter in `after_params` equals `before_params`'s or strictly adds `__shared `."""
    if len(before_params) != len(after_params):
        return False
    changed = False
    for before_param, after_param in zip(before_params, after_params):
        if after_param == before_param:
            continue
        label_before, sep_before, type_before = before_param.partition(': ')
        label_after, sep_after, type_after = after_param.partition(': ')
        if sep_before and sep_after and label_before == label_after and type_after == '__shared ' + type_before:
            changed = True
        elif not sep_before and not sep_after and after_param == '__shared ' + before_param:
            changed = True
        else:
            return False
    return changed or not require_change


def failure_split_signatures(difference, allow_shared_owned=False):
    """Whether every signature in `difference` is an `Observed` or `Owned` failure-split pair with matching
    declaration, constraints, and parameter types (optionally allowing strictly added `__shared ` on `Owned`
    parameters when `shared-param` is also active)."""
    def signature_key(signature, split):
        member = re.match(r'(Fz\.[\w.]+)\.(Observed|Owned)\.([^\s.<(]+)', signature)
        if member is None:
            return None
        schema, owner, method = member.groups()
        opening = signature.find('(', member.end())
        if opening < 0:
            return None
        end = scan_type_end(signature, opening + 1, '') + 1
        call, suffix = signature[:end], signature[end:]
        if owner == 'Observed' and suffix.startswith(' throws('):
            end = scan_type_end(suffix, len(' throws('), '')
            failure, result = suffix[len(' throws('):end], suffix[end + 1:]
            if result == f' -> {schema}.Prepared' and bool(failure) and (
                    failure == f'{schema}.PreparationRejection') == split:
                return ('Observed', call, ())
        if owner == 'Owned' and suffix.startswith(' -> '):
            result = suffix[len(' -> '):]
            parts = split_owned_signature(signature)
            owned_key = ('Owned', parts[0], tuple(parts[1])) if parts is not None else None
            if split:
                companion = unicodedata.normalize('NFC', method[:1].upper() + method[1:])
                phase = re.search(r'\bA == ' + re.escape(schema) + r'\.(\w+)(?=[,>])', call)
                allowed = {f'{schema}.Route.{companion}Result'}
                if phase:
                    allowed.add(f'{schema}.Route.{phase.group(1)}.{companion}Result')
                if result in allowed:
                    return owned_key
            elif result.startswith('StateMachine.Advance<') and result.endswith('>'):
                arguments = [argument.strip() for argument in split_top(result[len('StateMachine.Advance<'):-1])]
                if len(arguments) == 4 and all(arg.startswith(f'{schema}.Owned<') for arg in arguments[:2]):
                    return owned_key
        return None

    before = [signature_key(line[1:], False) for line in difference if line.startswith('-')]
    after = [signature_key(line[1:], True) for line in difference if line.startswith('+')]
    if not before or len(before) != len(after) or None in before or None in after:
        return False
    if not allow_shared_owned:
        return collections.Counter(before) == collections.Counter(after)
    remaining = list(after)
    for owner, head, params in before:
        match = next((i for i, (a_owner, a_head, a_params) in enumerate(remaining)
                      if a_owner == owner and a_head == head and (
                          a_params == params if owner == 'Observed' else shared_params_match(params, a_params, require_change=False))), None)
        if match is None:
            return False
        remaining.pop(match)
    return not remaining


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


def problems_of(outcome):
    return (outcome.get('spelling_problems', []) + outcome.get('diagram_problems', []) + outcome.get('label_problems', [])
            + outcome.get('text_problems', []) + outcome.get('inventory_problems', []) + outcome.get('fixit_problems', [])) if outcome else []


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
    # A crash, a cap, a timeout, or a failed execution fails whatever else the case meets: no allowance of its other
    # rewrites stands in front of it.
    if variant['status'] in RESOURCE_FAILURES:
        return 'fail', 'no crash, hang, or memory past the cap', describe(variant)
    if variant['status'] in RUN_FAILURES:
        return 'fail', 'a program that links and runs to completion, or a rejection before it', describe(variant)
    if prefix is not None:
        verdict, expected, observed = prefix
        if verdict == 'fail':
            return 'fail', f'the other rewrites alone: {expected}', observed
        if verdict.startswith('limit:') or verdict == 'artefact':
            # The other rewrites meet a documented limit (or a fuzzer artefact) first; this case cannot tell more.
            return verdict, 'the other rewrites alone meet a documented limit', observed
    client_limit = None
    if variant['status'] == 'client-error' and all(kind == 'eq' for kind in kinds):
        errors = variant['errors']
        if all(place == 'client' for place, _ in errors):
            client_limit = limit_for(case, 'client-error', [message for _, message in errors], role)
        if client_limit and 'fingerprint' in variant:
            # A separate client can fail after the schema compiled. Its own diagnostic and the whole change in the
            # schema's generated signatures must independently show the same documented limit.
            reference = control if control is not None else base
            mapping = case.get('mapping', {})
            difference = interface_difference(reference, variant, mapping, case.get('added', ()), order_free(case), case['text'])
            if failure_split_signatures(strip_repeated_ownership(difference, names), allow_shared_owned='shared-param' in names):
                return f'limit:{client_limit}', 'only the documented failure-split signature changes and matching client diagnostic', describe(variant)
            return 'fail', 'only the documented failure-split signature changes matching the client diagnostic', describe(variant)
    # Swift rejecting client code where a rewrite changed it is the rewrite's error, not the macro's.
    if variant['status'] == 'client-error':
        sites = variant.get('client_sites', [])
        if sites and all(place == 'client' for place, _ in variant['errors']) and all(
                line in diagnostic_changes(case, name)[0] for name, line in sites):
            return 'artefact', 'valid rewritten client code', describe(variant)
    if case.get('expect'):
        entry = next(e for e in LIMITS if e['id'] == case['expect'])
        if variant['status'] == 'macro-diagnostic' and refusal_matches(entry['pattern'], case, variant, True, entry.get('token')):
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
            # What else an accepted invalid schema does wrong, such as a deprecation fix-it its caller cannot apply.
            return 'fail', 'rejected (invalid under the documented grammar)', '; '.join(['compiles'] + (variant.get('fixit_problems', []) + problems_of(variant))[:2])
        # The rewrite's own finding, naming what it changed, or the rewrite's documented message; either at the token
        # it names, with nothing beside it but what the refused expansion and the broken graph leave behind.
        pattern = case.get('refusal') or BREAK_EXPECT.get(case.get('breaking') or last_special(case))
        if pattern is None:
            return 'fail', 'a breaking rewrite with a documented rejection', describe(variant)
        # The macro reports some checks through the expansion, as an unavailable witness that carries the message.
        witnessed = [m for p, m, _, _ in variant.get('located', []) if p == 'expansion' and re.fullmatch(r"'[^']*' is unavailable: (.*)", m)
                     and re.fullmatch(pattern, re.fullmatch(r"'[^']*' is unavailable: (.*)", m).group(1))]
        # Nothing but the witnesses and what the refused expansion and the broken graph leave behind stands beside them.
        unexplained = [m for p, m, _, _ in variant.get('located', []) if m not in witnessed and not CASCADE.search(m)
                       and not re.fullmatch(GRAPH_CONSEQUENCES, m)]
        if witnessed and all(p != 'macro' for p, _, _, _ in variant.get('located', [])):
            if unexplained:
                return 'fail', 'rejected through the expansion, alone', f'{describe(variant)}; beside it: {unexplained[0][:160]}'
            return 'pass', 'rejected through the expansion', describe(variant)
        if not refusal_matches(pattern, case, variant, True, token=case.get('token'), consequent=GRAPH_CONSEQUENCES):
            return 'fail', f'rejected with exactly the documented diagnostic at the token it names: {pattern}', describe(variant)
        return 'pass', 'rejected', describe(variant)
    if 'diag' in kinds:
        # Valid Swift the guide calls unsupported: the macro itself must say so, with its documented message, at the
        # token the case changed.
        pattern = DIAG_EXPECT.get(last_special(case))
        if variant['status'] == 'macro-diagnostic' and pattern and refusal_matches(pattern, case, variant, True, consequent=DIAG_CONSEQUENCES):
            return 'pass', 'a macro diagnostic', describe(variant)
        return 'fail', f'the documented macro diagnostic at the changed token, alone (Swift accepts it; the guide calls it unsupported): {pattern}', describe(variant)
    if 'safe' in kinds:
        # Valid Swift the guide neither supports nor rules out: compile, or refuse with a macro diagnostic at the token
        # it names.
        if variant['status'] == 'ok' or (variant['status'] == 'macro-diagnostic' and refusal_matches(r'.+', case, variant)):
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
        same, why = same_outcome(reference, variant, case.get('mapping', {}), case.get('behaviour', True), case.get('run_mapping'), order_free(case), case.get('added', ()), case['text'])
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
            # A variation changes no behavior a domain seed pins.
            expected_report = EXPECTED_REPORTS.get(case['seed'])
            if expected_report is not None and variant.get('report') != expected_report:
                return 'fail', f'compiles and prints the pinned report {expected_report!r}', f"report {variant.get('report')!r}"
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
    if client_limit:
        return f'limit:{client_limit}', 'as the seed, or a documented limit', describe(variant)
    if variant['status'] == 'expansion-error':
        messages = sorted({m for p, m in variant['errors'] if p == 'expansion'})
        entry = limit_for(case, 'expansion-error', messages, role)
        if entry:
            return f'limit:{entry}', 'as the seed, or a documented limit', describe(variant)
    if variant['status'] != 'ok':
        return 'fail', 'as the seed (Swift reads the same program)', describe(variant)
    reference = control if control is not None else base
    same, why = same_outcome(reference, variant, case.get('mapping', {}), case.get('behaviour', True), case.get('run_mapping'), order_free(case), case.get('added', ()), case['text'])
    if same:
        return 'pass', 'as the seed', 'same signatures, graph, and output'
    difference = interface_difference(reference, variant, case.get('mapping', {}), case.get('added', ()), order_free(case), case['text'])
    entry = limit_for(case, 'interface', difference or [why], role)
    if not entry and difference:
        remaining = strip_repeated_ownership(difference, names)
        if len(remaining) < len(difference):
            entry = 'repeated-ownership' if not remaining else limit_for(case, 'interface', remaining, role)
    if entry and difference:
        # A documented interface difference excuses only the signatures: the graph and the output, the pinned report
        # included, must still be the seed's.
        behaves, behaviour_why = same_outcome(dict(reference, fingerprint=[]), dict(variant, fingerprint=[]), case.get('mapping', {}),
                                              case.get('behaviour', True), case.get('run_mapping'), order_free(case), case.get('added', ()), case['text'])
        if not behaves:
            return 'fail', 'as the seed beside the documented interface difference', behaviour_why
    if entry:
        return f'limit:{entry}', 'as the seed, or a documented limit', why
    return 'fail', 'as the seed: same generated signatures, graph, and output', why


def strip_repeated_ownership(difference, rewrites):
    """Remove exact `(-before, +after)` `Owned` method pairs from `difference` where `shared-param` is active and
    `after` differs from `before` solely by adding `__shared ` to one or more parameters."""
    if 'shared-param' not in rewrites:
        return difference
    removed = [line[1:] for line in difference if line.startswith('-')]
    added = [line[1:] for line in difference if line.startswith('+')]
    kept_removed, kept_added = [], list(added)
    for line in removed:
        before_parts = split_owned_signature(line)
        match = None
        if before_parts is not None:
            b_head, b_params, b_tail = before_parts
            for i, candidate in enumerate(kept_added):
                after_parts = split_owned_signature(candidate)
                if after_parts is None:
                    continue
                a_head, a_params, a_tail = after_parts
                if a_head == b_head and a_tail == b_tail and shared_params_match(b_params, a_params, require_change=True):
                    match = i
                    break
        if match is not None:
            kept_added.pop(match)
        else:
            kept_removed.append(line)
    return [f'-{line}' for line in kept_removed] + [f'+{line}' for line in kept_added]


def interface_difference(reference, variant, mapping, added=(), order_free=(), text=None):
    """Every generated signature one outcome has and the other lacks, each marked `-` or `+`."""
    keep = lambda line: not any(re.search(pattern, line) for pattern in added)
    a = {line for line in apply_mapping(reference.get('fingerprint', []), mapping) if keep(line)}
    b = {line for line in variant.get('fingerprint', []) if keep(line)}
    if 'members' in order_free and text is not None:
        a = {reorder_labels(line, text) for line in a}
    return [f'-{line}' for line in sorted(a - b)] + [f'+{line}' for line in sorted(b - a)]


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


def edge_positions(direct, phase_payloads):
    """Map authored transitions and routers to `(declaration_offset, source_index)` sort keys, using `from:` order
    for multi-source edges (both inline lists and named `@PhaseSet` enums)."""
    phases = {core_name(payload): name for name, payload in phase_payloads.items()}
    sets = phase_sets(direct)
    positions = {}
    functions = collections.defaultdict(list)
    attributes = None
    identifier = IDENT_TOKEN
    tokens = (r'@(?:`?StateMachine`?\s*(?:::|\.)\s*)?`?(?:Transition|Route)`?(?![\w`])(?:\s*\()?'
              r'|\bfunc\s+(' + identifier + r')\s*(?:<[^>]*>\s*)?\(')
    parameter_prefix = re.compile(r'\s*' + identifier + r'(?:\s+' + identifier + r')?\s*:\s*' + MODIFIERS)
    for token in re.finditer(tokens, direct):
        if token.group().startswith('@'):
            attributes = direct[token.end():scan_type_end(direct, token.end(), '')] if token.group().endswith('(') else ''
        elif attributes is not None:
            name = token.group(1).strip('`')
            functions[name].append(token.start())
            source_list = re.search(r'(?<![\w`])`?from`?\s*:\s*\[([^\]]*)\]', attributes)
            source_set = (None if source_list else
                          re.search(r'(?<![\w`])`?from`?\s*:\s*(' + identifier + r')\s*\.\s*`?self`?(?![\w`])', attributes))
            if source_list:
                sources = [re.sub(r'\.\s*`?self`?\s*$', '', spelling) for spelling in split_top(source_list.group(1))]
            elif source_set:
                sources = sets.get(source_set.group(1).strip('`'), [])
            else:
                parameter = parameter_prefix.match(direct, token.end())
                sources = [direct[parameter.end():scan_type_end(direct, parameter.end(), ',=')]] if parameter else []
            for index, spelling in enumerate(sources):
                phase = phases.get(core_name(spelling))
                if phase is not None:
                    positions[f'{phase}.{name}'] = (token.start(), index)
            attributes = None
    positions.update({name: (offsets[0], 0) for name, offsets in functions.items() if len(offsets) == 1})
    return positions


# Lists of an edge or an operation whose order StateMachineGraph documents nowhere.
UNORDERED_LISTS = {'starts', 'emits', 'cancels', 'invalidates', 'requires'}


def in_declaration_order(graph, text, keys, schema):
    """The reference graph with every list under `keys` put in the order `text` declares its items: a rewrite that
    reorders declarations must reorder these lists exactly so, so each variant's lists derive from its own source."""
    body = schema_body(text, schema)
    if body is None:
        return graph
    direct = direct_member_text(body)
    phase_cases = list(direct_case_items(body))
    phases = {name: offset for name, offset, _ in phase_cases}
    namespaces = {m.group(1): m.start(1) for m in re.finditer(r'\benum\s+`?(\w+)`?', direct)}
    edges = edge_positions(direct, {name: payload for name, _, payload in phase_cases if payload is not None})
    orders = dict.fromkeys(('phases', 'terminal', 'restorable', 'activeIn'), phases)
    orders.update(dict.fromkeys(('events', 'operations'), namespaces))
    for key, name in (('inputs', 'Input'), ('scopes', 'Scope')):
        if key in keys:
            orders[key] = {case: offset for case, offset, _ in direct_case_items(case_namespace(body, direct, name))}

    def position(key, item):
        name = item.get('id') if isinstance(item, dict) else item
        if not isinstance(name, str):
            return None
        if key in ('edges', 'routers', 'candidates'):
            return edges.get(name, edges.get(name.partition('.')[2]))
        return orders.get(key, {}).get(name)

    def arrange(value, key):
        if isinstance(value, dict):
            return {k: arrange(v, k) for k, v in value.items()}
        if isinstance(value, list):
            items = [arrange(v, key) for v in value]
            if key not in keys:
                return items
            if key in UNORDERED_LISTS:
                # The graph documents no order for these; they compare as collections on both sides.
                return sorted(items, key=lambda v: json.dumps(v, sort_keys=True))
            positions = [position(key, v) for v in value]
            if any(p is None for p in positions):
                return items
            return [v for _, _, v in sorted(zip(positions, range(len(items)), items), key=lambda t: (t[0], t[1]))]
        return value
    return arrange(graph, None)


def align_graph_lines(reference, variant, mapping):
    """Reorder `reference`'s `graph:` lines to match `variant`'s `graph_paths` when rewrites move or rename
    schemas."""
    lines = reference.get('run', [])
    paths = reference.get('graph_paths', [])
    target = variant.get('graph_paths', [])
    if len(paths) != len(target) or paths == target:
        return lines
    graphs = [line for line in lines if line.startswith('graph: ')]
    if len(graphs) != len(paths):
        return lines
    mapped = apply_mapping(paths, mapping)
    matched = {path: line for path, new, line in zip(paths, mapped, graphs) if path == new and path in target}
    for path, new, line in zip(paths, mapped, graphs):
        if path == new and path in target:
            continue
        # The demangled mapping omits backticks. Require a unique remaining path with that spelling.
        choices = [candidate for candidate in target if candidate not in matched and candidate.replace('`', '') == new.replace('`', '')]
        if len(choices) != 1:
            return lines
        matched[choices[0]] = line
    return [matched[path] for path in target] + [line for line in lines if not line.startswith('graph: ')]


def same_outcome(reference, variant, mapping, behaviour, run_mapping=None, order_free=(), added=(), text=None):
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
    # Under a reordering, the reference's declaration-ordered lists are put in the variant's own declaration order;
    # the variant's lists are compared as they are, so a generator that sorts them does not pass.
    source = module_text(text) if text is not None else None
    aligned = align_graph_lines(reference, variant, mapping)
    schemas = iter(graph_keys(raw_graphs('\n'.join(variant.get('run', []))))) if keys and source is not None else iter(())
    ra = [('graph: ' + json.dumps(in_declaration_order(json.loads(line[7:]), source, keys, next(schemas, '')),
                                 sort_keys=True, ensure_ascii=False)
           if line.startswith('graph: ') and keys and source is not None else line)
          for line in apply_mapping(aligned, run_mapping)]
    unordered = keys & UNORDERED_LISTS
    rb = [('graph: ' + json.dumps(unorder(json.loads(line[7:]), unordered), sort_keys=True, ensure_ascii=False)
           if line.startswith('graph: ') and unordered else line) for line in variant.get('run', [])]

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
    errors = classify(log, {'Case.swift': schema_lines(text)})
    status = ('memory' if code == 'memory' else 'timeout' if code == 'timeout' else 'launch' if code == 'launch' else
              'crash' if CRASH.search(log) or (isinstance(code, int) and code < 0) else 'ok' if code == 0 else
              'macro-diagnostic' if any(p == 'macro' for p, _ in errors) else 'expansion-error' if any(p == 'expansion' for p, _ in errors) else 'error')
    outcome = dict(status=status, errors=errors, seconds=round(time.monotonic() - started, 2), peak_mb=result.peak_mb,
                   columns=columns_of(log))
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
def construct_effect_mix(n):
    """`n` effect cases as a mix: 170 keyed operations, each cancelled by an edge (two effect cases each), and the
    rest events, so the limit is crossed by its mix, not by one construct."""
    keyed = 170
    events = n - 3 * keyed
    operations = '\n'.join(f'    @Operation(activeIn: [Idle.self])\n    enum Op{i} {{ typealias Key = Int }}' for i in range(keyed))
    notes = '\n'.join(f'    @Event\n    enum Note{i} {{}}' for i in range(events))
    starts = ', '.join(f'Op{i}.self' for i in range(keyed))
    emits = ', '.join(f'Note{i}.self' for i in range(events))
    successes = '\n'.join(f'    @Transition(onSuccess: Op{i}.self)\n    fileprivate static func done{i}(_ source: Idle) -> Idle {{ source }}'
                          for i in range(keyed))
    return _schema(f"""    struct Idle: Sendable {{}}
    @Initial case idle(Idle)
    enum Input: Sendable {{ case go, stop }}
{operations}
{notes}
    @Transition(on: Input.go, starts: [{starts}], emits: [{emits}])
    fileprivate static func go(_ source: Idle) -> Change<Idle, Effect.Go> {{ Change(source, effects: []) }}
    @Transition(on: Input.stop, cancels: [{starts}])
    fileprivate static func stop(_ source: Idle) -> Change<Idle, Effect.Stop> {{ Change(source, effects: []) }}
{successes}""")


SIZE_LIMITS = {'phases': (construct_phases, 600), 'inputs': (construct_inputs, 512),
               'operations': (construct_operations, 256), 'effect cases': (construct_events, 512),
               'effect mix': (construct_effect_mix, 512)}


def all_owners(text):
    return re.sub(r'@StateMachine\(mode: \.shared, owners: \[[^\]]*\]\)', '@StateMachine(mode: .shared)', text)


SIZE_WORDS = {'phases': ('phases', 'Snapshot'), 'inputs': ('input cases', 'Input'), 'operations': ('operations', 'Completion'),
              'effect cases': ('operations, cancellations, and events', 'Effect'),
              'effect mix': ('operations, cancellations, and events', 'Effect')}



def size_refusal_problem(outcome, text, construct, count, limit):
    """Why a schema one past a limit was not refused exactly as documented: the one macro diagnostic must name the
    construct, the count it declares, and the bound, and stand at the schema's name. None when it was."""
    what, generated = SIZE_WORDS[construct]
    message = (f'This schema declares {count} {what}; the macro accepts at most {limit}, because Swift checks a switch over '
               f'its {generated} cases only within a fixed budget and type-checks a larger expansion slowly. Split the graph '
               f'into several schemas.')
    if outcome.get('status') != 'macro-diagnostic':
        return f'not refused: {describe(outcome)}'
    macro = [m for p, m in outcome.get('errors', []) if p == 'macro']
    if macro != [message]:
        return f'refused with {macro[:2]}, not {message!r}'
    lines = text.split('\n')
    at = next((('Case.swift', index + 1, line.index('Flow') + 1) for index, line in enumerate(lines) if re.search(r'\benum Flow\b', line)), None)
    # The site is the file as well as the line and column, and nothing but the refused expansion's consequences
    # may stand beside the refusal, whatever classifies it.
    where = [(name, line, column) for (m, name, line), column in outcome.get('columns', []) if m == message]
    if at is None or where != [at]:
        return f'refused at {where}, not at the schema name {at}'
    others = [m for _, m in outcome.get('errors', []) if m != message and not CASCADE.search(m)]
    if others:
        return f'refused beside other errors {others[:2]}'
    return None


def run_size_limits(toolchain, output, cap):
    """At each documented limit the expansion compiles within the time and memory caps; one past it, the macro
    refuses it with exactly the size-limit diagnostic for that construct, count, and bound, at the schema's name. One
    compilation at a time."""
    bounded = Toolchain.__new__(Toolchain)
    bounded.__dict__.update(toolchain.__dict__)
    bounded.timeout = cap
    pattern = next(e['pattern'] for e in LIMITS if e['id'] == 'size-limit')
    rows, results = [], []
    for name, (generate, limit) in SIZE_LIMITS.items():
        at = measure_macro(bounded, output / 'limits' / f'{name}-{limit}', all_owners(generate(limit)), 1)
        over = measure_macro(bounded, output / 'limits' / f'{name}-{limit + 1}', all_owners(generate(limit + 1)), 1)
        under_ok = at['status'] == 'ok'
        problem = size_refusal_problem(over, all_owners(generate(limit + 1)), name, limit + 1, limit)
        over_ok = problem is None
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
                elif outcome['status'] == 'macro-diagnostic' and len(messages) == 1 and re.fullmatch(pattern, messages[0]):
                    kind = 'refusal'
                elif all(re.search(SWIFT_LIMITS, m) for p, m in outcome.get('errors', [])) and outcome.get('errors'):
                    kind = 'swift-limit'
                else:
                    kind = 'error'
                break
            good, size = size, size * 2
        # Above the guaranteed floor only Swift's own documented limits may stop a construct; any other error fails.
        verdict = 'fail' if kind in ('resource', 'error') or (kind == 'swift-limit' and failing <= CEILING_FLOOR) else 'pass'
        found.append(dict(construct=name, ceiling=good, failing=failing, stopped=reason, kind=kind, verdict=verdict,
                          timings=at, limit=min(limit, CEILING_LIMITS.get(name, limit))))
    lines = ['| Construct | Compiles up to | First failing size | Macro time / peak memory at the largest | What stops it | Verdict |',
             '|---|---|---|---|---|---|']
    for row in found:
        largest = row['timings'].get(row['ceiling'], {})
        reach = (f"at least {row['ceiling']}" if row['failing'] is None else f"{row['ceiling'] or '< 8'}")
        stopped = {'resource': 'resource failure: ', 'refusal': 'documented refusal: ', 'swift-limit': "Swift's own limit: ",
                   'error': 'error: '}.get(row['kind'], '')

        lines.append(f"| {row['construct']} | {reach} | {row['failing'] or '-'} | {largest.get('macro_seconds', '-')}s / "
                     f"{largest.get('peak_mb', '-')} MB | {stopped}{(row['stopped'] or 'nothing up to the search limit')[:200]} | {row['verdict']} |")
    (output / 'ceilings.md').write_text('\n'.join(lines) + '\n')
    return found


# Sizes at or below which any failure to compile fails a ceiling search; above it, Swift's own limits (its check of a
# generated switch, its parser's nesting limit) may stop a construct the guide sets no limit for, and only those.
CEILING_FLOOR = 256
SWIFT_LIMITS = (r'the compiler is unable to type-check this expression in reasonable time|reasonable time|'
                r'parser (?:limit|nesting)|too complex|exceeds? (?:the )?(?:maximum|limit)|nesting level|nested too deeply')
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
            'events': [{'id': 'Logged', 'effect': 'logged', 'payload': 'Detail'}, {'id': 'Closing', 'effect': 'closing', 'payload': 'Swift::Void'}],
            'edges': [{'id': 'idle.go', 'name': 'go', 'source': 'idle', 'destination': 'busy', 'trigger': {'input': {'_0': 'go'}},
                       'starts': [], 'cancels': [], 'emits': ['Logged', 'Closing'], 'invalidates': []},
                      {'id': 'idle.stop', 'name': 'stop', 'source': 'idle', 'destination': 'busy', 'trigger': {'input': {'_0': 'stop'}},
                       'starts': [], 'cancels': [], 'emits': [], 'invalidates': []}],
            'routers': []}


PLANT_SYMBOL = 'Fz.Plant.Owned.go(_: Fz.Plant.Owned<Fz.Plant.Idle>) -> Fz.Plant.Owned<Fz.Plant.Busy>'


def synthetic(graph=None, fingerprint=(PLANT_SYMBOL,), report='planted', text=None, **extra):
    """An outcome as a compilation of the self-test schema (or `text`) that printed `graph` would give, with its
    inventory and exported text checked against that source."""
    graph = graph or self_test_graph()
    lines = normalize_run('graph: ' + json.dumps(graph, sort_keys=True) + f'\nreport: {report}')
    outcome = dict(dict(status='ok', errors=[], located=[], fingerprint=list(fingerprint), run=lines, report=report,
                        spelling_problems=[], diagram_problems=[], label_problems=[], seconds=0.0), **extra)
    source = text or SELF_TEST_SCHEMA
    outcome.setdefault('inventory_problems', inventory_problems(source, outcome))
    outcome.setdefault('text_problems', exported_text_problems(source, [graph]))
    return outcome


def self_case(text, rewrites=('paren',), kinds=('eq',), **extra):
    SEED_TEXTS.setdefault('selftest', SELF_TEST_SCHEMA)
    return dict(dict(id='selftest', seed='selftest', rewrites=list(rewrites), kinds=list(kinds), text=text, role='value',
                     mapping={}, behaviour=True, added=[], steps=[]), **extra)


OLD_MERMAID = 'stateDiagram-v2\n    [*] --> {0}\n    {0} --> busy : go\n    {0} --> busy : stop\n    busy --> [*]\n'
NEW_MERMAID = ('stateDiagram-v2\n    state "{0}" as p0\n    state "busy" as p1\n    [*] --> p0\n    p0 --> p1 : go\n    p0 --> p1 : stop\n'
               '    p1 --> [*]\n')
DOT = ('digraph "Plant" {{\n    entry [shape=point];\n    p0 [label="{0}"];\n    p1 [label="busy", peripheries=2];\n'
       '    entry -> p0;\n    p0 -> p1 [label="go"];\n    p0 -> p1 [label="stop"];\n}}\n')
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
          judge(case, base, None, synthetic())[0])
    check('respelled export', 'exported text', judge(case, base, None, synthetic(respelled))[0], judge(case, base, None, synthetic())[0])
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
    # The refusal stands at the attribute, column 5 of its line, unless a test moves it.
    refusal = lambda line, extra=(), column=5, text=message: dict(
        status='macro-diagnostic', errors=[('macro', text)] + [(p, m) for p, m, _, _ in extra],
        located=[('macro', text, 'Case.swift', line)] + list(extra), columns=[((text, 'Case.swift', line), column)])
    refused_case = self_case(refused_text, rewrites=['declaration-attributes'], kinds=['safe'], expect='custom-attribute')
    check('refusal away from the changed site', 'refusal site', judge(refused_case, base, None, refusal(3))[0],
          judge(refused_case, base, None, refusal(attribute_line))[0])
    check('exact refusal with another error', 'exact refusal', judge(refused_case, base, None, refusal(attribute_line, [('expansion', 'type mismatch', 'Case.swift', 4)]))[0],
          judge(refused_case, base, None, refusal(attribute_line, [('authored', "cannot find type 'Effect' in scope", 'Case.swift', 20)]))[0])
    owners_message = "Owner '.isolatedHost' is unavailable in .ownedOnly, which supports only .owned."
    owners_case = self_case(base_text, rewrites=['owner-excluded'], kinds=['break'])
    witness = lambda extra=(): dict(status='expansion-error', errors=[('expansion', f"'_owners' is unavailable: {owners_message}")] + [(p, m) for p, m, _, _ in extra],
                                    located=[('expansion', f"'_owners' is unavailable: {owners_message}", 'Case.swift', 3)] + list(extra), columns=[])
    check('expansion witness beside an unrelated expansion error', 'exact refusal',
          judge(owners_case, base, None, witness([('expansion', "cannot convert value of type 'Int' to 'String'", 'Case.swift', 9)]))[0],
          judge(owners_case, base, None, witness())[0])
    phase_message = "Phase 'idle' needs a distinct nongeneric struct or enum declared directly inside the schema, named with a Swift identifier that needs no backticks; aliases are unsupported."
    aliased = base_text.replace('@Initial case idle(Idle)', '@Initial case idle(FuzzAlias)')
    alias_case = self_case(aliased, rewrites=['alias-local'], role='phase')
    phase_line = aliased.split('\n').index('    @Initial case idle(FuzzAlias)') + 1
    alias_column = aliased.split('\n')[phase_line - 1].index('FuzzAlias') + 1
    other = dict(status='macro-diagnostic', errors=[('macro', 'Some other refusal.')], located=[('macro', 'Some other refusal.', 'Case.swift', phase_line)],
                 columns=[(('Some other refusal.', 'Case.swift', phase_line), alias_column)])
    alias = dict(status='macro-diagnostic', errors=[('macro', phase_message)], located=[('macro', phase_message, 'Case.swift', phase_line)],
                 columns=[((phase_message, 'Case.swift', phase_line), alias_column)])
    check('phase alias refused for another reason', 'limit message', judge(alias_case, base, None, other)[0], judge(alias_case, base, None, alias)[0])
    move_schema = REWRITE_BY_NAME['schema-to-file'].function
    moved, _ = move_schema(aliased, None)[0]
    moved_case = self_case(moved, rewrites=['alias-local', 'schema-to-file'], kinds=['eq', 'eq'], role='phase')
    phase_line, source = next((i, line) for i, line in enumerate(split_case(moved)[0]['Other.swift'].splitlines(), 1)
                              if 'case idle(FuzzAlias)' in line)
    def moved_refusal(name, token):
        return dict(alias, located=[('macro', phase_message, name, phase_line)],
                    columns=[((phase_message, name, phase_line), source.index(token) + 1)])

    correct = moved_refusal('Other.swift', 'FuzzAlias')
    check('refusal at an unchanged token of a moved schema', 'refusal token',
          judge(moved_case, base, None, moved_refusal('Other.swift', 'case'))[0], judge(moved_case, base, None, correct)[0])
    check('refusal at the moved schema coordinates in another file', 'refusal site',
          judge(moved_case, base, None, moved_refusal('Case.swift', 'FuzzAlias'))[0], judge(moved_case, base, None, correct)[0])
    client_seed = base_text + CLIENT_MARKER + 'let before = 1\nlet after = 2\n'
    SEED_TEXTS['selftest-client-lines'] = client_seed
    client_case = self_case(client_seed.replace('let after', 'let inserted = 0\nlet after'),
                            seed='selftest-client-lines', rewrites=['unrelated-declarations'])
    def client_error(name, line):
        message = 'cannot convert value to expected argument type'
        return dict(status='client-error', errors=[('client', message)], located=[('client', message, name, line)],
                    client_sites=[(name, line)])

    changed_client = judge(client_case, base, None, client_error('Client.swift', 2))[0]
    check('client error on untouched line after an insertion', 'client error site',
          judge(client_case, base, None, client_error('Client.swift', 3))[0],
          'pass' if changed_client == 'artefact' else changed_client)
    deleted = dict(client_case, text=client_seed.replace('let before = 1\n', ''))
    check('client error on untouched line after a deletion', 'client error site',
          judge(deleted, base, None, client_error('Client.swift', 1))[0],
          'pass' if changed_client == 'artefact' else changed_client)
    check('client error in a missing source file', 'client error site',
          judge(client_case, base, None, client_error('Missing.swift', 2))[0],
          'pass' if changed_client == 'artefact' else changed_client)
    unordered_client = ('func usePlant() {\n'
                        '    _ = Plant.MainActorHost(Plant.Idle(), /*fuzz-args*/ onClosing: {}, onLogged: { _ in } /*end-args*/)\n'
                        '}\n')
    ordered_client = order_client_arguments(unordered_client, base_text)
    SEED_TEXTS['selftest-client-order'] = base_text + CLIENT_MARKER + unordered_client
    ordered = dict(client_case, seed='selftest-client-order', text=base_text + CLIENT_MARKER + ordered_client)
    check('client error on a line whose compiled arguments were unchanged', 'client error site',
          judge(ordered, base, None, client_error('Client.swift', 2))[0],
          'pass' if ordered_client != unordered_client and changed_client == 'artefact' else 'fail')
    del SEED_TEXTS['selftest-client-lines']
    del SEED_TEXTS['selftest-client-order']
    unexit = "Phase 'busy' has no outgoing transitions; mark it '@Terminal' or declare a transition from it."
    broken = self_case(base_text.replace('@Terminal case busy', 'case busy'), rewrites=['terminal-flip'], kinds=['break'],
                       refusal=r"Phase 'busy' has no outgoing transitions; mark it '@Terminal' or declare a transition from it\.")
    busy_line = base_text.split('\n').index('    @Terminal case busy(Busy)') + 1
    busy_column = base_text.replace('@Terminal case busy', 'case busy').split('\n')[busy_line - 1].index('busy') + 1
    finding = lambda text, column=busy_column, extra=(): dict(
        status='macro-diagnostic', errors=[('macro', text)] + [(p, m) for p, m, _, _ in extra],
        located=[('macro', text, 'Case.swift', busy_line)] + list(extra), columns=[((text, 'Case.swift', busy_line), column)])
    check('breaking rewrite rejected only by the linker', 'rejection', judge(broken, base, None, dict(status='link-error', errors=[('link', 'undefined symbol')], located=[]))[0],
          judge(broken, base, None, finding(unexit))[0])
    check('breaking rewrite rejected with another diagnostic', 'documented rejection', judge(broken, base, None, finding('Unrelated.'))[0],
          judge(broken, base, None, finding(unexit))[0])
    other_phase = "Phase 'idle' has no outgoing transitions; mark it '@Terminal' or declare a transition from it."
    check('breaking rewrite refused for a phase it did not change (broad graph-validity match)', 'exact finding',
          judge(broken, base, None, finding(other_phase))[0], judge(broken, base, None, finding(unexit))[0])
    check('breaking rewrite refused at another token of the line', 'refusal token', judge(broken, base, None, finding(unexit, column=15))[0],
          judge(broken, base, None, finding(unexit))[0])
    check('refusal whose message only starts as documented', 'whole message',
          judge(refused_case, base, None, refusal(attribute_line, text="Remove '@MainActor'"))[0],
          judge(refused_case, base, None, refusal(attribute_line))[0])
    check('exact refusal beside a Swift error at the changed declaration', 'consequent diagnostics',
          judge(refused_case, base, None, refusal(attribute_line, [('authored', "cannot convert value of type 'Int' to specified type 'String'", 'Case.swift', attribute_line)]))[0],
          judge(refused_case, base, None, refusal(attribute_line))[0])
    check('refusal at the right line, wrong column', 'refusal token', judge(refused_case, base, None, refusal(attribute_line, column=17))[0],
          judge(refused_case, base, None, refusal(attribute_line))[0])

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
    nested_source = ('extension Outer {\n    @StateMachine(mode: .shared)\n    enum Nested {\n'
                     '        struct Payload { let text = "}" }\n    }\n}\nfunc outside() {}')
    spans = {'Case.swift': [], 'Other.swift': schema_lines(nested_source)}
    message = "cannot convert return expression"
    check('a schema error attributed to client code after a file move', 'diagnostic origin',
          'fail' if classify(f'Other.swift:4:3: error: {message}', spans) == [('authored', message)] else 'pass',
          'pass' if spans['Other.swift'] == [(2, 5)]
          and classify(f'Case.swift:4:3: error: {message}', spans) == [('client', message)]
          and classify(f'Other.swift:7:3: error: {message}', spans) == [('client', message)] else 'fail')
    named_values = REWRITE_BY_NAME['schema-named-value'].function
    decoys = '/* outer /* inner */ @StateMachine(mode: .shared) enum Decoy {} */\n'
    decoys += 'let example = "@StateMachine(mode: .shared) enum AlsoDecoy {}"\n'
    initial = named_values(decoys + base_text, None)
    check('a comment or string treated as a schema', 'rewrite applicability',
          'fail' if not named_values(decoys, None) else 'pass',
          'pass' if {info['site'] for _, info in initial} == {'static var Plant inside Plant', 'static var Plant in an extension'} else 'fail')
    check('a rewrite redeclares a property already in the schema or an extension', 'rewrite applicability',
          'fail' if initial and all(not named_values(text, None) for text, _ in initial) else 'pass',
          'pass' if len(initial) == 2 else 'fail')
    sugar_cases = {
        '[Swift::Int]': 'Array<Swift::Int>',
        '[Swift::String: Swift::Int]': 'Dictionary<Swift::String, Swift::Int>',
        '[(left: Int, right: Int)]': 'Array<(left: Int, right: Int)>',
        '[2 of Swift::Int]': None,
    }
    check('a module selector read as a dictionary separator', 'collection type spelling',
          'fail' if desugar('[Swift::Int]') != 'Dictionary<Swift, :Int>' else 'pass',
          'pass' if all(desugar(source) == wanted for source, wanted in sugar_cases.items()) else 'fail')
    add_helper = REWRITE_BY_NAME['helper-basename'].function
    first_helper = add_helper(base_text, None)[0][0]
    helpers = add_helper(first_helper, None)
    check('two helper rewrites declare the same type', 'rewrite applicability',
          'fail' if helpers and all('FuzzNotes2' in info['site'] for _, info in helpers) else 'pass',
          'pass' if all(text.count('FuzzNotes2') == 1 for text, _ in helpers) else 'fail')
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
    swapped_events = self_test_graph()
    swapped_events['events'] = swapped_events['events'][::-1]
    check('reordered events, labels kept in the old order', 'ordered label comparison',
          judge(reordered, synthetic(fingerprint=[right_init]), None, synthetic(swapped_events, fingerprint=[right_init]))[0],
          judge(reordered, synthetic(fingerprint=[right_init]), None, synthetic(swapped_events, fingerprint=[wrong_init]))[0])

    # (7) Diagrams.
    graph = self_test_graph()
    noted = json.loads(json.dumps(graph).replace('"idle"', '"note"').replace('idle.', 'note.'))
    check('Mermaid state named note', 'Mermaid reader', 'fail' if check_diagrams(noted, OLD_MERMAID.format('note'), DOT.format('note')) else 'pass',
          'pass' if not check_diagrams(noted, NEW_MERMAID.format('note'), DOT.format('note')) else 'fail')
    check('Mermaid describing another graph', 'Mermaid structure', 'fail' if check_diagrams(graph, NEW_MERMAID.format('idle').replace('p0 --> p1 : stop', 'p1 --> p0 : stop'), DOT.format('idle')) else 'pass',
          'pass' if not check_diagrams(graph, NEW_MERMAID.format('idle'), DOT.format('idle')) else 'fail')
    check('DOT name with an unescaped quote', 'DOT reader', 'fail' if check_diagrams(graph, NEW_MERMAID.format('idle'), DOT.replace('"Plant"', '"Pl"ant"').format('idle')) else 'pass',
          'pass' if not check_diagrams(graph, NEW_MERMAID.format('idle'), DOT.format('idle')) else 'fail')
    check('DOT edge missing', 'DOT structure', 'fail' if check_diagrams(graph, NEW_MERMAID.format('idle'), DOT.format('idle').replace('    p0 -> p1 [label="stop"];\n', '')) else 'pass',
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
    globals()['measure_macro'] = lambda *a, **k: dict(status='error', errors=[('authored', 'some unrelated error')], seconds=1, peak_mb=10, macro_seconds=0)
    try:
        errored = run_ceilings(toolchain, output / 'self-test' / 'ceilings-error', 1, 1, 1024, '^phases$')[0]
    finally:
        globals()['measure_macro'] = real_measure
    check('ceiling stopped by an arbitrary compiler error', 'ceiling verdict', errored['verdict'], refused['verdict'])

    # (9) Exported text, against the author's own.
    selfish = base_text.replace('@Initial case idle(Idle)', '@Initial case idle(Self.Idle)')
    check('exported text drops Self.', 'exported text', 'fail' if exported_text_problems(selfish, [self_test_graph()]) else 'pass',
          'pass' if not exported_text_problems(base_text, [self_test_graph()]) else 'fail')
    parenthesized = base_text.replace('case go(Detail), stop', 'case go((Detail)), stop')
    check('exported text drops parentheses', 'exported text', 'fail' if exported_text_problems(parenthesized, [self_test_graph()]) else 'pass',
          'pass' if not exported_text_problems(parenthesized, [json.loads(json.dumps(self_test_graph()).replace('"payload": "Detail"}, {"id": "stop"', '"payload": "(Detail)"}, {"id": "stop"'))]) else 'fail')
    defaulted = self_test_graph()
    defaulted['events'][1]['payload'] = 'Void'
    check('omitted payload not spelled through the standard module', 'exported text', 'fail' if exported_text_problems(base_text, [defaulted]) else 'pass',
          'pass' if not exported_text_problems(base_text, [self_test_graph()]) else 'fail')

    # (10) What the input declares.
    check('successful outcome with no symbols and no output', 'inventory', 'fail' if seed_problems('selftest', synthetic(fingerprint=[], run=[])) else 'pass',
          'pass' if not seed_problems('selftest', base) else 'fail')
    dropped = self_test_graph()
    dropped['phases'] = dropped['phases'][:1]
    check('graph that leaves a declared phase out', 'inventory', 'fail' if inventory_problems(base_text, synthetic(dropped)) else 'pass',
          'pass' if not inventory_problems(base_text, base) else 'fail')
    two = base_text + '\n// fuzz-file: Other.swift\nimport StateMachine\n\n' + base_text.split('\n', 2)[2].replace('enum Plant', 'enum Other').split('extension Plant')[0]
    check('schema in another file without a graph', 'inventory', 'fail' if inventory_problems(two, base) else 'pass',
          'pass' if not inventory_problems(base_text, base) else 'fail')
    check('probe count read from the graph, not the input', 'probe count', 'fail' if spelling_probes(base_text, [dropped])[2] else 'pass',
          'pass' if not spelling_probes(base_text, [self_test_graph()])[2] else 'fail')

    # (11) What decides whether a case is probed.
    check('alias right-hand side changed under an unchanged spelling', 'probe cache',
          'fail' if declaration_signature('typealias T = Int\n') != declaration_signature('typealias T = String\n') else 'pass',
          'pass' if declaration_signature('typealias T = Int\n') == declaration_signature('typealias T = Int\n') else 'fail')
    check('import changed under an unchanged spelling', 'probe cache',
          'fail' if declaration_signature('import Foundation\n') != declaration_signature('import Darwin\n') else 'pass',
          'pass' if declaration_signature('import Foundation\n') == declaration_signature('import Foundation\n') else 'fail')
    here = 'import Foundation\nenum A {}\n// fuzz-file: Other.swift\nenum B {}\n'
    there = 'enum A {}\n// fuzz-file: Other.swift\nimport Foundation\nenum B {}\n'
    check('import moved to another file of the module', 'probe cache',
          'fail' if declaration_signature(here) != declaration_signature(there) else 'pass',
          'pass' if declaration_signature(here) == declaration_signature(here) else 'fail')

    # (12) A crash before any allowance, and through reduction.
    crashing = dict(status='crash', crash='Stack dump:', errors=[], located=[])
    check('crash behind a documented limit of the other rewrites', 'judgment order',
          judge(case, base, None, crashing, ('limit:phase-alias', 'a documented limit', 'x'))[0],
          judge(case, base, None, base, ('limit:phase-alias', 'a documented limit', 'x'))[0])
    check('reduction to a case that fails another way', 'reduction',
          'fail' if not same_failure(dict(expected='E', status='crash'), dict(status='ok'), 'fail', 'E') else 'pass',
          'pass' if same_failure(dict(expected='E', status='crash'), dict(status='crash'), 'fail', 'E') else 'fail')

    # (13) Declaration order from the variant's own source.
    sorted_events = self_test_graph()
    sorted_events['events'] = sorted(sorted_events['events'], key=lambda e: e['id'])
    in_order = self_case(base_text, rewrites=['reorder-members'])
    check('declaration-ordered list alphabetized by the generator', 'order comparison',
          judge(in_order, base, None, synthetic(sorted_events))[0], judge(in_order, base, None, synthetic())[0])

    idle_edge = dict(id='idle.retry', name='retry', source='idle')
    busy_edge = dict(id='busy.retry', name='retry', source='busy')
    schema = """@StateMachine(mode: .shared)
enum SCHEMA {
    @Initial case idle(Idle)
    case busy(Busy)
    EDGES
}
"""
    idle_retry = '@Transition(on: Input.retry)\n    static func retry(_ source: Idle) -> Busy { Busy() }'
    busy_retry = '@Transition(on: Input.retry)\n    static func retry(_ source: Busy) -> Busy { source }'
    plant = schema.replace('SCHEMA', 'Plant').replace('EDGES', busy_retry + '\n    ' + idle_retry)
    other = schema.replace('SCHEMA', 'Other').replace('EDGES', idle_retry + '\n    ' + busy_retry)
    plant_graph = dict(name='Plant', edges=[idle_edge, busy_edge])
    other_graph = dict(name='Other', edges=[idle_edge, busy_edge])
    reversed_plant = dict(plant_graph, edges=[busy_edge, idle_edge])
    reversed_other = dict(other_graph, edges=[busy_edge, idle_edge])

    def graph_run(graphs, paths=(), report='planted'):
        return dict(status='ok', graph_paths=paths,
                    run=normalize_run('\n'.join('graph: ' + json.dumps(graph) for graph in graphs) + f'\nreport: {report}'))

    def comparison(reference, variant, **kwargs):
        return 'pass' if same_outcome(reference, variant, kwargs.pop('mapping', {}), True, **kwargs)[0] else 'fail'

    original_order = graph_run([plant_graph, other_graph])
    changed_order = graph_run([reversed_plant, other_graph])
    check('overloaded edges left in seed order after their declarations move', 'order comparison',
          comparison(original_order, original_order, text=plant + other, order_free=['members']),
          comparison(original_order, changed_order, text=plant + other, order_free=['members']))
    nested_input = plant.replace('case busy(Busy)', 'case busy(\n        Busy\n    )\n    enum Input { case retry(Idle) }')
    check('an Input case mistaken for a phase case when ordering overloaded edges', 'order comparison',
          comparison(original_order, original_order, text=nested_input + other, order_free=['members']),
          comparison(original_order, changed_order, text=nested_input + other, order_free=['members']))
    nested_schema = EMBEDDED_SEEDS['same-basename']
    phase_alias = REWRITE_BY_NAME['alias-local'].function(nested_schema, None)
    phase_aliases = {info['site']: info['role'] for _, info in phase_alias}
    accepts_phase = any(info['site'] == 'return:End' for _, info in REWRITE_BY_NAME['alias-nested'].function(nested_schema, None))
    has_phase_roles = lambda roles: roles.get('phase-case:Idle') == roles.get('return:End') == 'phase'
    check('indented phase payloads treated as ordinary alias sites', 'phase site selection',
          'pass' if has_phase_roles({'case:Idle': 'value', 'return:End': 'value'}) else 'fail',
          'pass' if has_phase_roles(phase_aliases) and not accepts_phase else 'fail')
    ordinary_end = nested_schema.replace('@Initial case idle(Idle)', 'struct End: Sendable {}\n        @Initial case idle(Idle)', 1)
    ordinary_end = ordinary_end.replace('case go }', 'case go(End) }', 1).replace('func go(_ source: Idle)', 'func go(_ source: Idle, _ value: End)', 1)
    roles = {repr(site): site_role(site) for site in type_sites(ordinary_end)}
    separates_payloads = lambda roles: roles.get('param:End') == roles.get('case:End') == 'value' and roles.get('return:End') == 'phase'
    check("another schema's phase type prevents a valid value alias", 'phase site selection',
          'pass' if separates_payloads(dict(roles, **{'param:End': 'phase'})) else 'fail',
          'pass' if separates_payloads(roles) else 'fail')
    check('order from one schema applied to another schema with the same edge names', 'order comparison',
          comparison(original_order, graph_run([reversed_plant, reversed_other]), text=plant + other, order_free=['members']),
          comparison(original_order, changed_order, text=plant + other, order_free=['members']))
    multi_source = '@Transition(from: [Busy.self, Idle.self], on: Input.retry)\n    static func retry() -> Busy { Busy() }'
    listed = schema.replace('SCHEMA', 'Plant').replace('EDGES', multi_source)
    check('multi-source edges kept in the old source-list order', 'order comparison',
          comparison(graph_run([plant_graph]), graph_run([plant_graph]), text=listed, order_free=['lists']),
          comparison(graph_run([plant_graph]), graph_run([reversed_plant]), text=listed, order_free=['lists']))
    named_set = ('@PhaseSet([Busy.self, Idle.self])\n    fileprivate enum Active {}\n'
                 '    @Transition(from: Active.self, on: Input.retry)\n    static func retry() -> Busy { Busy() }')
    named_listed = schema.replace('SCHEMA', 'Plant').replace('EDGES', named_set)
    check('named @PhaseSet list alphabetized by the generator', 'order comparison',
          comparison(graph_run([plant_graph]), graph_run([plant_graph]), text=named_listed, order_free=['lists']),
          comparison(graph_run([plant_graph]), graph_run([reversed_plant]), text=named_listed, order_free=['lists']))
    nested_forward_set = (
        'enum Outer {\n'
        '    @StateMachine(mode: .shared)\n'
        '    enum Plant {\n'
        '        @Initial case idle(Idle)\n'
        '        case busy(Busy)\n'
        '        @StateMachine::Transition(`from`: /* set */ `Active`.`self`, on: Input.retry)\n'
        '        static func `retry`() -> Busy { Busy() }\n'
        '        @StateMachine::PhaseSet(/* order */ [`Busy`.`self`, `Idle`.`self`])\n'
        '        private nonisolated enum `Active` {}\n'
        '    }\n'
        '}\n'
        '@StateMachine(mode: .shared)\n'
        'enum Other {\n'
        '    @Initial case idle(Idle)\n'
        '    case busy(Busy)\n'
        '    @PhaseSet([Idle.self, Busy.self])\n'
        '    fileprivate enum Active {}\n'
        '    @Transition(from: Active.self, on: Input.retry)\n'
        '    static func retry() -> Busy { Busy() }\n'
        '}\n'
    )
    check('nested forward-declared qualified @PhaseSet alphabetized or confused with another schema', 'order comparison',
          comparison(original_order, original_order, text=nested_forward_set, order_free=['lists']),
          comparison(original_order, changed_order, text=nested_forward_set, order_free=['lists']))
    phase_set_term_seed = (
        'import StateMachine\n\n@StateMachine(mode: .shared)\nnonisolated enum Plant: Sendable {\n'
        '    struct Idle: Sendable {}\n    struct Done: Sendable {}\n'
        '    @Initial case idle(Idle)\n    @Terminal case done(Done)\n'
        '    enum Input: Sendable { case finish }\n'
        '    @PhaseSet([Idle.self])\n    fileprivate enum Live {}\n'
        '    @Transition(from: Live.self, on: Input.finish)\n'
        '    fileprivate static func finish() -> Done { Done() }\n}\n'
    )
    SEED_TEXTS['selftest-phase-set-anchor'] = phase_set_term_seed
    term_broken = phase_set_term_seed.replace('@PhaseSet([Idle.self])', '@PhaseSet([Idle.self, Done.self])')
    term_line = term_broken.split('\n').index('    @Transition(from: Live.self, on: Input.finish)') + 1
    term_src = term_broken.split('\n')[term_line - 1]
    term_msg = ("Terminal phase 'done' in @PhaseSet 'Live' cannot have an outgoing transition 'finish'; "
                "remove '@Terminal', remove 'Done.self' from 'Live', or remove the transition.")
    term_case = self_case(
        term_broken, seed='selftest-phase-set-anchor', rewrites=['phase-set-use-invalid'], kinds=['break'],
        refusal=re.escape(term_msg), token=r'`?Live`?\.self')
    term_outcome = lambda col: dict(
        status='macro-diagnostic', errors=[('macro', term_msg)],
        located=[('macro', term_msg, 'Case.swift', term_line)],
        columns=[((term_msg, 'Case.swift', term_line), col)])
    check('@PhaseSet terminal refusal anchored at @Transition instead of Live.self', 'refusal token',
          judge(term_case, base, None, term_outcome(term_src.index('@Transition') + 1))[0],
          judge(term_case, base, None, term_outcome(term_src.index('Live.self') + 1))[0])
    del SEED_TEXTS['selftest-phase-set-anchor']

    moved = graph_run([reversed_plant, plant_graph], ['Left.Plant', 'Right.Plant'])
    before_move = graph_run([plant_graph, reversed_plant], ['Right.Plant', 'Left.Plant'])
    wrong_after_move = graph_run([plant_graph, reversed_plant], ['Left.Plant', 'Right.Plant'])
    check('graphs swapped between schemas of the same name after a file move', 'schema paths',
          comparison(before_move, wrong_after_move), comparison(before_move, moved))

    phase_rename = {'idle': 'href'}
    renamed_graph = dict(plant_graph, edges=[dict(idle_edge, id='href.retry', source='href'), busy_edge])
    report = graph_run([plant_graph], report='retained 1; idle.retry')
    renamed_report = graph_run([renamed_graph], report='retained 1; href.retry')
    check('phase rename with a stale receipt ID in the report', 'rename comparison',
          comparison(report, graph_run([renamed_graph], report='retained 1; idle.retry'), mapping=phase_rename),
          comparison(report, renamed_report, mapping=phase_rename))
    check('phase rename with a changed status beside the correct receipt ID', 'rename comparison',
          comparison(report, graph_run([renamed_graph], report='retained 2; href.retry'), mapping=phase_rename),
          comparison(report, renamed_report, mapping=phase_rename))

    raw = module_text(rename(EMBEDDED_SEEDS['same-basename'], 'Right', '`Left.Flow`'))
    parsed_paths = schema_path_list(raw)
    check('harness that flattens a raw identifier into a dotted path', 'schema paths',
          'fail' if '`Left.Flow`.Flow.graph' not in graph_accessor(raw, ['Left.Flow', 'Left.Flow.Flow']) else 'pass',
          'pass' if parsed_paths == ['Left.Flow', '`Left.Flow`.Flow'] and '`Left.Flow`.Flow.graph' in graph_accessor(raw, parsed_paths) else 'fail')
    available = '// fuzz-file: Other.swift\n@available(macOS 14, *)\n' + plant
    check('cross-file graph accessor omitting the schema availability guard', 'harness availability',
          'fail' if 'if #available(macOS 14, *)' not in graph_accessor('', ['Plant']) else 'pass',
          'pass' if 'if #available(macOS 14, *)' in graph_accessor(module_text(available), ['Plant']) else 'fail')

    pool = ('import StateMachine\n\n@StateMachine(mode: .shared, owners: [.mainActorHost])\nnonisolated enum Pool: Sendable {\n'
            '    struct Idle: Sendable {}\n    @Initial case idle(Idle)\n    @Operation(activeIn: [Idle.self])\n    enum Fetch {}\n'
            '    @Event\n    enum Logged {}\n}\n')
    pooled = 'Fz.Pool.MainActorHost.init(_: Fz.Pool.Idle, {0}configuration: StateMachine.Configuration) -> Fz.Pool.MainActorHost'
    driver = 'fetchDriver: @MainActor () async -> (), '
    handler = 'onLogged: @MainActor () -> (), '
    check('driver-only and handler-only initializers standing in for one', 'declaration-order labels',
          'fail' if label_order_problems([pooled.format(driver), pooled.format(handler)], pool) else 'pass',
          'pass' if not label_order_problems([pooled.format(driver + handler)], pool) else f'fail: {label_order_problems([pooled.format(driver + handler)], pool)}')
    check('managed owner without its ordered initializer', 'declaration-order labels',
          'fail' if label_order_problems([], base_text) else 'pass', 'pass' if not label_order_problems([right_init], base_text) else 'fail')

    # (14) External uses.
    presence, absence, marked, _ = client_use_sources(base_text)
    lines = absence.split('\n')
    absent_log = ''.join(f"Absent.swift:{line}:9: error: type 'Plant' has no member '{owner}'\n" for owner, line in marked)
    check('unselected owner present', 'external uses', 'fail' if client_use_judgement('', 0, absent_log.split('\n', 1)[1], marked) else 'pass',
          'pass' if not client_use_judgement('', 0, absent_log, marked) else 'fail')
    check('selected owner unusable from another module', 'external uses',
          'fail' if client_use_judgement("Uses.swift:5:9: error: cannot find 'Plant' in scope\n", 1, absent_log, marked) else 'pass',
          'pass' if not client_use_judgement('', 0, absent_log, marked) else 'fail')
    widened = client_use_sources(base_text.replace('owners: [.owned, .local, .mainActorHost]', 'owners: [.owned, .local, .mainActorHost, .shared]'))
    spread_owners = base_text.replace('@StateMachine(mode: .shared, owners: [.owned, .local, .mainActorHost])',
                                      '@StateMachine(\n    mode: .shared,\n    `owners`: [.owned, .local]\n)')
    # An unselected owner that exists, behind an attribute spread over lines with an escaped label.
    _, _, spread_marked, _ = client_use_sources(spread_owners)
    spread_log = ''.join(f"Absent.swift:{line}:9: error: type 'Plant' has no member '{owner}'\n" for owner, line in spread_marked)
    check('unselected owner present behind an attribute spread over lines', 'external uses',
          'fail' if client_use_judgement('', 0, '', spread_marked) else 'pass',
          'pass' if spread_marked and not client_use_judgement('', 0, spread_log, spread_marked) else 'fail')
    check('uses generated from the schema, not fixed', 'external uses',
          'fail' if {o for o, _ in widened[2]} != {o for o, _ in marked} and 'Plant.Shared.self' in widened[0] else 'pass',
          'pass' if 'MainActorHost.self' in presence and {o for o, _ in marked} == {'Shared', 'ActorHost', 'IsolatedHost'} else 'fail')


    # (15) Diagrams, every documented feature.
    bare = '\n'.join(l for l in NEW_MERMAID.format('idle').split('\n') if not l.startswith('    state ')) 
    check('Mermaid without its state declarations', 'Mermaid declarations', 'fail' if check_diagrams(graph, bare, DOT.format('idle')) else 'pass',
          'pass' if not check_diagrams(graph, NEW_MERMAID.format('idle'), DOT.format('idle')) else 'fail')
    restoring = self_test_graph()
    restoring['restorable'] = ['busy']
    restored_mermaid = NEW_MERMAID.format('idle').replace('    [*] --> p0\n', '    [*] --> p0\n    [*] --> p1 : restored\n')
    restored_dot = DOT.format('idle').replace('    entry -> p0;\n', '    entry -> p0;\n    entry -> p1 [label="restored", style=dashed];\n')
    check('DOT restoration edge without its dashed style', 'DOT edge style',
          'fail' if check_diagrams(restoring, restored_mermaid, restored_dot.replace(', style=dashed', '')) else 'pass',
          'pass' if not check_diagrams(restoring, restored_mermaid, restored_dot) else f'fail: {check_diagrams(restoring, restored_mermaid, restored_dot)[:1]}')
    check('Mermaid label with a character Mermaid reads', 'Mermaid label', 'fail' if mermaid_label('x:y') is None else 'pass',
          'pass' if mermaid_label('x' + chr(0x05B0)) == 'x' + chr(0x05B0) else 'fail')

    # (16) Allowances explain the whole difference, and stand on the guide.
    shared = 'Fz.Plant.Owned.go(_: Fz.Plant.Owned<Fz.Plant.Idle>, _: Swift.Int) -> Fz.Plant.Owned<Fz.Plant.Busy>'
    lost = 'Fz.Plant.Owned.stop(_: Fz.Plant.Owned<Fz.Plant.Idle>) -> Fz.Plant.Owned<Fz.Plant.Busy>'
    ownership = self_case(base_text, rewrites=['shared-param'])
    check('documented respelling beside a lost member', 'whole-difference allowance',
          judge(ownership, synthetic(fingerprint=[shared, lost]), None, synthetic(fingerprint=[shared.replace('_: Swift.Int', '_: __shared Swift.Int')]))[0],
          judge(ownership, synthetic(fingerprint=[shared, lost]), None, synthetic(fingerprint=[shared.replace('_: Swift.Int', '_: __shared Swift.Int'), lost]))[0])
    overload = 'Fz.Plant.Owned.go(_: Fz.Plant.Owned<Fz.Plant.Idle>, value: Swift.Int) -> Fz.Plant.Owned<Fz.Plant.Busy>'
    respelled_only = [shared.replace('_: Swift.Int', '_: __shared Swift.Int'), lost]
    check('documented respelling beside a changed report', 'whole-difference allowance',
          judge(ownership, synthetic(fingerprint=[shared, lost]), None, synthetic(fingerprint=respelled_only, report='wrong edge'))[0],
          judge(ownership, synthetic(fingerprint=[shared, lost]), None, synthetic(fingerprint=respelled_only))[0])
    check('lost overload excused by another overload of the same name', 'whole-difference allowance',
          judge(ownership, synthetic(fingerprint=[shared, overload, lost]), None, synthetic(fingerprint=[shared.replace('_: Swift.Int', '_: __shared Swift.Int'), lost]))[0],
          judge(ownership, synthetic(fingerprint=[shared, lost]), None, synthetic(fingerprint=[shared.replace('_: Swift.Int', '_: __shared Swift.Int'), lost]))[0])
    reordered_ownership = self_case(swapped_text, rewrites=['shared-param', 'reorder-members'])
    check('documented respelling beside reordered members with stale initializer labels', 'whole-difference allowance',
          judge(reordered_ownership, synthetic(fingerprint=[shared, right_init]), None,
                synthetic(swapped_events, fingerprint=[shared.replace('_: Swift.Int', '_: __shared Swift.Int'), right_init]))[0],
          judge(reordered_ownership, synthetic(fingerprint=[shared, right_init]), None,
                synthetic(swapped_events, fingerprint=[shared.replace('_: Swift.Int', '_: __shared Swift.Int'), wrong_init]))[0])
    check('allowance whose guide sentence is gone', 'guide quotation',
          'fail' if missing_quotations([dict(id='gone', doc='A sentence the guide never had.')], DOC.read_text()) else 'pass',
          'pass' if not missing_quotations(LIMITS, DOC.read_text()) else f"fail: {[e['id'] for e in missing_quotations(LIMITS, DOC.read_text())]}")

    # (17) Size limits: the construct, the count, the bound, and the place.
    flow = construct_phases(3)
    flow_line = flow.split('\n').index(next(l for l in flow.split('\n') if 'enum Flow' in l)) + 1
    flow_column = flow.split('\n')[flow_line - 1].index('Flow') + 1
    sized = lambda message, column=flow_column: dict(status='macro-diagnostic', errors=[('macro', message)],
                                                    columns=[((message, 'Case.swift', flow_line), column)])
    right = ('This schema declares 601 phases; the macro accepts at most 600, because Swift checks a switch over its Snapshot cases '
             'only within a fixed budget and type-checks a larger expansion slowly. Split the graph into several schemas.')
    check('size refusal for another construct', 'size limit',
          'fail' if size_refusal_problem(sized(right.replace('601 phases', '601 input cases')), flow, 'phases', 601, 600) else 'pass',
          'pass' if not size_refusal_problem(sized(right), flow, 'phases', 601, 600) else 'fail')
    check('size refusal with another count', 'size limit',
          'fail' if size_refusal_problem(sized(right.replace('601', '700')), flow, 'phases', 601, 600) else 'pass',
          'pass' if not size_refusal_problem(sized(right), flow, 'phases', 601, 600) else 'fail')
    check('size refusal away from the schema name', 'size limit',
          'fail' if size_refusal_problem(sized(right, column=1), flow, 'phases', 601, 600) else 'pass',
          'pass' if not size_refusal_problem(sized(right), flow, 'phases', 601, 600) else 'fail')
    elsewhere = dict(sized(right), columns=[((right, 'Other.swift', flow_line), flow_column)])
    check('size refusal at the right line and column of another file', 'size limit',
          'fail' if size_refusal_problem(elsewhere, flow, 'phases', 601, 600) else 'pass',
          'pass' if not size_refusal_problem(sized(right), flow, 'phases', 601, 600) else 'fail')
    beside = dict(sized(right), errors=[('macro', right), ('authored', "cannot convert value of type 'Int' to 'String'")])
    check('size refusal beside an unrelated error', 'size limit',
          'fail' if size_refusal_problem(beside, flow, 'phases', 601, 600) else 'pass',
          'pass' if not size_refusal_problem(sized(right), flow, 'phases', 601, 600) else 'fail')

    # (18) The DOT header names the graph by the grammar's quoted-identifier rule, not the label rule.
    entity = DOT.format('idle').replace('digraph "Plant"', 'digraph "R&amp;D"')
    check('DOT header decoded as a label (R&amp;D read as R&D)', 'DOT identifier',
          'fail' if named_dot_problems('R&D', entity) else 'pass',
          'pass' if not named_dot_problems('R&D', DOT.format('idle').replace('digraph "Plant"', 'digraph "R&D"'))
          and not named_dot_problems('say "hi"', DOT.format('idle').replace('digraph "Plant"', 'digraph "say \\"hi\\""'))
          else 'fail')
    check('DOT header with an escaped backslash read as one backslash', 'DOT identifier',
          'fail' if named_dot_problems('a\\b', DOT.format('idle').replace('digraph "Plant"', 'digraph "a\\\\b"')) else 'pass',
          'pass' if not named_dot_problems('a\\b', DOT.format('idle').replace('digraph "Plant"', 'digraph "a\\b"')) else 'fail')

    # (18a) The initial and terminal markers, read from the source.
    misplaced = self_test_graph()
    misplaced['initial'], misplaced['terminal'] = 'busy', ['idle']
    check('graph with the initial and terminal phases swapped', 'inventory',
          'fail' if synthetic(misplaced)['inventory_problems'] else 'pass',
          'pass' if not synthetic()['inventory_problems'] else f"fail: {synthetic()['inventory_problems'][:1]}")

    # (18b) Rewrite composition preserves authored lookup and declarations before the macro is checked.
    def mutation(name, source, site):
        return next((new for new, info in REWRITE_BY_NAME[name].function(source, random.Random(0))
                     if info['site'] == site), '')

    def compiled(source, name):
        return compile_case(toolchain, directory / name, source) if source else {}

    nested_plant = mutation('nest-schema', base_text, 'inside actor FuzzOuter')
    outside_alias = mutation('alias-file', nested_plant, 'alias:Detail')
    alias_target = 'typealias FuzzOutside = FuzzOuter.Plant.Logged.Detail'
    missing_outer = outside_alias.replace(alias_target, 'typealias FuzzOutside = Plant.Logged.Detail')
    check("file alias that loses the nested schema's enclosing type", 'rewrite composition',
          'fail' if compiled(missing_outer, 'alias-without-enclosing-type').get('status') != 'ok' else 'pass',
          'pass' if alias_target in outside_alias and compiled(outside_alias, 'alias-with-enclosing-type').get('status') == 'ok' else 'fail')

    generic_aliases = base_text.replace('    typealias Detail = Swift::String',
                                       '    typealias Identity<Item: ~Copyable> = Item\n'
                                       '    typealias Map<Value> = [Swift::String:Value]\n'
                                       '    typealias Closed<Item> = (Item: Swift::Int, value: Swift::Int)\n'
                                       '    typealias Detail = Identity<Swift::String>')
    escaping_alias = generic_aliases.replace('> = Item', '> = EscapingItem').replace(
        'import StateMachine\n', 'import StateMachine\ntypealias EscapingItem = Item\n')
    closed_alias = mutation('alias-file', generic_aliases, 'alias:(Item: Swift::Int, value: Swift::Int)')
    check('file alias refers to an out-of-scope parameter of a generic alias', 'rewrite composition',
          'fail' if compiled(escaping_alias, 'alias-free-parameter').get('status') != 'ok' else 'pass',
          'pass' if not mutation('alias-file', generic_aliases, 'alias:Item')
          and not mutation('alias-file', generic_aliases, 'alias:[Swift::String:Value]')
          and compiled(closed_alias, 'alias-closed-generic').get('status') == 'ok' else 'fail')

    extended = mutation('schema-named-value', base_text, 'static var Plant in an extension')
    generic_plant = mutation('nest-generic', extended, 'inside a generic type')
    broken_property = generic_plant.replace('static var Plant:', 'static var FuzzOuter.Plant:')
    generic_refusal = DIAG_EXPECT['nest-generic']
    generic_control = compiled(generic_plant, 'generic-unqualified-property')

    def generic_plant_verdict(source, outcome):
        candidate = self_case(source, rewrites=['schema-named-value', 'nest-generic'])
        return 'pass' if refusal_matches(generic_refusal, candidate, outcome,
                                         exact=True, consequent=DIAG_CONSEQUENCES) else 'fail'

    check("nesting qualifies a value declaration's name", 'rewrite composition',
          generic_plant_verdict(broken_property, compiled(broken_property, 'generic-qualified-property')),
          generic_plant_verdict(generic_plant, generic_control))

    generic_lines = generic_plant.split('\n')
    initial_line = next(i for i, line in enumerate(generic_lines, 1) if '@Initial case' in line)
    schema_line = next(i for i, line in enumerate(generic_lines, 1) if line.startswith('@StateMachine('))

    def misplaced_generic(column, line):
        message = 'Generic schemas, including schemas inside a generic enclosing type, are unsupported.'
        moved = dict(generic_control, located=[(p, m, name, line if m == message else n)
                                              for p, m, name, n in generic_control['located']],
                     columns=[((m, name, line if m == message else n), column if m == message else col)
                              for (m, name, n), col in generic_control['columns']])
        return generic_plant_verdict(generic_plant, moved)

    check('generic-enclosure refusal at a different attribute', 'enclosing type diagnostic',
          misplaced_generic(generic_lines[initial_line - 1].index('@Initial') + 1, initial_line),
          generic_plant_verdict(generic_plant, generic_control))
    check('generic-enclosure refusal inside the attribute name', 'enclosing type diagnostic',
          misplaced_generic(3, schema_line), generic_plant_verdict(generic_plant, generic_control))

    qualified = base_text.replace('func stop(_ source: Idle)', 'func stop(_ source: Plant.Idle)')
    shadowed = mutation('schema-named-type', qualified, 'struct Plant inside Plant')
    captured = shadowed.replace('func stop(_ source: Self.Idle)', 'func stop(_ source: Plant.Idle)')
    shadow_refusal = next(e['pattern'] for e in LIMITS if e['id'] == 'reserved-names')

    def shadow_verdict(source, name):
        return 'pass' if refusal_matches(shadow_refusal, self_case(source), compiled(source, name), exact=True) else 'fail'

    check('new schema-name shadow captures a phase type', 'rewrite composition',
          shadow_verdict(captured, 'shadow-captured-reference'),
          shadow_verdict(shadowed, 'shadow-preserved-reference'))

    bound = all_seeds()['doc-Lookup'].replace('import StateMachine', 'import StateMachine\n'
                                           'typealias FuzzEdgeScalar = Swift::String\n'
                                           'typealias FuzzUnrelated = Swift::Int\n'
                                           'typealias FuzzRequestScalar = Swift::String')
    bound = bound.replace('_ query: String', '_ query: FuzzEdgeScalar').replace(
        'typealias Input = String', 'typealias Input = FuzzRequestScalar')
    rebinds = {info['site']: new for new, info in REWRITE_BY_NAME['rebind-alias'].function(bound, random.Random(0))}
    blocked = {'FuzzEdgeScalar = Swift::Substring', 'FuzzRequestScalar = Swift::Substring'}
    mismatched = bound.replace('FuzzEdgeScalar = Swift::String', 'FuzzEdgeScalar = Swift::Substring').replace(
        'FuzzRequestScalar = Swift::String', 'FuzzRequestScalar = Swift::Substring')
    check('rebinding changes an edge or operation contract', 'rewrite composition',
          'fail' if compiled(mismatched, 'rebind-edge-and-operation').get('status') != 'ok' else 'pass',
          'pass' if blocked.isdisjoint(rebinds)
          and compiled(rebinds.get('FuzzUnrelated = Swift::Int64'), 'rebind-unrelated').get('status') == 'ok' else 'fail')

    event = all_seeds()['own-report-local'].replace('    @Event\n    enum Logged { typealias Payload = String }',
                                                    '    typealias LogText = Swift::String\n'
                                                    '    @Event()\n    enum Logged { typealias Payload = LogText }')
    event_rebinding = 'LogText = Swift::Substring'
    typed_event = event.replace('LogText = Swift::String', event_rebinding)
    literal_event = event.replace('source.log.joined(separator: ",")', '"done"').replace(
        '                switch command {', '                if case .logged(let line) = command { _ = line }\n'
        '                switch command {')
    check('rebinding an event payload breaks a typed producer', 'rewrite composition',
          'fail' if compiled(typed_event, 'rebind-typed-event').get('status') != 'ok' else 'pass',
          'pass' if not mutation('rebind-alias', event, event_rebinding)
          and compiled(mutation('rebind-alias', literal_event, event_rebinding), 'rebind-literal-event').get('status') == 'ok' else 'fail')

    # (18c) Separate-client failure-split limits require matching generated signature changes.
    pinned = all_seeds()['own-value-generic-failure'].replace(
        'import StateMachine\n', 'import StateMachine\ntypealias FuzzUnrelated = Swift::Int\n', 1)
    pinned += '\nfunc checkUnrelatedType() { let _: FuzzUnrelated = 0 }\n'
    SEED_TEXTS['selftest-client-split'] = pinned
    split_failure = mutation('alias-file', pinned, 'throws:Problem<10>')
    pinned_base = compiled(pinned, 'pinned-failure-base')
    split_outcome = compiled(split_failure, 'pinned-failure-split')
    split_candidate = self_case(split_failure, rewrites=['alias-file'], seed='selftest-client-split')
    split_verdict = judge(split_candidate, pinned_base, None, split_outcome)[0]
    changed_type = split_failure.replace('FuzzUnrelated = Swift::Int', 'FuzzUnrelated = Swift::String')
    extra_error = compiled(changed_type, 'pinned-failure-with-unrelated-error')
    extra_candidate = dict(split_candidate, text=changed_type)
    unsplit = dict(split_outcome, fingerprint=pinned_base.get('fingerprint', []))
    check('typed-throws client error beside an unrelated error', 'documented client limit',
          judge(extra_candidate, pinned_base, None, extra_error)[0],
          split_verdict if sum(place == 'client' for place, _ in extra_error['errors']) == 2 else 'fail')
    check('typed-throws client error without the documented signature split', 'documented client limit',
          judge(split_candidate, pinned_base, None, unsplit)[0], split_verdict)
    changed_parameter = dict(split_outcome, fingerprint=[
        line.replace('(Swift.Int) throws(', '(Swift.String) throws(')
        if '.Observed.read<' in line else line for line in split_outcome['fingerprint']])
    check("typed-throws signature split changes a method's parameter type", 'documented client limit',
          judge(split_candidate, pinned_base, None, changed_parameter)[0], split_verdict)
    old_owned = ('-Fz.Picker.Owned.choose< where A == Fz.Picker.Idle>(Swift.Bool) -> StateMachine.Advance<'
                 'Fz.Picker.Owned<Fz.Picker.Idle>, Fz.Picker.Owned<Fz.Picker.Chosen>, Swift.Never, Fz.Picker.Problem>')
    routed_owned = '+Fz.Picker.Owned.choose< where A == Fz.Picker.Idle>(Swift.Bool) -> Fz.Picker.Route.Idle.ChooseResult'
    check("owned signature split returns another phase's route result", 'documented client limit',
          'fail' if not failure_split_signatures([old_owned, routed_owned.replace('.Route.Idle.', '.Route.Chosen.')]) else 'pass',
          'pass' if failure_split_signatures([old_owned, routed_owned]) else 'fail')

    # (19) Deprecation fix-its: read from the compiler's notes, applied, and the fixed client compiled.
    noted = ("Client.swift:4:42: warning: 'old' is deprecated: replaced by 'Flow.next(_:_:)' [#DeprecatedDeclaration]\n"
             "    _ = owned.old(7)\n                                         ^\n"
             "Client.swift:4:42: note: use 'Flow.next(_:_:)' instead\n"
             "    _ = owned.old(7)\n              ^~~\n              Flow.next\n")
    renaming, edits = fixit_edits(noted)
    fixed_line = lambda log: apply_edits('\n\n\n    _ = owned.old(7)', fixit_edits(log)[1]).split('\n')[3]
    shifted = noted.replace('              ^~~\n', '             ^~~\n')
    check('fix-it applied one column off its range', 'deprecation fix-it',
          'fail' if fixed_line(shifted) != '    _ = owned.Flow.next(7)' else 'pass',
          'pass' if renaming == [(4, 42)] and fixed_line(noted) == '    _ = owned.Flow.next(7)' else f'fail: {renaming} {edits}')
    broken = "Fixed.swift:4:15: error: value of type 'Owned' has no member 'Flow'\n"
    check('fix-it that leaves the client uncompilable', 'deprecation fix-it',
          'fail' if fixit_judgement(renaming, edits, 1, broken) else 'pass',
          'pass' if not fixit_judgement(renaming, edits, 0, '') else 'fail')
    check('renamed member without a fix-it', 'deprecation fix-it',
          'fail' if fixit_judgement(renaming, [], 0, '') else 'pass',
          'pass' if not fixit_judgement([], [], 0, '') else 'fail')

    # (20) Exported text compared verbatim with the authored text on one line.
    decoy = self_test_graph()
    decoy['phases'][0]['payload'] = 'Idle\t/* decoy */\n'
    check('exported text with a tab, a comment, and a line break', 'exported text',
          'fail' if exported_text_problems(base_text, [decoy]) else 'pass',
          'pass' if not exported_text_problems(base_text, [self_test_graph()]) else 'fail')

    # (21) The absence module's compilation must finish normally.
    check('absence diagnostic from a compilation that then timed out', 'external uses',
          'fail' if client_use_judgement('', 0, absent_log, marked, absence_code='timeout') else 'pass',
          'pass' if not client_use_judgement('', 0, absent_log, marked, absence_code=1) else 'fail')

    # (22) Rewrites reach the shapes of the review's witnesses, and a rewrite that makes no case fails the run.
    def reaches(function, text, needle):
        return any(needle in (text_ + info.get('site', '')) for text_, info in function(text, random.Random(0)))
    never = lambda text, rng: []
    redirect = REWRITE_BY_NAME['redirect-entrance'].function
    scoped_start = all_seeds()['fx-GMT-scope-active']
    chain = chain_seed(2, 3)
    eligible_scope = scoped_start.replace('@Active(in: [Searching.self])', '@Active(in: [Searching.self, Idle.self])')
    required_scope = eligible_scope.replace('case query', 'case query\n        @Active(in: [Searching.self])\n        case session')
    required_scope = required_scope.replace('scope: Scope.query)', 'scope: Scope.query, requires: [Scope.session])')
    eligible_scope = eligible_scope.replace('\n}', '''
    @Transition(onSuccess: Lookup.self)
    fileprivate static func foundAtIdle(_ source: Idle, _ count: Lookup.Output) -> Idle { Idle() }
}''')
    empty_starts = chain.replace('onSuccess: Work.self)', 'onSuccess: Work.self, starts: [])')
    check('redirect moves an operation start out of its scope', 'rewrite coverage',
          'fail' if not redirect(scoped_start, None) and not redirect(scoped_start.replace('starts:', '`starts`:'), None)
          and not redirect(required_scope, None) else 'pass',
          'pass' if reaches(redirect, chain, 'step1 into C1 instead of C2') else 'fail')
    check('rewrite drops a redirect whose operation remains eligible', 'rewrite coverage',
          'fail' if not reaches(never, chain, 'go into C2 instead of C1') else 'pass',
          'pass' if reaches(redirect, chain, 'go into C2 instead of C1')
          and reaches(redirect, eligible_scope, 'begin into Idle instead of Searching')
          and reaches(redirect, empty_starts, 'step1 into C1 instead of C2') else 'fail')
    message = all_seeds()['own-deprecated-message-edge']
    permute = REWRITE_BY_NAME['permute-availability'].function
    check('availability options never reordered', 'rewrite coverage',
          'fail' if not reaches(never, message, '@available(*, message: "migration", deprecated)') else 'pass',
          'pass' if reaches(permute, message, '@available(*, message: "migration", deprecated)') else 'fail')
    special = all_seeds()['own-alias-leaf-specialized']
    leaf = REWRITE_BY_NAME['leaf-access'].function
    check('leaf access lowered only through a bare alias', 'rewrite coverage',
          'fail' if not reaches(never, special, 'Box<Swift::Int>.Hidden internal') else 'pass',
          'pass' if reaches(leaf, special, 'Box<Swift::Int>.Hidden internal') and reaches(leaf, special, 'N.Hidden internal') else 'fail')
    phase_set_seed = all_seeds()['own-phase-set']
    check('@PhaseSet rewrites fail to reach their target shapes', 'rewrite coverage',
          'fail' if not reaches(never, phase_set_seed, 'extract') else 'pass',
          'pass' if (reaches(REWRITE_BY_NAME['phase-set-extract'].function, phase_set_seed, 'extract [Editing.self, Review.self]')
                     and reaches(REWRITE_BY_NAME['phase-set-inline'].function, phase_set_seed, 'inline Editable removing decl')
                     and reaches(REWRITE_BY_NAME['phase-set-move'].function, phase_set_seed, 'move @PhaseSet Editable to bottom')
                     and reaches(REWRITE_BY_NAME['phase-set-spelling'].function, phase_set_seed, '@StateMachine::PhaseSet beside enum PhaseSet')
                     and reaches(REWRITE_BY_NAME['phase-set-decl-invalid'].function, phase_set_seed, 'empty @PhaseSet Editable')
                     and reaches(REWRITE_BY_NAME['phase-set-use-invalid'].function, phase_set_seed, 'from: bare phase Review.self'))
          else 'fail')
    backticked_route = ('@StateMachine(mode: .shared)\nenum R {\n'
                        '    @Route(on: Input.go)\n'
                        '    fileprivate static func choose(_ source: Idle) -> `Route`.Choose { .a }\n}\n')
    dup_route = REWRITE_BY_NAME['router-duplicate'].function(backticked_route, random.Random(0))
    broken_route = re.sub(r'\bRoute\.Choose\b', 'Route.ChooseAgain', backticked_route)
    check('router-duplicate leaves backticked Route.Choose unchanged', 'rewrite composition',
          'fail' if '`Route`.ChooseAgain' not in broken_route else 'pass',
          'pass' if dup_route and '`Route`.ChooseAgain' in dup_route[0][0] and 'func chooseAgain' in dup_route[0][0] else 'fail')
    # Planted regressions for composed-rewrite oracle and generator fixes.
    multiline_seed = all_seeds()['doc-Library']
    SEED_TEXTS['selftest-multiline-param'] = multiline_seed
    multiline_broken = REWRITE_BY_NAME['drop-request-label'].function(multiline_seed, random.Random(0))[0][0]
    ml_line = next(i for i, l in enumerate(multiline_broken.splitlines(), 1) if 'func downloaded(' in l)
    ml_src = multiline_broken.splitlines()[ml_line - 1]
    ml_msg = "This trigger requires source and trigger payload parameters, and optionally the operation's request, labeled request:."
    ml_case = self_case(multiline_broken, seed='selftest-multiline-param', rewrites=['drop-request-label'], kinds=['break'])
    ml_outcome = lambda col: dict(
        status='macro-diagnostic', errors=[('macro', ml_msg)],
        located=[('macro', ml_msg, 'Case.swift', ml_line)],
        columns=[((ml_msg, 'Case.swift', ml_line), col)])
    check('multiline parameter-clause refusal anchored outside parameter list', 'refusal token',
          judge(ml_case, base, None, ml_outcome(ml_src.index('fileprivate') + 1))[0],
          judge(ml_case, base, None, ml_outcome(ml_src.index('(') + 1))[0])
    del SEED_TEXTS['selftest-multiline-param']
    nested_editor = REWRITE_BY_NAME['nest-schema'].function(all_seeds()['doc-Editor'], random.Random(0))[0][0]
    check('schema-to-file rips a nested schema out of its enclosing type', 'rewrite composition',
          'fail' if not REWRITE_BY_NAME['schema-to-file'].function(nested_editor, random.Random(0)) else 'pass',
          'pass' if REWRITE_BY_NAME['schema-to-file'].function(all_seeds()['doc-Editor'], random.Random(0)) else 'fail')
    qualified_lookup = all_seeds()['doc-Lookup'].replace('case found(Found)', 'case found(Self.Found)')
    redir_muts = REWRITE_BY_NAME['redirect-entrance'].function(qualified_lookup, random.Random(0))
    check('redirect-entrance drops refusal when phase payload is Self-qualified', 'rewrite composition',
          'fail' if not any(info.get('refusal') is None for _, info in redir_muts) and redir_muts else 'pass',
          'pass' if redir_muts and all(info.get('refusal') for _, info in redir_muts) else 'fail')
    dep_muts = REWRITE_BY_NAME['verb-edge-name'].function(all_seeds()['own-deprecated-edge'], random.Random(0))
    finish_mut = next((t for t, info in dep_muts if info['site'] == 'Transition finish -> shutdown'), '')
    check('verb-edge-name leaves deprecation renamed: pointing at old edge name', 'rewrite composition',
          'fail' if 'renamed: "finish"' not in finish_mut and 'renamed: "shutdown"' in finish_mut else 'pass',
          'pass' if finish_mut and 'renamed: "shutdown"' in finish_mut else 'fail')
    with_underscored = all_seeds()['fx-GMT-routed-mixed-escaping'].replace(
        'nonisolated enum Bench {', 'nonisolated enum Bench {\n    struct _StateMachineEngine: Sendable {}', 1)
    check('renamable selects an underscored implementation-reserved member', 'rewrite composition',
          'fail' if all(n != '_StateMachineEngine' for _, n in renamable(with_underscored)) else 'pass',
          'pass' if any(n == 'Kept' for _, n in renamable(with_underscored)) else 'fail')
    sendable_renamed = rename(all_seeds()['own-public-sendable-helper'], 'Sendable', 'SendableK')
    check('rename corrupts Swift::Sendable or @Sendable when renaming a helper', 'rewrite composition',
          'fail' if 'Swift::SendableK' not in sendable_renamed and '@SendableK' not in sendable_renamed else 'pass',
          'pass' if 'enum SendableK {}' in sendable_renamed and 'Swift::Sendable' in sendable_renamed and '@Sendable' in sendable_renamed else 'fail')
    aliased_scoped = REWRITE_BY_NAME['alias-generic'].function(all_seeds()['own-scoped-invalidation'], random.Random(0))[0][0]
    nested_generic_scoped = REWRITE_BY_NAME['nest-generic'].function(aliased_scoped, random.Random(0))[0][0]
    check('nest-generic shadows alias-generic type parameter FuzzT', 'rewrite composition',
          'fail' if 'enum FuzzOuter<FuzzT>' not in nested_generic_scoped else 'pass',
          'pass' if 'enum FuzzOuter<FuzzOuterT>' in nested_generic_scoped and 'FuzzIdentity<FuzzT:' in nested_generic_scoped else 'fail')
    split_and_shared = [
        '-Fz.Gauge.Observed.read< where A == Fz.Gauge.Start>(Swift.Int) throws(Fz.Gauge.Problem<10>) -> Fz.Gauge.Prepared',
        '-Fz.Gauge.Owned.low< where A == Fz.Gauge.Start>(Swift.Int) -> StateMachine.Advance<Fz.Gauge.Owned<Fz.Gauge.Start>, Fz.Gauge.Owned<Fz.Gauge.Low>, Swift.Never, Fz.Gauge.Problem<10>>',
        '+Fz.Gauge.Observed.read< where A == Fz.Gauge.Start>(Swift.Int) throws(Fz.Gauge.PreparationRejection) -> Fz.Gauge.Prepared',
        '+Fz.Gauge.Owned.low< where A == Fz.Gauge.Start>(__shared Swift.Int) -> StateMachine.Advance<Fz.Gauge.Owned<Fz.Gauge.Start>, Fz.Gauge.Owned<Fz.Gauge.Low>, Swift.Never, Fz.Gauge.Problem<10>>',
    ]
    bad_shared = split_and_shared[:3] + [split_and_shared[3].replace('__shared Swift.Int', '__shared Swift.String')]
    observed_shared = [
        '-Fz.Gauge.Observed.low< where A == Fz.Gauge.Start>(Swift.Int) -> Fz.Gauge.Prepared',
        '+Fz.Gauge.Observed.low< where A == Fz.Gauge.Start>(__shared Swift.Int) -> Fz.Gauge.Prepared',
    ]
    moved_shared = [
        '-Fz.Gauge.Owned.low< where A == Fz.Gauge.Start>(__shared Swift.Int, Swift.Bool) -> Fz.Gauge.Owned<Fz.Gauge.Low>',
        '+Fz.Gauge.Owned.low< where A == Fz.Gauge.Start>(Swift.Int, __shared Swift.Bool) -> Fz.Gauge.Owned<Fz.Gauge.Low>',
    ]
    check('combined failure-split and shared-param hides a changed parameter type', 'documented client limit',
          'fail' if not failure_split_signatures(strip_repeated_ownership(bad_shared, ['alias-file', 'shared-param'])) else 'pass',
          'pass' if failure_split_signatures(strip_repeated_ownership(split_and_shared, ['alias-file', 'shared-param']))
          and not failure_split_signatures(strip_repeated_ownership(split_and_shared, ['alias-file']))
          and strip_repeated_ownership(observed_shared, ['shared-param']) == observed_shared
          and strip_repeated_ownership(moved_shared, ['shared-param']) == moved_shared else 'fail')
    same_method_split = [
        '-Fz.Picker.Owned.choose< where A == Fz.Picker.Idle>(Swift.Bool) -> StateMachine.Advance<Fz.Picker.Owned<Fz.Picker.Idle>, Fz.Picker.Owned<Fz.Picker.Chosen>, Swift.Never, Fz.Picker.Problem>',
        '+Fz.Picker.Owned.choose< where A == Fz.Picker.Idle>(__shared Swift.Bool) -> Fz.Picker.Route.Idle.ChooseResult',
    ]
    bad_same_method = [same_method_split[0], same_method_split[1].replace('__shared Swift.Bool', '__shared Swift.Int')]
    check('same-method Owned failure split with shared-param hides a parameter type change', 'documented client limit',
          'fail' if not failure_split_signatures(bad_same_method, allow_shared_owned=True) else 'pass',
          'pass' if failure_split_signatures(same_method_split, allow_shared_owned=True)
          and not failure_split_signatures(same_method_split, allow_shared_owned=False) else 'fail')
    nested_authored = 'static Fz.Left.Flow.go(__shared Fz.Left.Flow.Idle) -> Fz.Left.Flow.Done'
    old_authored_filter = lambda line: re.match(r'static Fz\.(?:FuzzOuter\.)?\w+\.go\(', line) is not None
    generated_statics = [
        'static Fz.Left.Flow.Local.go(Fz.Left.Flow.Snapshot) -> Swift.String',
        'static Fz.Left.Flow.Observed.go() -> Swift.String',
        'static Fz.Left.Flow.Route.go() -> Swift.String',
    ]
    check('nested enclosing-type authored static function kept in generated fingerprint', 'fingerprint filter',
          'fail' if not old_authored_filter(nested_authored) else 'pass',
          'pass' if is_authored_static(nested_authored, ['go'], ['Left.Flow', 'Right.Flow'])
          and not any(is_authored_static(s, ['go'], ['Left.Flow', 'Right.Flow']) for s in generated_statics) else 'fail')
    shadowed_hold = REWRITE_BY_NAME['schema-named-value'].function(all_seeds()['own-testing-duplicate'], random.Random(0))[0][0]
    default_shadowed = [info['site'] for _, info in REWRITE_BY_NAME['initial-default-spelling'].function(shadowed_hold, random.Random(0))]
    default_plain = [info['site'] for _, info in REWRITE_BY_NAME['initial-default-spelling'].function(all_seeds()['own-testing-duplicate'], random.Random(0))]
    check('initial-default-spelling emits shadowed Schema.Payload() in expression position', 'rewrite composition',
          'fail' if 'default Hold.Idle()' not in default_shadowed else 'pass',
          'pass' if 'default Self.Idle()' in default_shadowed and 'default Hold.Idle()' in default_plain else 'fail')
    # (23) Planted oracle regressions for typed `routed:` payloads and generic `<Source>` multi-source transitions.
    generic_authored = 'static Fz.NavFlow.select<A where A: Fz.NavFlow.SelectionCarrying>(A, Swift.Optional<Swift.Int>) -> StateMachine.Change<A, Fz.NavFlow.Effect.Select>'
    old_non_generic_filter = lambda line: re.match(r'static Fz\.NavFlow\.select\(', line) is not None
    check('generic authored static function leaked into generated fingerprint', 'fingerprint filter',
          'fail' if not old_non_generic_filter(generic_authored) else 'pass',
          'pass' if is_authored_static(generic_authored, ['select'], ['NavFlow']) else 'fail')
    generic_seed = all_seeds()['own-generic-source']
    generic_body = schema_body(generic_seed, 'NavFlow')
    generic_direct = direct_member_text(generic_body)
    generic_payloads = {name: payload for name, _, payload in direct_case_items(generic_body, generic_direct) if payload is not None}
    old_edge_pos = {m.group(1) for m in re.finditer(r'\bfunc\s+(\w+)\s*\(', generic_direct)}
    new_edge_pos = edge_positions(generic_direct, generic_payloads)
    check('edge_positions misses generic <Source> multi-source transitions', 'declaration order',
          'fail' if 'select' not in old_edge_pos else 'pass',
          'pass' if all(f'{p}.select' in new_edge_pos for p in ('browsing', 'confirming', 'presenting', 'sheetConfirming'))
          and new_edge_pos['browsing.select'] < new_edge_pos['confirming.select'] < new_edge_pos['presenting.select'] < new_edge_pos['sheetConfirming.select'] else 'fail')
    routed_seed = all_seeds()['own-routed-handoff']
    routed_sites = type_sites(routed_seed)
    generic_sites = type_sites(generic_seed)
    old_tuple_split = [m.group(0) for m in re.finditer(r'(?:^|,)\s*(?:`?\w+`?\s+)?`?\w+`?\s*:\s*', '_ source: Comparing, _ delta: Swift::Int, routed pair: (label: Swift::String, score: Swift::Int)')]
    check('type_sites splits tuple routed: payload or exposes generic Source as a concrete type site', 'source scanner',
          'fail' if len(old_tuple_split) != 3 else 'pass',
          'pass' if any('(label: Swift::String, score: Swift::Int)' in s.text for s in routed_sites)
          and not any(s.text.strip() == 'Source' for s in generic_sites)
          and any(s.text.strip() == 'Presenting' and s.kind == 'return' for s in generic_sites) else 'fail')
    old_generic_fn_muts = [f'generic {f["name"]}' for f in authored_functions_at(generic_seed)]
    generic_fn_muts = [info['site'] for _, info in REWRITE_BY_NAME['generic-function'].function(generic_seed, random.Random(0))]
    check('generic-function targets generic from: transitions instead of single-source transitions/routers', 'rewrite coverage',
          'fail' if any('generic select' in s for s in old_generic_fn_muts) else 'pass',
          'pass' if any('generic keepBrowsing' in s for s in generic_fn_muts) and not any('generic select' in s for s in generic_fn_muts) else 'fail')
    routed_nc_seed = all_seeds()['own-routed-noncopyable']
    generic_owned_seed = all_seeds()['own-generic-source-owned']
    check('routed: and generic <Source> rewrites fail to reach their target shapes', 'rewrite coverage',
          'fail' if not reaches(never, routed_seed, 'routed') else 'pass',
          'pass' if (reaches(REWRITE_BY_NAME['routed-spelling'].function, routed_seed, 'Self.Step routed on advance')
                     and reaches(REWRITE_BY_NAME['routed-convention'].function, routed_seed, 'borrowing routed')
                     and reaches(REWRITE_BY_NAME['routed-invalid'].function, routed_seed, 'routed: before request on followUp')
                     and reaches(REWRITE_BY_NAME['routed-invalid'].function, routed_seed, 'public @Route routeChoice exposes fileprivate Step')
                     and reaches(REWRITE_BY_NAME['routed-invalid'].function, generic_seed, 'partially routed from:')
                     and reaches(REWRITE_BY_NAME['routed-invalid'].function, generic_owned_seed, 'routed: in .ownedOnly')
                     and reaches(REWRITE_BY_NAME['generic-source-where'].function, generic_seed, 'move Source: NavSelectionCarrying to where')
                     and reaches(REWRITE_BY_NAME['generic-source-where'].function, generic_seed, 'inline where Source: NavSelectionCarrying')
                     and reaches(REWRITE_BY_NAME['generic-source-invalid'].function, generic_seed, 'two generics <Source,')
                     and reaches(REWRITE_BY_NAME['generic-source-invalid'].function, generic_seed, 'pack <each Source>')
                     and reaches(REWRITE_BY_NAME['generic-source-invalid'].function, generic_seed, 'routed: references Source')
                     and reaches(REWRITE_BY_NAME['generic-source-invalid'].function, generic_seed, 'same-phase starts [FuzzLimitedOp.self]')
                     and reaches(REWRITE_BY_NAME['generic-source-invalid'].function, generic_owned_seed, 'Advance<'))
          else 'fail')
    SEED_TEXTS['selftest-routed-anchor'] = routed_seed
    routed_dup_text, routed_dup_info = next((t, i) for t, i in REWRITE_BY_NAME['routed-invalid'].function(routed_seed, random.Random(0)) if 'duplicate routed:' in i['site'])
    rd_line = next(i for i, l in enumerate(routed_dup_text.splitlines(), 1) if 'routed fuzzSecond' in l)
    rd_src = routed_dup_text.splitlines()[rd_line - 1]
    rd_msg = 'Take the routed payload once, in the last parameter, labeled routed:.'
    rd_case = self_case(routed_dup_text, seed='selftest-routed-anchor', rewrites=['routed-invalid'], kinds=['break'],
                        refusal=routed_dup_info['refusal'], token=routed_dup_info['token'])
    rd_outcome = lambda col: dict(
        status='macro-diagnostic', errors=[('macro', rd_msg)],
        located=[('macro', rd_msg, 'Case.swift', rd_line)],
        columns=[((rd_msg, 'Case.swift', rd_line), col)])
    check('routed: refusal anchored off the routed token', 'refusal token',
          judge(rd_case, base, None, rd_outcome(rd_src.index('fileprivate') + 1 if 'fileprivate' in rd_src else 1))[0],
          judge(rd_case, base, None, rd_outcome(rd_src.index('routed fuzzSecond') + 1))[0])
    del SEED_TEXTS['selftest-routed-anchor']
    # (24) Planted composition regressions for `alias-nested` after `self-qualify` and `schema-qualify` in shadowed `Input`.
    desk_self_saved = all_seeds()['own-report-local'].replace('_ saved: Saved', '_ saved: Self.Saved')
    desk_nested_bad = insert_in_schema(desk_self_saved.replace('_ saved: Self.Saved', '_ saved: FuzzSpace.Alias'),
                                       'enum FuzzSpace { typealias Alias = Self.Saved }')
    desk_nested_fixed = mutation('alias-nested', desk_self_saved, 'param:Self.Saved')
    check('alias-nested leaves schema Self. unqualified inside enum FuzzSpace', 'rewrite composition',
          'fail' if compiled(desk_nested_bad, 'alias-nested-self-bad').get('status') != 'ok' else 'pass',
          'pass' if desk_nested_fixed and 'typealias Alias = Desk.Saved' in desk_nested_fixed
          and compiled(desk_nested_fixed, 'alias-nested-self-ok').get('status') == 'ok' else 'fail')
    tray_seed = all_seeds()['own-input-shadow']
    tray_bad = tray_seed.replace('case put(Box)', 'case put(Tray.Box)')
    tray_fixed = mutation('schema-qualify', tray_seed, 'case:Box')
    check('schema-qualify points shadowed Input.Box to outer schema Tray.Box', 'rewrite composition',
          'fail' if compiled(tray_bad, 'schema-qualify-shadow-bad').get('status') != 'ok' else 'pass',
          'pass' if tray_fixed and 'case put(Tray.Input.Box)' in tray_fixed and 'case put(Tray.Box)' not in tray_fixed
          and compiled(tray_fixed, 'schema-qualify-shadow-ok').get('status') == 'ok' else 'fail')
    rejecting_seed = schema_only(all_seeds()['own-rejecting-routers'])
    SEED_TEXTS['selftest-conditional-never'] = rejecting_seed
    cond_never_fixed = mutation('conditional-attribute', rejecting_seed, '#if attribute on deny')
    cond_never_bad = cond_never_fixed.replace('@inline(__always)', '@discardableResult') if cond_never_fixed else ''
    cond_verdict = lambda src, tag: judge(
        self_case(src, seed='selftest-conditional-never', rewrites=['conditional-attribute'], kinds=['safe'], expect='conditional-attributes'),
        base, None, compiled(src, tag))[0]
    check('conditional-attribute places @discardableResult on a Never-returning rejecting router', 'rewrite composition',
          cond_verdict(cond_never_bad, 'cond-attr-never-bad'),
          cond_verdict(cond_never_fixed, 'cond-attr-never-ok'))
    del SEED_TEXTS['selftest-conditional-never']
    gauge_seed = schema_only(all_seeds()['doc-Gauge'])
    SEED_TEXTS['selftest-terminal-op'] = gauge_seed
    gauge_term_text, gauge_term_info = next(
        (t, i) for t, i in REWRITE_BY_NAME['terminal-flip'].function(gauge_seed, random.Random(0))
        if i['site'] == 'add @Terminal to initial')
    gauge_term_case = self_case(gauge_term_text, seed='selftest-terminal-op', rewrites=['terminal-flip'], kinds=['break'],
                                refusal=gauge_term_info['refusal'])
    gauge_op_line = next(i for i, l in enumerate(gauge_term_text.splitlines(), 1) if '@Operation(activeIn: [Ready.self])' in l)
    gauge_op_msg = "Operation 'Measure' cannot be active in terminal phase 'ready'; remove Ready.self from the phases where it is active, or remove '@Terminal'."
    gauge_op_off = dict(status='macro-diagnostic', errors=[('macro', gauge_op_msg)],
                        located=[('macro', gauge_op_msg, 'Case.swift', gauge_op_line + 1)],
                        columns=[((gauge_op_msg, 'Case.swift', gauge_op_line + 1), 5)])
    check('terminal-flip active-operation refusal anchored off Ready.self', 'refusal token',
          judge(gauge_term_case, base, None, gauge_op_off)[0],
          judge(gauge_term_case, base, None, compiled(gauge_term_text, 'terminal-op-ok'))[0])
    del SEED_TEXTS['selftest-terminal-op']
    owned_ps_seed = all_seeds()['own-phase-set-owned']
    SEED_TEXTS['selftest-outside-never-owned'] = owned_ps_seed
    owned_never = mutation('throws-never', owned_ps_seed, 'throws(Never) on Transition close')
    owned_outside = mutation('alias-file', owned_never, 'throws:Never') if owned_never else ''
    owned_outside_case = self_case(owned_outside, seed='selftest-outside-never-owned',
                                   rewrites=['throws-never', 'alias-file'], kinds=['eq', 'eq'])
    owned_close_line = next(i for i, l in enumerate(owned_outside.splitlines(), 1) if 'throws(FuzzOutside)' in l)
    owned_close_msg = 'Owned-only transitions cannot throw; return Advance<Source, Destination, Effect, Failure> to give the source back.'
    owned_close_off = dict(status='macro-diagnostic', errors=[('macro', owned_close_msg)],
                           located=[('macro', owned_close_msg, 'Case.swift', owned_close_line)],
                           columns=[((owned_close_msg, 'Case.swift', owned_close_line), 5)])
    owned_outside_compiled = compiled(owned_outside, 'outside-never-owned-ok')
    check('outside-never-owned anchored off throws token', 'documented limits',
          judge(owned_outside_case, base, None, owned_close_off)[0],
          'pass' if judge(owned_outside_case, base, None, owned_outside_compiled)[0] == 'limit:outside-never-owned' else 'fail')
    owned_gen_seed = all_seeds()['own-generic-source-owned']
    SEED_TEXTS['selftest-outside-never-unrelated'] = owned_gen_seed
    owned_gen_never = mutation('throws-never', owned_gen_seed, 'throws(Never) on Transition close')
    owned_unrelated_alias = mutation('alias-file', owned_gen_never, 'param:Swift::String') if owned_gen_never else ''
    owned_unrelated_line = next(i for i, l in enumerate(owned_unrelated_alias.splitlines(), 1) if 'throws(Never)' in l)
    owned_unrelated_col = owned_unrelated_alias.splitlines()[owned_unrelated_line - 1].index('throws(Never)') + 1
    owned_unrelated_case = self_case(owned_unrelated_alias, seed='selftest-outside-never-unrelated',
                                     rewrites=['throws-never', 'alias-file'], kinds=['eq', 'eq'])
    owned_unrelated_mistaken = dict(status='macro-diagnostic', errors=[('macro', owned_close_msg)],
                                    located=[('macro', owned_close_msg, 'Case.swift', owned_unrelated_line)],
                                    columns=[((owned_close_msg, 'Case.swift', owned_unrelated_line), owned_unrelated_col)])
    check('outside-never-owned excuses literal throws(Never) beside an unrelated alias-file', 'documented limits',
          judge(owned_unrelated_case, base, None, owned_unrelated_mistaken)[0],
          'pass' if judge(owned_outside_case, base, None, owned_outside_compiled)[0] == 'limit:outside-never-owned' else 'fail')
    del SEED_TEXTS['selftest-outside-never-owned']
    del SEED_TEXTS['selftest-outside-never-unrelated']
    feed_generic = mutation('alias-generic', all_seeds()['doc-Feed'], 'alias:[String]')
    feed_chain_bad = insert_in_schema(feed_generic.replace('typealias FuzzIdentity<FuzzT: ~Copyable> = FuzzT',
                                                           'typealias FuzzIdentity<FuzzT: ~Copyable> = FuzzChain0'),
                                      'typealias FuzzChain0 = FuzzChain1\n    typealias FuzzChain1 = FuzzChain2\n    typealias FuzzChain2 = FuzzT')
    feed_chain_variants = REWRITE_BY_NAME['alias-chain'].function(feed_generic, random.Random(0))
    feed_chain_clean = next((t for t, i in feed_chain_variants if i['site'] == 'alias:String'), None)
    check('alias-chain hoists generic parameter FuzzT out of FuzzIdentity', 'rewrite composition',
          'fail' if compiled(feed_chain_bad, 'alias-chain-generic-bad').get('status') != 'ok' else 'pass',
          'pass' if not any('= FuzzT' in t and 'FuzzChain2 = FuzzT' in t for t, _ in feed_chain_variants)
          and feed_chain_clean and compiled(feed_chain_clean, 'alias-chain-generic-ok').get('status') == 'ok' else 'fail')
    OPERATORS.clear()
    OPERATORS['paren']['applicable'] = 3
    silent = operator_problems([REWRITE_BY_NAME['paren']])
    OPERATORS['paren']['generated'] = 1
    check('a rewrite that made no case in a smoke run', 'rewrite coverage', 'fail' if silent else 'pass',
          'pass' if not operator_problems([REWRITE_BY_NAME['paren']]) else 'fail')
    OPERATORS.clear()
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
        # A client section compiles only once the schema module has, so one written to call what the rewrite changes
        # stays: an accepted invalid schema is then also judged by what its caller sees.
        if info.get('keep_client') and CLIENT_MARKER in text:
            module, client = text.split(CLIENT_MARKER, 1)
            text = schema_only(module) + '\n' + CLIENT_MARKER + client
        else:
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
                refusal=info.get('refusal'), token=info.get('token'))



SEED_TEXTS = {}


def seeds_text_of(name):
    return SEED_TEXTS[name]


def site_signature(rewrite, info):
    """What makes one site of a rewrite different from another for the macro: the kind and role of a type site and
    the shape of its spelling with names abstracted, or a non-type rewrite's flavor."""
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
    'own-parallel-32': r'^(integer-spelling|label-backtick|callee-backtick|numeric-valid|numeric-invalid)$',
    'own-parallel-33': r'^(integer-spelling|label-backtick)$',

    'own-keyed-scoped-restoration': r'^(shadow-alias|restoration-invalid|scope-ineligible|operation-drop|cancel-unkeyed|integer-spelling)$',
    'own-report-local': r'^(reorder-members|reorder-cases|verb-edge-name|collide-case|reserved-phase|operation-drop)$',
    'own-available-schema': r'^(edge-availability|declaration-attributes)$',
    'own-isolated-default': r'^(owner-selection|owner-invalid)$',
    'own-single-managed': r'^(owner-selection|owner-invalid)$',
    'own-managed-only': r'^(owner-selection|owner-invalid|reorder-members)$',
    'doc-Approval': r'^reserved-phase$',
    'own-public-sendable-helper': r'^(shadow-standard|schema-access|label-backtick|closure-convention)$',
    'own-alias-leaf': r'^(leaf-access|alias-base|schema-named-value)$',
    'own-alias-leaf-specialized': r'^leaf-access$',
    'own-deprecated-edge': r'^(permute-availability|qualify-renamed)$',
    'own-deprecated-message-edge': r'^(permute-availability|qualify-renamed)$',
    'own-phase-set': r'^(phase-set-extract|phase-set-inline|phase-set-move|phase-set-spelling|phase-set-decl-invalid|phase-set-use-invalid|reorder-lists|reorder-members|module-attribute|attribute-trivia|terminal-flip)$',
    'own-phase-set-owned': r'^(phase-set-extract|phase-set-inline|phase-set-move|phase-set-spelling|phase-set-decl-invalid|phase-set-use-invalid|reorder-lists|reorder-members)$',
    'own-routed-handoff': r'^(routed-spelling|routed-convention|routed-invalid|reorder-members|router-delete|router-duplicate|generic-function|paren|backtick-declaration|nest-schema|schema-to-file)$',
    'own-routed-noncopyable': r'^(routed-spelling|routed-convention|routed-invalid|reorder-members|router-delete|router-duplicate|paren)$',
    'own-generic-source': r'^(generic-source-where|generic-source-invalid|routed-spelling|routed-invalid|phase-set-extract|phase-set-inline|phase-set-move|reorder-members|reorder-lists|generic-function|permute-availability|nest-schema)$',
    'own-generic-source-owned': r'^(generic-source-where|generic-source-invalid|routed-invalid|phase-set-extract|phase-set-inline|phase-set-move|reorder-members|reorder-lists|paren)$',
    'doc-Document': r'^(phase-set-inline|phase-set-move|phase-set-spelling|phase-set-decl-invalid|phase-set-use-invalid|reorder-lists)$',
    'doc-Editor': r'^phase-set-extract$',
}


# Rewrites that `--smoke` runs only on the seeds written for them, to keep it near its time budget; `--full` and
# `--random` run them on every seed.
SMOKE_SEEDS = {
    'label-backtick': r'^own-(parallel-32|keyed-scoped-restoration|scoped-invalidation|access-pair)$',
    'callee-backtick': r'^own-(parallel-32|keyed-scoped-restoration|scoped-invalidation|access-pair)$',
    'split-payload': r'^(own-report-local|own-alias-leaf|own-same-basename|own-deprecated-edge|doc-Approval)$',
    'schema-named-value': r'^(own-event-isolated|own-alias-leaf|own-report-local|doc-Approval)$',
    'schema-named-type': r'^(own-event-isolated|own-alias-leaf)$',
    'rebind-alias': r'^(own-event-shadow|own-input-shadow|own-cross-file-input|fx-GMT-alias-router-failure)$',
    'schema-to-file': r'^(own-alias-leaf|own-report-local|own-same-basename|doc-Approval|own-routed-handoff)$',
    'comment-decoy': r'^(own-report-local|doc-Approval)$',
    'nfc-body': r'^(own-report-local|own-rejecting-routers)$',
    'nfc-read': r'^(own-report-local|own-rejecting-routers)$',
    'parameter-restriction': r'^(own-report-local|own-keyed-scoped-restoration|doc-Approval)$',
    'duplicate-marker': r'^(own-report-local|own-keyed-scoped-restoration|doc-Approval)$',
    'routed-invalid': r'^own-(routed-handoff|routed-noncopyable|generic-source|generic-source-owned)$',
    'generic-source-invalid': r'^own-(generic-source|generic-source-owned)$',
}


# Seeds that `--smoke` runs only with the rewrites written for them, to keep it near its time budget.
SMOKE_ONLY = {
    'own-deprecated-message-edge': r'^(permute-availability|qualify-renamed|edge-availability|declaration-attributes|paren)$',
    'own-alias-leaf-specialized': r'^(leaf-access|alias-base|paren|schema-to-file)$',
    'own-testing-duplicate': r'^(paren|reorder-members|reorder-cases)$',
    'own-failure-router': r'^(paren|reorder-members|router-duplicate)$',
    'own-parallel-32-isolated': r'^(integer-spelling|paren)$',
    'own-parallel-33-isolated': r'^(integer-spelling|paren)$',
    'own-phase-set-owned': r'^(phase-set-extract|phase-set-inline|phase-set-move|phase-set-spelling|phase-set-decl-invalid|phase-set-use-invalid|reorder-lists|reorder-members|module-attribute|attribute-trivia|paren|backtick-declaration|nest-schema)$',
    'own-routed-noncopyable': r'^(routed-spelling|routed-convention|routed-invalid|reorder-members|router-delete|router-duplicate|paren|backtick-declaration|nest-schema)$',
    'own-generic-source-owned': r'^(generic-source-where|generic-source-invalid|routed-invalid|phase-set-extract|phase-set-inline|phase-set-move|reorder-members|reorder-lists|paren|backtick-declaration|nest-schema)$',
}

# What each rewrite did in the last `smoke_cases`: sites it found, cases it made, and any error it raised.
OPERATORS = collections.defaultdict(lambda: dict(applicable=0, generated=0, errors=[]))


def smoke_cases(seeds, rewrites, per_rewrite, full=False):
    """Every seed with every rewrite, at sites spread over each rewrite's candidates. Unless `full`, a site whose
    signature two earlier seeds already covered is left out, except where SMOKE_EVERY_SITE keeps every site of a
    seed's rewrite; seeds written for this fuzzer come first. OPERATORS records each rewrite's sites and cases."""
    cases = []
    covered = collections.Counter()
    OPERATORS.clear()
    order = sorted(seeds, key=lambda name: (not name.startswith('own-'), not name.startswith('fx-'), name))
    for seed_name in order:
        text = seeds[seed_name]
        for rw in rewrites:
            if not full and rw.name in SMOKE_SEEDS and not re.search(SMOKE_SEEDS[rw.name], seed_name):
                continue
            if not full and seed_name in SMOKE_ONLY and not re.search(SMOKE_ONLY[seed_name], rw.name):
                continue
            # A renaming of a public seed's payload would also need the renamed declaration's access, which the
            # distinction rewrites do not give it; the access-pair seed covers renaming under public access.
            if rw.kind == 'dist' and seed_name in ('own-public-sendable-helper', 'own-alias-leaf'):
                continue
            try:
                mutations = rw.function(text, random.Random(f'{seed_name}/{rw.name}'))
            except Exception as error:  # A rewrite that cannot read a seed is a fuzzer defect: the run fails.
                print(f'rewrite {rw.name} failed on {seed_name}: {error!r}', file=sys.stderr)
                OPERATORS[rw.name]['errors'].append(f'{seed_name}: {error!r}')
                continue
            OPERATORS[rw.name]['applicable'] += len(mutations)
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
                    OPERATORS[rw.name]['generated'] += 1
    return cases


def operator_problems(rewrites):
    """Rewrites a smoke run selected that raised an error or made no case: their checks gave no evidence."""
    problems = []
    for rw in rewrites:
        record = OPERATORS[rw.name]
        if record['errors']:
            problems.append(f"operator {rw.name}: raised {record['errors'][0]}")
        elif not record['generated']:
            problems.append(f"operator {rw.name}: made no case ({record['applicable']} sites)")
    return problems


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
        for key in ('breaking', 'signature', 'refusal', 'token', 'keep_client'):
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
    mode.add_argument('--smoke', action='store_true', help='run every rewrite alone at sites of every shape the seeds hold (deterministic)')
    mode.add_argument('--random', action='store_true', help='random compositions of two to four rewrites')
    mode.add_argument('--cost', action='store_true', help='compare scaled schemas using rewritten spellings against the base spelling')
    mode.add_argument('--scaling', action='store_true', help='every list-like construct at sizes n and 4n')
    mode.add_argument('--ceilings', action='store_true', help="search each construct's largest size that compiles")
    mode.add_argument('--self-test', action='store_true', help='plant a defect for each oracle and check that it is reported')
    parser.add_argument('--growth-bound', type=float, default=5.0, help='allowed growth of macro time for 4x the size')
    parser.add_argument('--repeats', type=int, default=3, help='runs per measurement (keeps the median)')
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
    parser.add_argument('--no-run', action='store_true', help='compile only without linking or running cases')
    parser.add_argument('--no-reduce', action='store_true')
    parser.add_argument('--list', action='store_true', help='list seeds and rewrites and exit')
    parser.add_argument('--spelling-scope', choices=('written', 'schema'), default='written',
                        help="where an exported spelling is read, either where the guide specifies (default) or at the "
                             "schema's scope to check a macro older than that contract")
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
        parser.error(f'{output} is not empty. Give a fresh --output')
    output.mkdir(parents=True, exist_ok=True)

    testing_link = []
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
        # The testing product, which a seed's report may drive, links into the cases that import it.
        testing_link = [str(p) for p in sorted((bin_path / 'StateMachineTesting.build').glob('*.o'))]
        if not plugin.exists() or not (modules / 'StateMachine.swiftmodule').exists():
            parser.error(f'no native build of the macro plugin at {bin_path}. Build the package first')
    # Keep the plugin this run uses, so concurrent rebuilds cannot change it mid-run.
    kept = output / 'plugin'
    shutil.copy2(plugin, kept)
    global MEMORY_CAP_MB
    MEMORY_CAP_MB = args.memory_cap_mb
    toolchain = Toolchain(kept, modules, link, args.jobs, args.timeout, not args.no_run)
    toolchain.testing_link = testing_link
    toolchain.spelling_scope = args.spelling_scope
    if args.cost or args.scaling or args.ceilings:
        # Large schemas compile one at a time, so a compilation near the memory cap is the only one running.
        args.jobs = 1

    # An allowance stands only on the sentence of the guide that documents it.
    unquoted = missing_quotations(LIMITS, DOC.read_text())
    for entry in unquoted:
        print(f"error: limit {entry['id']} quotes text DeclaringAGraph.md no longer contains: {entry['doc']!r}", file=sys.stderr)
    (output / 'limits.json').write_text(json.dumps(LIMITS, indent=2, ensure_ascii=False) + '\n')
    if unquoted and not args.self_test:
        return 2

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
    def compile_seed(name, text):
        outcome = compile_case(toolchain, output / 'seeds' / name, text)
        if outcome['status'] == 'ok' and toolchain.run:
            outcome['client_use_problems'] = client_use_problems(toolchain, output / 'seeds' / name, text)
        return outcome
    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        futures = {name: pool.submit(compile_seed, name, text) for name, text in seeds.items()}
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
    # Every selected rewrite must make a case in a smoke run over every seed; a filtered run reports its own.
    unexercised = operator_problems(rewrites) if args.smoke and not blocked and args.only_seeds in ('', '.*') else []
    for problem in unexercised:
        print(f'FAIL coverage: {problem}', flush=True)
    if args.smoke:
        (output / 'operators.json').write_text(json.dumps(OPERATORS, indent=2, sort_keys=True) + '\n')
    declarations = {name: declaration_signature(text) for name, text in seeds.items()}

    def probe_for(case):
        # Spellings are probed for a renaming, and for any case whose exported spellings or declarations differ from
        # its seed's: a moved or added declaration can change what an unchanged spelling names.
        if 'dist' in case['kinds'] or case['flags']:
            # The seed's spellings were probed without the case's flags.
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
        replaced = False
        if verdict == 'artefact' and CLIENT_MARKER in case['text'] and case['control'] is None:
            # A rewrite that broke the seed's client code leaves the case unusable; the same schema without the
            # client is its valid control, judged in its place.
            stripped = dict(case, text=case['text'].split(CLIENT_MARKER, 1)[0])
            variant = compile_case(toolchain, directory / 'without-client', stripped['text'], probe_for(stripped), case['flags'])
            verdict, expected, observed = judge(stripped, bases[case['seed']], None, variant)
            replaced = True
        result = dict(id=case['id'], seed=case['seed'], rewrites=case['rewrites'], kinds=case['kinds'], steps=case['steps'],
                      verdict=verdict, expected=expected, observed=observed, seconds=variant['seconds'], replaced=replaced,
                      status=variant['status'])
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
    # A fuzzer artefact is an unusable case: it is counted apart, never as a pass.
    passed = counts.get('pass', 0) + counts.get('limit', 0)
    replaced = sum(1 for _, r in results if r.get('replaced'))
    print(f"{passed}/{len(results)} fuzz cases passed ({counts.get('limit', 0)} at documented limits), "
          f"{counts.get('artefact', 0)} unusable (fuzzer artefacts; {replaced} replaced by their valid controls), "
          f"{counts.get('fail', 0)} failed, {counts.get('policy', 0)} policy, "
          f"{len(blocked)} seeds blocked, in {summary['seconds']}s; evidence: {output}")
    if unexercised:
        print(f'{len(unexercised)} rewrites gave no evidence: {unexercised}')
    return 1 if counts.get('fail') or counts.get('policy') or blocked or unexercised else 0


# --- External uses ------------------------------------------------------------------------------------------------
# Every seed's owners are used from a module of their own, generated from what the seed's attributes declare: each
# selected owner exists and has the conformance the guide gives it, each unselected owner does not exist, and a public
# schema's owners are reachable with a plain import from another package.

SENDABLE_OWNERS = {'Shared', 'ActorHost', 'MainActorHost'}


def client_use_sources(text):
    """(presence source, absence source with the line of each absent owner, whether the schema is public)."""
    source = module_text(text)
    guard = availability_guard(source)
    present, absent, public, published = [], [], False, []
    # Both lists follow the schemas' declarations in order, so two schemas of one basename keep their own paths.
    paths = schema_path_list(source)
    for (schema, owners), path in zip(selected_owners(source), paths if len(paths) == len(selected_owners(source)) else []):
        exported = re.search(r'\bpublic\s+(?:\w+\s+)*enum\s+`?' + re.escape(schema) + r'\b', source) is not None
        public = public or exported
        # `Owned` is generic over its phase: it is named at the initial phase's payload.
        occurrence = sum(1 for p in paths[:paths.index(path)] if p.split('.')[-1] == schema)
        initial = re.search(r'@Initial\b[^\n]*?case\s+`?\w+`?\s*\(\s*([\w.]+)', schema_body(source, schema if not occurrence else f'{schema}#{occurrence}') or '')
        for owner in OWNER_TYPES.values():
            # `IsolatedHost` is generic over the actor it is confined to.
            payload = re.sub(r'^(?:Self|' + re.escape(schema) + r')\.', '', initial.group(1)) if initial else ''
            spelled = f'Fz.{path}.{owner}' + (f'<Fz.{path}.{payload}>' if owner == 'Owned' and initial else
                                               '<MainActor>' if owner == 'IsolatedHost' else '')
            if owner in owners:
                present.append(f'fuzzNeedsType({spelled}.self)')
                if exported:
                    published.append(f'fuzzNeedsType({spelled}.self)')
                if owner in SENDABLE_OWNERS:
                    present.append(f'fuzzNeedsSendable({spelled}.self)')
            else:
                absent.append((owner, f'fuzzNeedsType({spelled}.self)'))
    head = ['import Fz', 'import StateMachine', 'func fuzzNeedsSendable<T: Sendable & ~Copyable>(_: T.Type) {}',
            'func fuzzNeedsType<T: ~Copyable>(_: T.Type) {}', '']
    def wrap(lines):
        body = ['    ' + line for line in lines]
        if guard:
            body = [f'    if #available({guard}) {{'] + ['    ' + line for line in body] + ['    }']
        return '\n'.join(head + ['func fuzzUses() {'] + body + ['}']) + '\n'
    presence = wrap(present)
    absence = wrap([line for _, line in absent])
    lines = absence.split('\n')
    marked = [(owner, lines.index(next(l for l in lines if l.strip() == line)) + 1) for owner, line in absent]
    return presence, absence, marked, wrap(published) if public else None


def client_use_judgement(presence_log, presence_code, absence_log, marked, public_log=None, public_code=None, absence_code=1):
    """Problems of the external uses: the presence module must compile, and the absence module must fail exactly once
    at each absent owner's line, saying the owner does not exist, as an ordinary compilation that finished: a crash,
    a timeout, or a memory kill after the expected diagnostic proves nothing."""
    problems = []
    if marked and (not isinstance(absence_code, int) or absence_code < 0 or CRASH.search(absence_log)):
        problems.append(f'client uses: the absence module\'s compilation did not finish normally ({absence_code})')
    if presence_code != 0:
        problems.append(f'client uses: a selected owner cannot be used from another module: {describe(dict(status="error", errors=classify(presence_log)))}')
    if public_code not in (None, 0):
        problems.append(f'client uses: a public schema\'s owner cannot be used from another package: {describe(dict(status="error", errors=classify(public_log)))}')
    errors = [(int(line), message) for _, line, _, message in ERROR.findall(absence_log)]
    for owner, line in marked:
        here = [m for at, m in errors if at == line]
        if not any(re.search(r"has no member '" + owner + r"'|'" + owner + r"' is not a member type", m) for m in here):
            problems.append(f'client uses: the unselected owner {owner} exists ({here[:1] or "no error"})')
    stray = [m for at, m in errors if at not in {line for _, line in marked}]
    if stray:
        problems.append(f'client uses: the absence module fails elsewhere: {stray[:1]}')
    return problems


def client_use_problems(toolchain, directory, text):
    """Compiles the generated external uses of a seed's module, built in `directory`."""
    module_directory = directory / 'module'
    if not (module_directory / 'Fz.swiftmodule').exists():
        return ['client uses: the schema module was not emitted']
    presence, absence, marked, public = client_use_sources(text)
    def typecheck(name, source, package='FuzzPackage'):
        (directory / name).write_text(source)
        command = toolchain.base('FzUse') + ['-I', str(module_directory), '-typecheck', str(directory / name)]
        command[command.index('-package-name') + 1] = package
        result = watched(command, toolchain.timeout)
        return result.stdout, (result.returncode if result.verdict == 'ok' else result.verdict)
    presence_log, presence_code = typecheck('Uses.swift', presence.replace('import Fz', '@testable import Fz', 1))
    absence_log, absence_code = typecheck('Absent.swift', absence.replace('import Fz', '@testable import Fz', 1)) if marked else ('', 0)
    # Only the public schemas' owners, with a plain import, from another package.
    public_log, public_code = typecheck('PublicUses.swift', public, 'OtherPackage') if public else (None, None)

    return client_use_judgement(presence_log, presence_code, absence_log, marked, public_log, public_code, absence_code)


def missing_quotations(entries, doc):
    """The allowances whose quoted sentence the guide no longer contains."""
    text = ' '.join(doc.split())
    return [e for e in entries if not e.get('doc') or ' '.join(e['doc'].split()) not in text]


def seed_problems(name, outcome):
    """Why a seed does not pass on its own, as `site: detail` problems."""
    if outcome['status'] != 'ok':
        return [f'the seed itself: {describe(outcome)}']
    problems = list(problems_of(outcome)) + list(outcome.get('client_use_problems', []))
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
            if kind == 'typealias':
                # What an unchanged spelling of the alias names depends on its right-hand side.
                right = re.match(r'[^=\n]*=\s*([^\n;]*)', text[match.end():])
                found.append((enclosing, kind, name, ' '.join(right.group(1).split()) if right else ''))
            elif kind != 'extension':
                found.append((enclosing, kind, name, ''))
            if kind != 'typealias':
                pending = name if kind != 'extension' else f'extension {name}'
    # So do the modules each file imports, and the inherited and conforming types each declaration names: an import
    # moved to another file, or a conformance moved to another declaration, changes what a spelling names there.
    files, client = split_case(text)
    sections = list(files.items()) + ([('client', client)] if client is not None else [])
    imports = sorted((name, ' '.join(m.split())) for name, section in sections
                     for m in re.findall(r'^\s*(?:@\w+\s+)*import\s+[^\n]+', section, re.M))
    inherits = sorted((name, ' '.join(declaration.split()), ' '.join(m.split())) for name, section in sections
                      for declaration, m in re.findall(r'\b((?:struct|enum|class|actor|extension)\s+[\w.`]+)\s*:\s*([^{\n]+)\{', section))
    return sorted(found) + [('import',) + i for i in imports] + [('inherits',) + i for i in inherits]


def safe(identifier):
    return re.sub(r'[^\w.+-]', '_', identifier)[:150]


def failure_class(status):
    return status if status in RESOURCE_FAILURES or status in RUN_FAILURES else 'other'


def same_failure(result, variant, verdict, expected):
    """Whether a reduced candidate fails as the original did."""
    return (verdict == 'fail' and expected == result['expected']
            and failure_class(variant.get('status')) == failure_class(result.get('status')))


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
        # A reduction keeps a rewrite's removal only when the smaller case fails the same way: the same expectation,
        # and for a crash, a cap, a timeout, or a failed run, the same kind of failure.
        if same_failure(result, variant, verdict, expected):

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
