# Declaring a graph

Keep each phase's data distinct and declare the edges a caller may take.

A schema is a `nonisolated enum` marked with `@StateMachine(mode:)`. Its cases
are phases, and each carries one distinct nested payload type. `import
StateMachine` is the only import a graph needs, because the macros live in that
module. This graph has one legal transition, from a draft to an approved value.

```swift
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Approval: Sendable {
    struct Draft: Sendable { let title: String }
    struct Approved: Sendable { let title: String }

    @Initial case draft(Draft)
    @Terminal case approved(Approved)

    enum Input: Sendable { case approve }

    @Transition(on: Input.approve)
    fileprivate static func approve(_ source: Draft) -> Approved {
        Approved(title: source.title)
    }
}

func approveDraft() {
    let draft = Approval.Draft(title: "Launch checklist")
    let approved = Approval.owned(draft).approve()
    print(approved.withValue { $0.title })
}
```

`Approval.owned(_:)` takes the draft and creates an owner in the initial phase,
and `withValue` reads the payload an owner holds. The generated `Owned<Draft>`
exposes `approve`, while `Owned<Approved>` does not. Calling the edge consumes
the draft owner and returns `Owned<Approved>`. An edge that starts nothing
returns its destination payload directly, and the macro derives the edge's
endpoints from its signature. Because `approve` takes a `Draft` and returns an
`Approved`, it leads from the `draft` phase to the `approved` phase. Its
trigger, `Input.approve`, is an ordinary reference that the compiler resolves,
so a misspelled case fails to compile at the attribute.

`@Terminal` says that the graph intends to end in `approved`. The macro checks
the graph's structure on every build, and a phase that no edge leaves must say
so. [Satisfy the graph checks](<doc:DeclaringAGraph#Satisfy-the-graph-checks>)
lists every check.

The plain `Draft` and `Approved` values remain ordinary data. Constructing an
`Approved` does not construct an `Owned<Approved>`.

## Name each declaration

| To declare | Write |
| --- | --- |
| The ownership contract | `@StateMachine(mode: .shared)`, `.isolated`, or `.ownedOnly` on a `nonisolated enum` |
| Only some of the owners | `@StateMachine(mode: .shared, owners: [.local, .mainActorHost])` |
| A phase | A `case` with one payload type declared inside the schema |
| The initial phase | `@Initial` on exactly one `case` |
| A default initial payload | A default on the initial case, as in `@Initial case idle(Idle = Idle())` |
| A phase the graph ends in | `@Terminal` on a `case` that no edge leaves |
| An input | A case of the nested `enum Input` |
| An edge that starts nothing | `@Transition(on: Input.approve)` on a function returning the destination payload |
| An edge that starts operations | `@Transition(on: Input.begin, starts: [Fetch.self])` on a function returning `Change<Destination, Effect.Begin>` |
| One edge from several phases | `@Transition(from: [Draft.self, Failed.self], on: Input.close)` without a source parameter, or with a single generic `<Source>` source parameter |
| A reusable source-phase list | `@PhaseSet([Draft.self, Failed.self])` on an empty nested enum, named by `@Transition(from: Active.self, on: Input.close)` |
| An operation | `@Operation(activeIn: [Searching.self])` on an enum, with optional `Input`, `Output`, `Failure`, and `Key` aliases |
| A completion edge | `@Transition(onSuccess: Fetch.self)` or `@Transition(onFailure: Fetch.self)` |
| Several edges for one source and trigger | `@Route(on:)`, `@Route(onSuccess:)`, or `@Route(onFailure:)` on a selector function |
| A typed handoff from a router to a chosen edge | A final `routed:` parameter on a candidate `@Transition` chosen by `@Route` |
| Authority that several operations share | A case of the nested `enum Scope`, with `@Active(in:)` for its phases, named by `@Operation(scope: Scope.account)` |
| Authority an edge revokes without leaving the active phases | `invalidates: [Scope.account]` |
| A dependency on a scope another operation owns | `requires: [Scope.session]` |
| Cancellation of one key's work | `cancels: [Download.self]`, for an operation with a `Key` alias |
| An event | `@Event` on an enum, with an optional `Payload` alias, listed in an edge's `emits:` |
| Validation of saved data | `@Restoration` on one function returning `Restoration`, with `allows:` or `only:` to choose its phases |

Write each reference in an attribute exactly as shown, using forms such as
`Input.approve`, `Scope.account`, `Fetch.self`, and `.shared`. The macro reads
the spelling, so it rejects qualified forms such as `Lookup.Input.approve`,
implicit members such as `.approve`, and computed expressions. An attribute may
include its module name, as in `@StateMachine.Transition`. A phase payload in
an edge signature may be written `Draft`, `Self.Draft`, or `Approval.Draft`. An
operation can spell its infallible `Failure` as `Never` or `Swift::Never`.

### How the macro resolves type spellings

A spelling means what it means where it is written, and the macro reads it
through the declarations it can see, including the types and aliases declared
inside the schema, inside the nongeneric types the schema declares, and inside
the namespace that spells it. With `typealias Unit = Void` in the schema, an
`Output` of `Unit` produces no value, and with `typealias Problem = Never`, a
`Failure` of `Problem` cannot fail. A generic alias the schema declares reads
with its arguments, so with `typealias Identity<T> = T`, a `Failure` of
`Identity<Never>` cannot fail. An alias chain of any length reads through to
the type it names. A schema or namespace that declares its own `Void` or
`Never` type means that type, so an operation whose `Failure` names the
schema's `Never` can fail, and a dotted name means what its first part names
there, so `Swift.Never` names the `Never` of a `Swift` type the schema
declares.

Parentheses change nothing, so `(Values).Unit` and the members of
`typealias Namespace = (Values)` read as those of `Values`. Backticks change no
name, so `Unit` written in backticks names `Unit`, and an alias named `Type`,
which its declaration writes in backticks, is the type a bare `Type` names
wherever no period precedes it. A tuple element's `_` is no label, as Swift
reads it, so `(_: A, B)` is `(A, B)` and `(_: ())` is `()`, while an underscore
written in backticks is a label of its own. `()`, `Swift::Void`, and
`Swift::Never` always name the standard library's types.

In the schema's `graph`, each type spelling preserves the author's text, keeping
the type's tokens as written with one space wherever whitespace, a line break,
or a comment separated two of them, so `Self.Draft` stays `Self.Draft`. Each
spelling resolves in the scope where it was written, so a phase's payload
resolves inside the schema, an input case's payload inside `Input`, and an
operation's or event's types inside its namespace. A type the namespace omits is
spelled through the standard library's module, `Swift::Void` or `Swift::Never`,
which no declaration shadows. With `typealias Detail = String` in the schema
and `typealias Detail = Int` in an extension of `Input`, an input case
`fill(Detail)` takes an `Int`, and the graph shows its payload as `Detail`, the
name Swift resolves inside `Input`. Because the macro cannot see the extension,
the graph never rewrites a spelling into one it would have to resolve elsewhere.

The macro reads only what the graph reaches. An alias that no operation, event,
payload, or signature names is never read, and a generic alias reads an
argument only where its own spelling uses that parameter, so with
`typealias First<X, Y> = X`, `First<A, B>` never reads `B`. A chain of aliases
that each name the next reads without nesting, however long it is, whether the
aliases are generic, as in `typealias G2<T> = G1<T>`, or not. An alias that
names itself, directly or through other aliases, is diagnosed where it is
declared once a reading reaches it. The compiler reports one that nothing reads,
and one that a member the macro cannot see, such as one a class inherits, could
make a different alias.

A reading that nests too deeply through the structure its aliases spell, such
as an alias that wraps another in an array at each of a thousand levels, or
that takes more than a fixed number of steps, is diagnosed at the declaration
that spells it. Spell the type directly or through fewer aliases. Every type
the macro reads counts as a step, and so do each generic argument of a use,
each enclosing scope a name is looked up through, and each member a composition
gathers from a composition it names. A structure as wide as that bound, such as
a tuple, a function's parameters, or a composition of a hundred thousand types,
is diagnosed the same way. So is a family of compositions that repeats a wide
one across many aliases, such as a hundred aliases that each add one protocol
to the same 500-protocol composition. The macro never guesses past that bound.

An alias that names a type by a path of names, such as `Namespace`, `Self`,
`Flow.Namespace`, `(Namespace)`, or another such alias, is read wherever a
reading reaches it, so a member of it is looked up at once. `N.Discard<Wide>`
for `typealias N = Namespace` or `typealias N = (Namespace)` costs what
`Namespace.Discard<Wide>` does, and an alias that ignores its argument never
reads it, by any of those spellings. An alias of another alias costs what that
alias does, so a composition of three hundred aliases of one 500-protocol
composition gathers its members once, as three hundred uses of its own name do.
An alias whose reading would keep more than 1,024 types reads as a type of its
own, equal to no other spelling, wherever and in whatever order a reading
reaches it.

### Comparing thrown failure types

The macro compares the types functions throw by what they name, so `[Detail]`
and `Swift::Array<Detail>` are one type, as are `Detail?` and
`Swift::Optional<Detail>`, `[Key: Value]` and `Swift::Dictionary<Key, Value>`,
`any Failure` and `Failure` for a protocol `Failure` the schema declares,
`A & B` and `B & A`, `PQ & R` and `P & Q & R` for `typealias PQ = P & Q`,
`P & P` and `P`, `(_: A, B)` and `(A, B)`, and `@Sendable @MainActor () -> Int`
and `@MainActor @Sendable () -> Int`. The macro orders a composition's members
by what each names rather than by how it prints, so a nested protocol `N.P` and
a protocol whose name is the raw identifier `N.P`, written in backticks, are
two members, and a composition of the two is one type in either order. Two
router candidates that throw `Problem<[Detail]>` and
`Problem<Swift::Array<Detail>>` share one failure, and an integer argument
compares by its value, so `Problem<10>`, `Problem<1_0>`, and `Problem<0xA>` are
one type.

A metatype follows Swift's own rule. A protocol's `Failure.Type`, spelled bare,
in parentheses, or through an alias of the protocol, is the existential
`any Failure.Type` of every conforming type's metatype, while
`(any Failure).Type`, which `Failure.Protocol` and the `T.Type` of a generic
argument standing for `Failure` also name, is the metatype of the existential.
So candidates that throw `Problem<Failure.Type>` and
`Problem<any Failure.Type>` share a failure, and candidates that throw
`Problem<Failure.Type>` and `Problem<(any Failure).Type>` do not. The standard
library's sugared types are concrete, so `[Int].Type` and
`Swift::Array<Swift::Int>.Type` are one metatype. Every type keeps its
structure, so `(() -> Int).Type` and `() -> Int.Type` are two types, as are
`(() -> Int)?` and `() -> Int?`, and a custom attribute such as a global actor
names the type its own scope finds, so `@Actors.Main` inside two different
namespaces can name two actors. A function that throws `Never`, spelled
directly or through an alias the schema declares, does not throw. Its generated
methods return without a rejection, and no router treats it as one that can
fail.

Two failures are one only when the macro can prove it. Either both readings are
confirmed, as the next section describes, and name the same type, or both are
spelled alike apart from comments, spacing, redundant backticks, and a leading
`Self.` or schema name. Every other pair counts as two failures, which keeps the
generated code correct and only makes a router's method throw
`PreparationRejection` where one shared type would do. Spell two failures
identically, or name the common type with `failure:`, to merge them.

### Unconfirmed type readings

The macro cannot see declarations outside the schema, such as an alias at module
scope, an extension of a type the schema declares, a member a class inherits,
or one a protocol extension supplies. So it confirms what kind of type a
spelling names, whether `Void`, `Never`, a function type, or another type with
values, only when nothing it cannot see could change it. A spelling's structure
confirms its kind whatever the names inside it mean, so `(A, B)` is a tuple,
`() -> A` a function, and `[A]` an array. A name confirms its kind only through
lookups the macro confirms. A name a nested scope finds outside itself, as an
operation's namespace finds `Detail` in `typealias Output = Detail`, could be
hidden by a member an extension gives the namespace, and so could the schema's
own name there, as in `typealias Output = Flow.Detail`. A bare `Void`, `Never`,
`Error`, `Array`, `Dictionary`, `Optional`, or `InlineArray`, or a name read
through a `Swift` the schema does not declare, could be taken by a declaration
outside the schema, and the macro cannot see into a type declared outside the
schema at all.

A name found in the scope that spells it, `Self`, and a module selector such as
`Swift::Int` change under nothing the macro cannot see. So does the schema's
own name at the schema's scope. Because generated code names the schema by it,
every expansion checks that it names the schema and fails to compile with a
message when an extension of the schema declares a type of that name. A type or
type alias of that name declared directly inside the schema is refused. A
property or method of that name changes nothing, because generated code names
the schema only where Swift looks up a type. A module selector names one
declaration, but it confirms that declaration's kind only for the standard
library's own types, protocols, and aliases whose kind the macro knows, such as
`Swift::Int` and `Swift::Array<Swift::Int>` having values and
`Swift::UnboundedRange` aliasing a function type. Any other name, such as the
caseless namespace `Swift::Unicode` or a type another module declares, keeps
its identity and leaves its kind for the expansion to check.

A diagnostic that rejects a declaration rests only on a reading the macro
confirms. Where it cannot confirm a reading, the generated code either works for
whatever type Swift resolves, or follows what the rest of the declaration says
and checks against the type on the alias the conclusion is about, such as
`Load.Output` at the schema's scope, so the check holds however the spelling's
names resolve.

- An operation's request and work store its `Input` and `Output` through a
  generic parameter, so a closure input or output is stored whatever the macro
  reads, and `LoadRequest(input:)` and `work.succeeded(_:)` take it as an
  `@escaping` parameter would. A driver receives an input the macro confirms
  is a function type as `@escaping`, so it can keep it. Any other input reaches
  the driver as it is, which a closure does too, so the driver can call it.
- An `Input` or an event's `Payload` that the macro reads as a type with values
  is carried as a value, which is correct for any type including `Void`, where
  the effect is written `.load(())`. One it reads as `Void` without confirming
  it is omitted, and checked to be the standard library's `Void`, unless a
  completion of an operation without a `Key` takes the operation's request. That
  request says the work carries its input, so the input is carried as it is.
  Carriage is decided first, and a carried input of any reading the macro cannot
  confirm is checked not to be `Never`, so a module-scope
  `typealias Void = Swift::Never` cannot hide an input no transition can start.
- Whether an operation succeeds follows its `onSuccess:` edges and routers.
  With none, its `Output` is read as `Never`, and with one, as a type with
  values. Whether a success carries a value follows what those functions take
  after the source. One that takes an unlabeled parameter there takes the
  output, and functions that take none, or only the request labeled `request:`,
  say it is `Void`. The label alone decides which parameter is the request, so
  no spelling of a type changes the generated shape. Whether an operation can
  fail follows its `onFailure:` edges and routers in the same way. The expansion
  checks each conclusion, so with `typealias Output = Product` and an extension
  of the namespace that declares `Product` as `Int`, a success edge that takes
  `Load.Output` compiles, and one that takes nothing fails to compile with a
  message that says the operation succeeds without output.
- A type a function throws, or a router's result, that the macro reads as
  `Never` without confirming it, must be the standard library's type. A router
  with no edge to choose must throw, so a spelling of `Never` it throws names a
  type with values, and every function that throws the same spelling throws
  that type.
- An operation's `Input`, `Output`, `Failure`, or `Key`, an event's `Payload`,
  or a type a transition, router, or `@Restoration` function throws, that the
  macro reads as a type with values without confirming its kind, must not be
  `Never`. Otherwise the expansion fails to compile with a message, so spell the
  type `Never` there to have the macro read it as `Never`. This covers a type
  declared outside the schema, a member of a type the macro does not read, such
  as `[Int].Element`, a generic alias it cannot expand, such as one over a
  parameter pack, and an alias that reaches `Never` through an inherited member,
  as `Child.Outcome` does in `class Child: Parent { typealias Outcome = Product }`
  when `Parent` declares `typealias Product = Never`.
- An operation's `Input` or `Key`, an event's `Payload`, or an `Input` case's
  payload, that the macro reads as `Never` through a name it cannot confirm, is
  checked not to be `Never`, with the message that rejects one it confirms. An
  operation whose `Output` and `Failure` both read as `Never`, without both
  confirmed, compiles only if one of them has values.
- A router with no edge to choose, whose result the macro cannot confirm, is
  checked to return `Never`, and so is the `Advance` effect argument of an
  owned-only edge without effects.

Spell a type through a module selector, or declare it in the namespace that
uses it, and the macro confirms its reading, so the expansion checks it only
when it names a type the macro cannot see into.

### Input case payloads

An `Input` case can carry a type declared inside `Input`, including a global
actor named in an attribute, as in
`case decode(@DecodeActor @Sendable () -> Int)`. `Input` resolves each case's
payload, through an extension of `Input` too, so the generated witness that an
edge takes the payload infers it from the value a pattern of the case binds
alone, as `case .decode(let bound)`, and then compares it with the edge's
parameter on its own. The edge therefore takes the exact type Swift gives the
case, so an edge that takes `Int` for a case carrying `Int?`, `any Shape` for
one carrying `Circle`, or `@Sendable () -> Void` for one carrying `() -> Void`
fails to compile, whichever owners the schema generates. No case can carry a
`Never` that the macro can see, since no input could ever have that case. A
case whose payload names `Never` through an alias declared outside the schema
is the exception, because the macro reads it as a type with values and the
schema compiles with a case that no input can have. Swift reports an edge that
takes such a payload, which can never run.

### Parameter ownership and sending

A transition or router takes its payload, and a completion edge or router its
operation's request, with the passing convention it needs. The generated
methods that pass either on keep `@escaping` and `sending`, so a transition can
store an escaping closure, as in `_ work: @escaping @Sendable () -> Int`. An
`Owned` method passes its payload on once, so it also repeats the payload's
ownership as the transition spells it, whether `borrowing`, `consuming`,
`__shared`, or `__owned`.

An `Owned` router's method lends the payload to the router and then passes it
on to the edge the router selects. Its ownership comes from how those functions
spell theirs rather than from the payload's type, which an alias can hide. The
method is legal whatever the payload is, including a closure, which cannot be
`consuming` unless it is `@escaping`, or a noncopyable value, which must
declare an ownership.

- When one of the functions takes the payload `@escaping`, the payload is a
  function type, which is copyable, so the method takes it `@escaping` with no
  ownership, and lends it to each function that takes it nonescaping. It is
  `__shared sending @escaping` when a function of the group sends the payload,
  so a caller that only borrows the closure can still call the method. The
  router and its edges may each take the closure escaping or not, with any
  ownership.
- When one of the functions declares no ownership, the payload is copyable, so
  the method takes it as a plain parameter. That parameter is copied
  implicitly where the payload is needed twice. The method also takes it plain
  when the router takes it as its own, `consuming`, `__owned`, or `sending`,
  because the edge it selects still takes the payload after the router.
- Otherwise, when an edge the router may select takes the payload as its own,
  the method takes it the way that passes it on. It takes it `consuming` when
  a function of the group spells `consuming`, which a nonescaping closure
  cannot be, and `__owned` when the group spells `__owned`.
- Otherwise every function only lends the payload, and the method borrows it,
  so a caller that only borrows the payload can call the method. It is
  `__shared sending` when a function takes it that way, the one lending
  spelling that `sending` can join.

The method also keeps `sending` when any function of the group sends the
payload. A router that takes a noncopyable payload as its own leaves nothing
for the edge it selects, so the expansion checks the payload is copyable
whenever every function declares an ownership and none takes it `@escaping`. It
reports a message that asks you to take the payload `borrowing` in the router.

`Observed` methods and the request take their values as plain parameters,
which pass a copy to either. A payload or request cannot be `inout`,
`isolated`, or `@autoclosure`, or an opaque `some` type, which would make the
function generic.

A `sending` payload or request is transferred as it is wherever generated code
holds the value alone and passes it on once. In an `.isolated` schema, whose
payloads need not be `Sendable`, an observing owner keeps each input it
receives, and each outcome and request until a transition accepts it, so where
an edge or router of a schema that generates an owner other than `Owned` takes
a payload or request as `sending`, the value's type must be `Sendable`. An
operation's request is `Sendable` exactly when its input is, and a request that
carries only a key always is. A `sending Int` payload compiles, and a mutable
class fails to compile because it does not conform to `Sendable`.

An `Owned` router's method lends its source phase, its payload, and the request
it takes to the router, which joins every one of them that is not `Sendable`,
and then passes them to the edge it selects. Measured against Swift's region
checker, an edge may then take a value as `sending` under these rules, each of
which a generated check enforces with a message.

- A value the router takes as `sending` is given away, so an edge that takes it
  after needs it `Sendable`.
- A value one edge takes as `sending` while another edge takes it without needs
  to be `Sendable`, whether or not the router reads it, because the method
  keeps a value it may give away.
- A value an edge takes as `sending` that the router reads without it carries
  everything the router joined it with. So the value or the source phase's
  payload must be `Sendable`, and the value or the other value the router reads
  without `sending`, the payload or the request, must be too, unless that other
  value reaches the method as `sending`, because some function of the group
  takes it so, and that edge leaves it out.

Omitting the request from the router removes the joins caused by the router
reading it, so the third rule no longer pairs another value with the request.
If candidate edges take the request with different `sending` conventions, the
request still has to be `Sendable`, by the second rule. A group in which no
function takes a value as `sending` meets every rule. A `.shared` schema's
payloads are `Sendable`, which passes to a `sending` parameter as to any other.

### Default initial payloads

The `@Initial` case, and only that case, may give its payload a default. Every
fresh entry point then takes the initial payload as an optional argument,
covering `owned(_:)`, `Local`, `Shared`, `ActorHost`, `MainActorHost`,
`IsolatedHost`, and every owner's `reset(to:)`. An `init(restoring:)` is
unaffected, because saved data is always explicit. The default is a call with
no arguments. It either constructs the payload, as in `Idle()`, or calls a
static function of the schema that returns the payload, as in `makeIdle()` or
`Lookup.makeIdle()`. The case may spell its payload `Idle`, `Self.Idle`, or
`Lookup.Idle`, and the call may name it any of those ways. An owner created
without the payload evaluates the call once. The macro rejects any other
expression, so to default to something more involved, put the construction in a
static function that returns the payload and name that function. Swift checks
the call itself, so a public schema needs a public initializer or function, and
a payload whose construction can throw or fail has no default. Declare one only
when an empty start is true to the domain. A payload that carries required
data, such as a user identifier, is passed explicitly.

## Start an operation

An operation is work the host runs and whose result returns through a
completion edge. This schema starts a search and handles its result.

```swift
@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    struct Idle: Sendable {}
    struct Searching: Sendable { let query: String }
    struct Found: Sendable { let answer: String }

    @Initial case idle(Idle = Idle())
    case searching(Searching)
    @Terminal case found(Found)

    enum Input: Sendable { case search(String), cancel }

    @Operation(activeIn: [Searching.self])
    enum Fetch {
        typealias Input = String
        typealias Output = String
    }

    @Transition(on: Input.search, starts: [Fetch.self])
    fileprivate static func begin(_ source: Idle, _ query: String) -> Change<Searching, Effect.Begin> {
        Change(Searching(query: query), effects: [.fetch(query)])
    }

    @Transition(on: Input.cancel)
    fileprivate static func cancel(_ source: Searching) -> Idle { Idle() }

    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Searching, _ answer: Fetch.Output) -> Found {
        Found(answer: answer)
    }
}
```

The operation namespace declares `Input`, what the work receives, and `Output`,
what it returns. Its `activeIn` list names the phases where it may run, and
leaving them revokes the work. Here, `cancel` returns to `Idle`, so a result
that arrives afterward is stale. That list gives the operation a private scope
of its own, active exactly in those phases, which no edge can name. Its
`admission:` is `.latest` unless it says otherwise, which replaces older work
with the newer start. The other policies are `.rejectWhenActive` and
`.parallel(limit:)`. Work receives the post-commit activation of every scope it
holds.

The macro generates the `Effect` type. It has one case per operation, named in
lower camel case. For example, `Fetch` becomes `.fetch`, and `URLFetch` becomes
`.urlFetch`. Each edge that lists `starts:` also gets its own effect type named
after the function, so `begin` has `Effect.Begin`. That type contains only the
listed operations, and returning an effect outside `starts:` does not compile.
Two edges with the same `starts:` have distinct effect types. Each value's
`effect` property widens it to the schema-wide `Effect`. When the schema's
inheritance clause lists `Equatable` or `Hashable`, `Effect` and every edge's
effect type conform to it too, so a test in another module can compare
effects. The clause is read where the schema is declared, outside its body, so
a type of the protocol's name inside the schema does not take it. The generated
types name the standard library's protocol, so the expansion checks that the
schema conforms to it when the clause names it bare or through a dotted
`Swift`, and fails to compile with a message when a declaration outside the
schema takes the name.

An operation needs a success edge or router in every phase where it may run,
unless its `Output` is `Never`.
A completion edge may also list `starts:` to chain a successor operation.

### Leave out what an operation does not use

Every alias is optional. Without `Input`, the work takes no input, so its effect
case has no payload, its work has no `input`, and its driver takes no argument.
Without `Output`, the output is `Void`, and a success edge or router takes no
output parameter, as in `static func finished(_ source: Running) -> Ready` for
an operation `Ping` that produces nothing. The macro declares the omitted
aliases as `Void`, so `Measure.Output` always names the output a completion
edge takes. This gauge starts a reading that needs no input.

```swift
@StateMachine(mode: .shared)
nonisolated enum Gauge: Sendable {
    struct Ready: Sendable { var readings: [Int] = [] }

    @Initial case ready(Ready = Ready())

    enum Input: Sendable { case measure }

    @Operation(activeIn: [Ready.self])
    enum Measure { typealias Output = Int }

    @Transition(on: Input.measure, starts: [Measure.self])
    fileprivate static func take(_ source: Ready) -> Change<Ready, Effect.Take> {
        Change(source, effects: [.measure])
    }

    @Transition(onSuccess: Measure.self)
    fileprivate static func store(_ source: Ready, _ reading: Measure.Output) -> Ready {
        Ready(readings: source.readings + [reading])
    }
}

func makeGauge() -> Gauge.Shared {
    Gauge.Shared(measureDriver: { 21 })
}
```

`ready` has edges that lead back to itself, so it is a legitimate long-lived
phase rather than a dead end.

### Declare a failure

An operation whose work can fail adds a `Failure` alias. Without one, `Failure`
is `Never`, the operation cannot fail, and its driver returns the `Output`
itself. Such an operation has no failure edge or router, because one would never
run and the macro rejects it. With a `Failure`, the operation also needs a
failure edge or router in every phase where it may run, and its driver returns
`Result<Output, Failure>`. Where the macro cannot confirm what the `Failure`
alias names, as here where an extension of `Send` could declare its own
`Reason`, the failure edges decide and the expansion checks the type. Without a
failure edge, the operation reads as one that cannot fail, and fails to compile
with a message unless `Failure` is `Never`.

```swift
@StateMachine(mode: .shared)
nonisolated enum Upload: Sendable {
    struct Idle: Sendable {}
    struct Running: Sendable { let name: String }
    struct Done: Sendable { let bytes: Int }
    struct Failed: Sendable { let reason: Reason }

    enum Reason: Error, Sendable { case offline }

    @Initial case idle(Idle = Idle())
    case running(Running)
    @Terminal case done(Done)
    @Terminal case failed(Failed)

    enum Input: Sendable { case start(String) }

    @Operation(activeIn: [Running.self])
    enum Send {
        typealias Input = String
        typealias Output = Int
        typealias Failure = Reason
    }

    @Transition(on: Input.start, starts: [Send.self])
    fileprivate static func start(_ source: Idle, _ name: String) -> Change<Running, Effect.Start> {
        Change(Running(name: name), effects: [.send(name)])
    }

    @Transition(onSuccess: Send.self)
    fileprivate static func sent(_ source: Running, _ bytes: Send.Output) -> Done {
        Done(bytes: bytes)
    }

    @Transition(onFailure: Send.self)
    fileprivate static func failed(_ source: Running, _ reason: Send.Failure) -> Failed {
        Failed(reason: reason)
    }
}

@MainActor
func makeUploadHost() -> Upload.MainActorHost {
    Upload.MainActorHost(sendDriver: { name in
        name.isEmpty ? .failure(.offline) : .success(name.count)
    })
}
```

A driver returns `Result` rather than throwing, so a closure literal needs no
thrown-type annotation.

### Key work by an instance

An operation with a `Key` alias runs one piece of work per key, such as one
download per file. Its effect names the key, as in `.download(key: id, input:
url)`, or `.download(key: id)` when the input is `Void`, and its driver takes
the key before the input. Admission applies the policy to each key, so `.latest`
replaces only that key's work, and `.rejectWhenActive` and `.parallel(limit:)`
count only that key's. The key must be `Hashable` and `Sendable`. An edge that
lists the operation in `cancels:` may return `.cancelDownload(key: id)` to
revoke one key's work, or `.cancelAllDownload` to revoke every key's.
Cancelling a key without work does nothing, and admission applies an edge's
cancellations before its starts, so one edge can cancel a key and start it
again.

A completion edge or router can take one more parameter, the operation's
generated request, which records the `key` and `input` the work was started
with. The request is the parameter labeled `request:`, and it comes last, after
the source and after any unlabeled output or failure, as in
`static func received(_ loading: Loading, _ data: Data, request: LoadRequest) -> Ready`.
A success edge of an operation without output takes the request right after its
source, as in `static func finished(_ loading: Loading, request: LoadRequest) -> Idle`,
and an unlabeled parameter there, such as `_ output: Void`, is an error that asks
to remove it. This library files each title under the key its download was
started for.

```swift
@StateMachine(mode: .shared)
nonisolated enum Library: Sendable {
    struct Browsing: Sendable { var titles: [Int: String] = [:] }

    @Initial case browsing(Browsing = Browsing())

    enum Input: Sendable { case open(Int), close(Int), closeAll }

    @Operation(activeIn: [Browsing.self])
    enum Download {
        typealias Key = Int
        typealias Input = String
        typealias Output = String
    }

    @Transition(on: Input.open, starts: [Download.self])
    fileprivate static func open(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Open> {
        Change(source, effects: [.download(key: id, input: "https://example.com/books/\(id)")])
    }

    @Transition(on: Input.close, cancels: [Download.self])
    fileprivate static func close(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Close> {
        Change(source, effects: [.cancelDownload(key: id)])
    }

    @Transition(on: Input.closeAll, cancels: [Download.self])
    fileprivate static func closeAll(_ source: Browsing) -> Change<Browsing, Effect.CloseAll> {
        Change(source, effects: [.cancelAllDownload])
    }

    @Transition(onSuccess: Download.self)
    fileprivate static func downloaded(
        _ source: Browsing,
        _ title: Download.Output,
        request: DownloadRequest
    ) -> Browsing {
        var titles = source.titles
        titles[request.key] = title
        return Browsing(titles: titles)
    }
}

func makeLibrary() -> Library.Shared {
    Library.Shared(downloadDriver: { id, url in "Book \(id) from \(url)" })
}
```

Every operation that has a key or an input has a request type named for it,
`DownloadRequest` here, and an unkeyed one holds only `input`. An operation
with neither has no request. The request is plain data with a public
initializer, so it grants no authority. A request that carries an input is
``KeyedOperationRequest`` or ``OperationRequest`` specialized for the operation,
so it is `Sendable`, `Equatable`, and `Hashable` exactly when its input is. One
that carries only a key is `Hashable` and `Sendable` as its key is. A work
value, its completion, and a retained completion all carry the request that
admission captured, so a result that waits for reconciliation still knows its
key.

The label decides which parameter is the request rather than the type, so a
parameter's role never depends on how its type is spelled or what an alias
outside the schema names. The expansion checks each type so that the `request:`
parameter must be the exact operation request, through any alias, and the
unlabeled one must be its exact `Output` or `Failure`, each with a message that
names the role. An operation whose `Output` is its own request type, as
`typealias Output = DownloadRequest`, takes the request type unlabeled as its
output, and may take the request again as `request:`. A `request:` parameter on
an operation that has neither a key nor an input, or on an edge of an input, is
an error at the declaration, and so is a request that is not last or is taken
twice.

## Share authority with a scope

A named scope is for authority that more than one operation needs, or that an
edge must revoke while the operations stay in their phases. Declare a case of
the nested `Scope` enum and list the phases in which it stays active with
`@Active(in:)`. An operation that names the scope in `scope:` takes its phases
from it and declares no `activeIn` of its own. Every operation with that
primary scope shares one activation, so an edge that invalidates it revokes all
of them. A scope case without `@Active` is active in every phase.

`requires:` lists further scopes an operation depends on, and the operation
may run only in the phases its scopes share. Leaving those phases already
revokes an operation's work, so `invalidates:` covers the other case, revoking
work while staying in a phase where the operation is active. This feed loads
its items and the account's avatar under one account scope, and
`switchAccount` revokes both and starts them again for the new account without
leaving `Loading`.

```swift
@StateMachine(mode: .shared)
nonisolated enum Feed: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable {
        let account: String
        var avatar: String? = nil
    }
    struct Loaded: Sendable { let items: [String] }

    @Initial case idle(Idle = Idle())
    case loading(Loading)
    @Terminal case loaded(Loaded)

    enum Scope {
        @Active(in: [Loading.self])
        case account
    }

    enum Input: Sendable { case load(String), switchAccount(String) }

    @Operation(scope: Scope.account)
    enum Fetch {
        typealias Input = String
        typealias Output = [String]
    }

    @Operation(scope: Scope.account)
    enum Avatar {
        typealias Input = String
        typealias Output = String
    }

    @Transition(on: Input.load, starts: [Fetch.self, Avatar.self])
    fileprivate static func begin(_ source: Idle, _ account: String) -> Change<Loading, Effect.Begin> {
        Change(Loading(account: account), effects: [.fetch(account), .avatar(account)])
    }

    @Transition(on: Input.switchAccount, invalidates: [Scope.account], starts: [Fetch.self, Avatar.self])
    fileprivate static func switchAccount(
        _ source: Loading,
        _ account: String
    ) -> Change<Loading, Effect.SwitchAccount> {
        Change(Loading(account: account), effects: [.fetch(account), .avatar(account)])
    }

    @Transition(onSuccess: Avatar.self)
    fileprivate static func showAvatar(_ source: Loading, _ avatar: Avatar.Output) -> Loading {
        Loading(account: source.account, avatar: avatar)
    }

    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Loading, _ items: Fetch.Output) -> Loaded {
        Loaded(items: items)
    }
}
```

An operation either names a scope or lists `activeIn`, never both, because
`@Operation(scope:requires:admission:)` and
`@Operation(requires:activeIn:admission:)` are separate macros. A schema
whose operations all use `activeIn` and whose edges invalidate nothing needs no
`Scope` enum.

## Emit events

An event is an inert announcement that an edge makes as part of its change,
such as a line for an analytics log. Mark an enum with `@Event`, give it a
`Payload` alias, or none for `Void`, and list it in an edge's `emits:`. The
edge returns it among its effects, `.tracked(line)` here, or `.tracked` without
a payload.

```swift
@StateMachine(mode: .shared)
nonisolated enum Cart: Sendable {
    struct Shopping: Sendable { var items: [String] = [] }
    struct Ordered: Sendable { let items: [String] }

    @Initial case shopping(Shopping = Shopping())
    @Terminal case ordered(Ordered)

    enum Input: Sendable { case add(String), order }

    @Event
    enum Tracked { typealias Payload = String }

    @Transition(on: Input.add, emits: [Tracked.self])
    fileprivate static func add(_ source: Shopping, _ item: String) -> Change<Shopping, Effect.Add> {
        Change(Shopping(items: source.items + [item]), effects: [.tracked("added \(item)")])
    }

    @Transition(on: Input.order, emits: [Tracked.self])
    fileprivate static func order(_ source: Shopping) -> Change<Ordered, Effect.Order> {
        Change(Ordered(items: source.items), effects: [.tracked("ordered")])
    }
}

@MainActor
func makeCart() -> Cart.MainActorHost {
    Cart.MainActorHost(onTracked: { line in print(line) })
}
```

An event has no driver, output, completion, scope, or authority. `Owned`
returns it in the edge's effects. `Local` carries it as a command in the
acceptance's batch, in the order the edge wrote it among its starts. Every
managed owner takes one required handler per event, labeled `on` followed by
the event's name, and calls it once per emission, in commit order, after the
commit and outside every lock. A handler never runs inside admission, so it may
read the owner or send it another input.

A managed owner's initializers take one driver per operation, in the order the
operations are declared, and then one handler per event, in the order the
events are declared. `Local` takes no handlers and delivers each event through
`drainCommands(limit:)`. Moving an operation's or event's declaration therefore
moves its argument on managed initializers, and calls that pass them in the old
order no longer compile.

### When event handlers run

On every managed owner, `@Event` handlers run after the commit during batch
draining, outside admission and outside every lock. No managed owner guarantees
that `on<Event>` has returned when `send(_:)` or `commit(_:)` returns.

- On `MainActorHost`, state commits synchronously on `@MainActor`. The returned
  `Receipt` and a synchronous post-send read of `snapshot()` or
  `currentSnapshot` reflect the commit right away, while `on<Event>` runs on a
  later `@MainActor` turn.
- On `IsolatedHost<Owner>`, state commits synchronously on `Owner`. The returned
  `Receipt` and a synchronous post-send read of `snapshot(isolation:)` reflect
  the commit right away (`IsolatedHost` exposes `snapshot(isolation:)` and has
  no `currentSnapshot` property), while `on<Event>` runs on a later turn of
  `Owner` with `isolated Owner`.
- On `ActorHost`, state commits synchronously in the host actor's turn of
  `await send(_:)` or `await commit(_:)`. Draining runs in a detached turn on
  the host actor, so `on<Event>` may or may not have run by the time the caller
  resumes from `await` (including with `isolatedTo:`).
- On `Shared`, state commits atomically and the returned `Receipt` captures that
  exact commit, while a separate synchronous `host.snapshot()` read can already
  show a newer revision from another writer. Draining runs concurrently on a
  serial background task outside every lock, so when `send(_:)` or `commit(_:)`
  returns, `on<Event>` may still be pending, running on another thread, or
  already finished.
- On `Local`, `mutating send(_:)` and `commit(_:)` commit synchronously and
  append emitted events to the queued `CommandBatch` (after cancellations, in
  authored effect order among starts) for `drainCommands(limit:)`. `Local` never
  calls handlers.
- On `Owned`, the consuming edge method returns emitted events synchronously in
  `Change.effects` or `Advance.advanced(_:effects:)`.

Inspect the returned `Receipt` (`receipt.snapshot`, `receipt.revision`,
`receipt.edgeID`) when caller code needs synchronous post-commit work in the
same turn. `Receipt` carries no emitted event payloads. Drive `Local` and call
`drainCommands(limit:)` when a caller needs synchronous access to emitted
events.

Call `await host.flush(through: receipt)` on any of the four managed owners
(including event-only schemas) to wait until cancellations, every `on<Event>`
handler, and operation start registrations through `receipt.revision` have
finished. It returns ``FlushResult/processed``, or ``FlushResult/foreignOwner``
for another owner's receipt. `Task.yield()` gives no flush barrier.

Because handlers run outside admission while draining, `host.snapshot()` inside
`on<Event>` can already reflect later commits, and a snapshot read or new
subscription immediately after an emitting `send(_:)` can observe the committed
state before that commit's `on<Event>` runs. A handler may read the host or call
`send(_:)`, and any commit it makes drains in commit order without nesting.

## Choose among edges with a router

When several edges share a source and trigger, a router selects among them. It
is a function marked `@Route` that receives the plain source payload and trigger
payload, and returns a generated enum with one case per candidate edge.

```swift
@StateMachine(mode: .shared)
nonisolated enum Session: Sendable {
    struct Active: Sendable { let name: String }
    struct Ended: Sendable { let name: String }

    @Initial case active(Active)
    @Terminal case ended(Ended)

    enum Input: Sendable { case refresh(Bool) }

    @Transition(on: Input.refresh)
    fileprivate static func keep(_ source: Active, _ finish: Bool) -> Active { source }

    @Transition(on: Input.refresh)
    fileprivate static func end(_ source: Active, _ finish: Bool) -> Ended {
        Ended(name: source.name)
    }

    @Route(on: Input.refresh)
    fileprivate static func choose(_ source: Active, _ finish: Bool) -> Route.Choose {
        finish ? .end : .keep
    }
}
```

`Route.Choose` has the cases `.keep` and `.end`, one per candidate edge, and is
`Sendable`, `Equatable`, `Hashable`, and `CaseIterable`. A router may use typed
throws to decline, and `send` reports the failure as a `PreparationRejection`
case named after the router. A router with no candidate edge returns `Never`
and must throw.

A routed input has one public method, named after the `@Route` function, on
`Observed` and on `Owned`, and the candidate edges have no methods of their
own. The method runs the router and then the edge it selects, so a typed call
obeys the router exactly as `send` does. `send(.refresh(true))` goes through
`choose`, which selects `end`, and so does the observed call.

```swift
func finish(_ active: Session.Observed<Session.Active>) -> Session.Prepared {
    active.choose(true)
}
```

The observed method throws the failure type that the router and its candidate
edges share, however many of them throw, and `PreparationRejection` when their
failure types differ. Failures are one only when the macro proves it, so
`Problem`, `Self.Problem`, and an alias of it that the schema declares are one
failure, while an alias declared outside the schema is invisible to the macro
and counts as another type. To keep the method's signature fixed while
candidates change, or to name the common failure explicitly, name it with
`@Route(on: Input.pick, failure: Problem.self)`. The compiler then checks that
the router and every throwing candidate throw that type, whichever owners the
schema generates.

On `Owned`, the method returns the candidates' shared result when the router
cannot throw and every candidate returns one type. Otherwise it returns
`Route.<Router>Result`, with a case for each candidate. When the router throws,
that enum adds `rejected(_:_:)`, which holds the failure and the unchanged
source. Here the candidates return different phases, so `choose` returns
`Route.ChooseResult`.

```swift
func chooseOwned() {
    switch Session.owned(Session.Active(name: "Morning")).choose(true) {
    case .keep(let active):
        active.withValue { print("Still \($0.name)") }
    case .end(let ended):
        ended.withValue { print("Ended \($0.name)") }
    }
}
```

A completion router, declared with `@Route(onSuccess:)` or
`@Route(onFailure:)`, chooses among the completion edges that share a source
phase and an operation's outcome, and may take the request last, labeled
`request:`, as they may. Delivery runs it, and `Owned` offers its method in place
of the candidates' methods. An observation has no completion methods at all, so
the router has none there. A completion router that throws leaves the outcome
retained for reconciliation, as
[Settle completions that do not commit](<doc:HostingAGraph#Settle-completions-that-do-not-commit>)
describes.

### Pass a computed value from a router to its chosen edge

When a `@Route` function inspects state or parses an input to pick a branch, a
candidate `@Transition` that receives only `(source, input)` would have to repeat
that work and invent unreachable fallback values. Instead, any candidate
`@Transition` selected by a `@Route`—for an input or a completion, in `.shared`
or `.isolated` mode—may declare one optional final parameter labeled `routed:` to
receive a typed value directly from the router. Candidates that need no handoff
leave `routed:` out.

```swift
@StateMachine(mode: .isolated, owners: [.owned, .local, .mainActorHost])
public nonisolated enum SortDemo {
    public struct Ready { public let stepInterval: Duration }
    public struct Comparing {
        public let left: Int
        public let right: Int
        public let resolve: () -> Int
        public let stepInterval: Duration
    }
    public struct Finished { public let stepInterval: Duration }

    fileprivate struct ComparisonStep {
        let left: Int
        let right: Int
        let resolve: () -> Int
    }

    @Initial case ready(Ready)
    case comparing(Comparing)
    @Terminal case finished(Finished)

    public enum Input { case step }

    @Operation(activeIn: [Ready.self, Comparing.self])
    public enum StepDelay {}

    @Transition(on: Input.step, starts: [StepDelay.self])
    fileprivate static func start(_ source: Ready) -> Change<Ready, Effect.Start> {
        Change(source, effects: [.stepDelay])
    }

    @Transition(onSuccess: StepDelay.self, starts: [StepDelay.self])
    fileprivate static func presentComparison(
        _ source: Ready,
        routed step: ComparisonStep
    ) -> Change<Comparing, Effect.PresentComparison> {
        Change(
            Comparing(
                left: step.left,
                right: step.right,
                resolve: step.resolve,
                stepInterval: source.stepInterval
            ),
            effects: [.stepDelay]
        )
    }

    @Transition(onSuccess: StepDelay.self)
    fileprivate static func finishFromReady(_ source: Ready) -> Finished {
        Finished(stepInterval: source.stepInterval)
    }

    @Route(onSuccess: StepDelay.self)
    fileprivate static func routeReadyStep(_ source: Ready) -> Route.RouteReadyStep {
        if source.stepInterval > .zero {
            .presentComparison(ComparisonStep(left: 0, right: 1, resolve: { 1 }))
        } else {
            .finishFromReady
        }
    }

    @Transition(onSuccess: StepDelay.self)
    fileprivate static func finishFromComparing(_ source: Comparing) -> Finished {
        Finished(stepInterval: source.stepInterval)
    }
}
```

When at least one candidate takes `routed:`, the generated `Route.<Router>` enum
and dispatch follow these rules:

- `routed:` must be the last parameter, after the source, any unlabeled trigger
  payload, and any `request:` parameter on a completion edge. It may appear at
  most once, and is rejected on `@Route`, `@Restoration`, any transition
  missing a `@Route` in one of its source phases, and `.ownedOnly` schemas
  (which have no `@Route`). It cannot use `inout`, `isolated`, `@autoclosure`,
  an opaque `some` type, or `Never`.
- Each candidate with `routed: T` generates `case <edge>(T)`, stripping
  parameter ownership, `@escaping`, and `sending` while keeping outer
  parentheses on tuple types. Candidates without `routed:` remain bare
  `case <edge>`. Because routed values may be tuples or non-`Sendable` closures
  such as `ComparisonStep` above, `Route.<Router>` omits `Sendable`,
  `Equatable`, `Hashable`, and `CaseIterable`. Routers with no `routed:`
  candidates keep all four conformances unchanged.
- `Route.<Router>` (and any `Route.<Phase>.<Router>` alias) takes the narrower
  of the schema's access and the `@Route` function's access, at least
  `fileprivate`. A `fileprivate @Route` inside a `public` schema can therefore
  hand off a `fileprivate` struct without exposing it in the public module
  interface. When `Route.<Router>` keeps `public` or `package` access, its
  `routed:` types need that access too.
- If any candidate declares explicit ownership (`borrowing`, `consuming`,
  `__shared`, or `__owned`) on `routed:` without `@escaping`, `Route.<Router>`
  is `~Copyable` and generated dispatch consumes the choice value so a router
  can hand off a noncopyable intermediate resource. In `.isolated` mode (for
  any `owners:`, including `[.owned]`), a `sending` `routed:` parameter requires
  a `Sendable` type on Swift 6.4 because `@Route` returns `Route.<Router>`
  without region transfer.
- Two routers with the same name in different phases share `Route.<Router>` only
  when their candidate names, routed type identities, choice access, and
  copyability match. Otherwise each gets its own `Route.<Phase>.<Router>`.
- Public `Owned.<router>` and `Observed.<router>` signatures stay unchanged, and
  candidate methods stay `fileprivate`. `send`, `prepare`, delivery,
  `Owned.<router>`, and `Observed.<router>` run `@Route` once and pass the
  routed value straight to the chosen candidate. Each branch keeps its own
  `starts:`, `cancels:`, `emits:`, `invalidates:`, `throws(...)`, and distinct
  edge ID in `StateMachineGraph` (`formatVersion == 2`). On completion retries,
  capacity retries reuse the already-prepared `Prepared` candidate without
  running `@Route` or the candidate again. Conflict retries under `.retry` and
  explicit `reconcile(id:)` run fresh preparation (`@Route` once, then the
  chosen candidate once). A throwing `@Route` leaves the outcome retained for
  reconciliation.

## Handle fallible edges

An edge may use typed `throws(Failure)`. The generated `Owned` edge returns an
`Advance` that gives back the original owner on rejection. Hosted preparation
through `send` reports the failure as a `PreparationRejection` case named after
the edge, and the observed method throws the failure itself, so only a call
that can fail needs `try`.

```swift
@StateMachine(mode: .shared)
nonisolated enum Rename: Sendable {
    struct Draft: Sendable { let title: String }

    @Initial case draft(Draft)

    enum Input: Sendable { case rename(String) }
    enum RenameFailure: Error, Sendable { case empty }

    @Transition(on: Input.rename)
    fileprivate static func rename(
        _ source: Draft,
        _ title: String
    ) throws(RenameFailure) -> Draft {
        guard !title.isEmpty else { throw .empty }
        return Draft(title: title)
    }
}

@MainActor
func renameDraft() {
    let host = Rename.MainActorHost(Rename.Draft(title: "Notes"))
    do {
        try host.send(.rename(""))
    } catch .preparation(.rename(.empty)) {
        print("A title cannot be empty")
    } catch {
        print("Rename was not accepted: \(error)")
    }
}

@MainActor
func renameObserved(_ draft: Rename.Observed<Rename.Draft>, on host: Rename.MainActorHost) {
    do {
        _ = host.commit(try draft.rename(""))
    } catch {
        print("A title cannot be empty: \(error)")
    }
}
```

## Share edge names across phases

Edges that leave different phases may share a name, as Swift overloads that
differ in their source payload. Two edges or routers that leave one phase may
not. An edge's effect type is always available as `Effect.<Payload>.<Edge>`,
named for its source phase's payload type, and a router's choice type as
`Route.<Payload>.<Router>`. The shorter `Effect.<Edge>` names the same type when
only one edge has the name or every edge of that name starts the same
operations. Here the two `retry` edges start different operations, so each
names its own phase-qualified type.

```swift
@StateMachine(mode: .shared)
nonisolated enum Editor: Sendable {
    struct Draft: Sendable { var text = "" }
    struct Failed: Sendable { let text: String }
    struct Saving: Sendable { let text: String }

    @Initial case draft(Draft = Draft())
    case failed(Failed)
    case saving(Saving)

    enum Input: Sendable { case retry, close }
    enum SaveFailure: Error, Sendable { case offline }

    @Operation(activeIn: [Saving.self])
    enum Save {
        typealias Input = String
        typealias Failure = SaveFailure
    }

    @Operation(activeIn: [Saving.self])
    enum Audit {}

    @Transition(on: Input.retry, starts: [Save.self])
    fileprivate static func retry(_ source: Draft) -> Change<Saving, Effect.Draft.Retry> {
        Change(Saving(text: source.text), effects: [.save(source.text)])
    }

    @Transition(on: Input.retry, starts: [Save.self, Audit.self])
    fileprivate static func retry(_ source: Failed) -> Change<Saving, Effect.Failed.Retry> {
        Change(Saving(text: source.text), effects: [.save(source.text), .audit])
    }

    @Transition(from: [Draft.self, Failed.self], on: Input.close)
    fileprivate static func close() -> Draft { Draft() }

    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Saving) -> Draft {
        Draft(text: source.text)
    }

    @Transition(onFailure: Save.self)
    fileprivate static func failed(_ source: Saving, _ failure: Save.Failure) -> Failed {
        Failed(text: source.text)
    }

    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: Saving) -> Saving { source }
}
```

`close` uses `@Transition(from:on:)`, which declares one edge from each listed
phase. Its function takes no source parameter, only the input's payload when
there is one, and each listed phase gains the edge exactly as if it were
declared once per phase. When such an edge starts operations, its one effect
type is the one that every listed phase's `Effect.<Payload>.<Edge>` names. A
completion edge always names its source, so it cannot list `from:`.

### Reuse a source-phase list

When several edges share the same source phases, declare an empty, nongeneric
nested `enum` directly inside the schema and attach `@PhaseSet([…])` with the
phase payload types in order. Reference the set from `@Transition(from:)` as
`<Set>.self` on an input edge or an `.ownedOnly` direct edge.

```swift
@StateMachine(mode: .shared)
nonisolated enum Document: Sendable {
    struct Draft: Sendable { let title: String }
    struct Review: Sendable { let title: String }
    struct Archived: Sendable { let title: String }

    @Initial case draft(Draft)
    case review(Review)
    @Terminal case archived(Archived)

    enum Input: Sendable { case submit, revise(String), archive }

    @PhaseSet([Draft.self, Review.self])
    fileprivate enum Active {}

    @Transition(on: Input.submit)
    fileprivate static func submit(_ source: Draft) -> Review {
        Review(title: source.title)
    }

    @Transition(from: Active.self, on: Input.revise)
    fileprivate static func revise(_ title: String) -> Draft {
        Draft(title: title)
    }

    @Transition(from: Active.self, on: Input.archive)
    fileprivate static func archive() -> Archived {
        Archived(title: "Archived")
    }
}
```

A `@PhaseSet` expands to the exact ordered list of phases it names, producing
the same generated methods, `Effect` types, routing, and `StateMachineGraph` as
writing that list inline, with no runtime type or storage overhead. Any phase
omitted from the set, such as `Archived` above or a phase added later, stays
excluded unless listed. A set may be declared before or after the transitions
that name it, and an unused set is still checked. Because generated code never
spells a `@PhaseSet` enum's name, a `private` or `fileprivate` set works inside
a `public` or `package` schema without appearing in its module interface.

A `@PhaseSet` must be an empty nested enum directly inside the schema, named
with an ordinary Swift identifier in Unicode Normalization Form C, and may not
contain `#if` clauses or conditional attributes. Its list accepts only distinct
`<Phase payload>.self` references declared in the same schema: nested sets,
expressions, qualified names, mixed arrays such as `from: [Draft.self, Active.self]`,
cross-file sets, and completion edges with `from:` are unsupported. Write
`@StateMachine.PhaseSet` or `@StateMachine::PhaseSet` when the schema declares
its own type named `PhaseSet`.

### Share state-dependent edges across phases with a generic source

Parameterless `@Transition(from:)` works when the destination needs nothing from
the source phase. When several phases share fields or need a same-phase update
that preserves phase-only data, declare a single generic type parameter
`<Source>` (with an optional protocol constraint or `where` clause) on
`@Transition(from: [...], ...)` or `@Transition(from: Set.self, ...)` and take
`_ source: Source` as the first parameter.

```swift
nonisolated protocol SelectionCarrying {
    var selectedID: Int? { get set }
}

@StateMachine(mode: .shared, owners: [.owned, .local, .mainActorHost])
nonisolated enum Navigation: Sendable, Equatable {
    struct Browsing: Sendable, Equatable, SelectionCarrying {
        var selectedID: Int? = nil
    }
    struct Confirming: Sendable, Equatable, SelectionCarrying {
        let confirmation: String
        var selectedID: Int?
    }
    struct PresentingSheet: Sendable, Equatable, SelectionCarrying {
        var selectedID: Int?
        let sheet: String
    }

    @Initial case browsing(Browsing = Browsing())
    case confirming(Confirming)
    case presentingSheet(PresentingSheet)

    @PhaseSet([Browsing.self, Confirming.self, PresentingSheet.self])
    fileprivate enum AllPhases {}

    enum Input: Sendable {
        case select(Int?)
        case confirm(String)
        case presentSheet(String)
        case dismiss
    }

    // Same-phase update: retains `confirmation` in Confirming and `sheet` in PresentingSheet.
    @Transition(from: AllPhases.self, on: Input.select)
    fileprivate static func select<Source: SelectionCarrying>(
        _ source: Source,
        _ id: Int?
    ) -> Source {
        var next = source
        next.selectedID = id
        return next
    }

    // Fixed destination reading shared protocol fields.
    @Transition(from: [Browsing.self, Confirming.self], on: Input.presentSheet)
    fileprivate static func presentSheet<Source: SelectionCarrying>(
        _ source: Source,
        _ sheet: String
    ) -> PresentingSheet {
        PresentingSheet(selectedID: source.selectedID, sheet: sheet)
    }

    @Transition(on: Input.confirm)
    fileprivate static func confirm(_ source: Browsing, _ confirmation: String) -> Confirming {
        Confirming(confirmation: confirmation, selectedID: source.selectedID)
    }

    @Transition(from: [Confirming.self, PresentingSheet.self], on: Input.dismiss)
    fileprivate static func dismiss<Source: SelectionCarrying>(_ source: Source) -> Browsing {
        Browsing(selectedID: source.selectedID)
    }
}
```

Each phase listed in `from:` expands independently in authored order:

- Declare exactly one generic type parameter (no multiple parameters `<S, T>`
  and no parameter packs `each T`). The first parameter must be unlabeled and
  typed as that generic parameter, using the mode's source ownership rules:
  plain or `borrowing`/`__shared` in `.shared` and `.isolated`, and
  `consuming`/`__owned` in `.ownedOnly`. Any trigger payload or final `routed:`
  parameter cannot reference `Source`.
- Return either a fixed phase (`Dest`, `Change<Dest, Effect.<Edge>>`, or in
  `.ownedOnly` `Advance<Source, Dest, Effect, Failure>`) or the source phase
  itself (`Source`, `Change<Source, Effect.<Edge>>`, or in `.ownedOnly`
  `Advance<Source, Source, Effect, Failure>`). Returning `Source` creates one
  self-loop edge per phase in `from:`—such as `browsing.select -> browsing`,
  `confirming.select -> confirming`, and
  `presentingSheet.select -> presentingSheet`—preserving every phase-only field
  and static phase identity.
- Each expanded phase gets its own concrete `Owned` and `Observed` method,
  concrete `StateMachineGraph` edge, concrete witnesses, and per-phase
  deprecation requirements when marked `@available(*, deprecated)`. Swift
  verifies protocol conformances for each concrete phase in `from:` at the
  generated calls, and the macro validates every operation in `starts:` against
  every expanded destination phase.
- Generic `from:` transitions work on input edges in all modes and on
  `.ownedOnly` direct edges (which take no trigger payload when `on:` is
  omitted). They also compose with a final `routed:` parameter when every source
  phase in `from:` has a `@Route` for that trigger. Completion edges
  (`onSuccess:` / `onFailure:`) and `@Route` functions remain single-source.

When edges of one name throw different failure types, their
`PreparationRejection` cases are prefixed with the source phase, as in
`draftEdit` and `savingEdit`. An edge or router whose generated type would have
the schema's own name is rejected, because generated code inside `Effect` and
`Route` names the schema's types through that name. An edge named `effect`,
`type`, or `protocol` that starts, cancels, or emits is rejected too, because
its type would be `Effect.Effect`, which would hide `Effect` inside it, or
`Effect.Type` or `Effect.Protocol`, which name its metatypes.

## Declare a graph of unique resources

An `ownedOnly` schema's payloads may be noncopyable resources, and it generates
only `Owned`. Each edge consumes its source with `consuming`. If it can fail, it
returns `Advance<Source, Destination, Effect, Failure>`, where the effect
argument is `Never` or `Effect.<Edge>`, so a rejection can return the original
resource. An infallible `ownedOnly` edge returns the destination or a `Change`.
A consuming function that throws after losing its predecessor cannot provide
that recovery contract.

```swift
@StateMachine(mode: .ownedOnly)
nonisolated enum Seal: ~Copyable {
    struct Open: ~Copyable { let handle: Int32 }
    struct Sealed: ~Copyable { let handle: Int32 }

    @Initial case open(Open)
    @Terminal case sealed(Sealed)

    enum Input { case seal(Bool) }
    enum SealFailure: Error { case incomplete }

    @Transition(on: Input.seal)
    fileprivate static func seal(
        _ source: consuming Open,
        _ complete: Bool
    ) -> Advance<Open, Sealed, Never, SealFailure> {
        guard complete else { return .rejected(.incomplete, source) }
        return .advanced(Sealed(handle: source.handle), effects: [])
    }
}

func sealUpload() {
    switch Seal.owned(Seal.Open(handle: 3)).seal(false) {
    case .advanced(let sealed, _):
        sealed.withValue { print("Sealed \($0.handle)") }
    case .rejected(let failure, let open):
        // The original owner comes back and can be advanced again.
        open.withValue { print("\(failure): still holding \($0.handle)") }
    }
}
```

An input can carry a noncopyable resource too. Declare `enum Input: ~Copyable`
and take the payload `consuming` or `borrowing` in the edge, which the `Owned`
verb repeats, so the verb moves the resource in or only lends it.

```swift
@StateMachine(mode: .ownedOnly)
nonisolated enum Dock: ~Copyable {
    struct Cable: ~Copyable { let port: Int }
    struct Empty {}
    struct Plugged: ~Copyable { let cable: Cable }

    @Initial case empty(Empty)
    @Terminal case plugged(Plugged)

    enum Input: ~Copyable { case plug(Cable) }

    @Transition(on: Input.plug)
    fileprivate static func plug(_ source: consuming Empty, _ cable: consuming Cable) -> Plugged {
        Plugged(cable: cable)
    }
}

func connect() {
    let plugged = Dock.owned(Dock.Empty()).plug(Dock.Cable(port: 2))
    plugged.withValue { print("Plugged into port \($0.cable.port)") }
}
```

Only `Owned` passes such a value on without copying it, so a noncopyable
`Input`, or a noncopyable schema, in a schema that generates any other owner is
an error at its declaration, and an operation's `Output` that a `Local` or
managed host delivers must be copyable.

An `ownedOnly` schema has no routing surface, so it may omit `Input`, and an
edge may omit its trigger. Such an edge, declared with `@Transition` or
`@Transition(starts:)`, takes only its source and is called directly as the
owned method named after it.

```swift
@StateMachine(mode: .ownedOnly)
nonisolated enum Ticket: ~Copyable {
    struct Valid: ~Copyable { let seat: Int }
    struct Used: ~Copyable { let seat: Int }

    @Initial case valid(Valid)
    @Terminal case used(Used)

    @Transition
    fileprivate static func scan(_ source: consuming Valid) -> Used { Used(seat: source.seat) }
}

func board() {
    let used = Ticket.owned(Ticket.Valid(seat: 12)).scan()
    used.withValue { print("Seat \($0.seat) boarded") }
}
```

## Satisfy the graph checks

The macro checks the graph's structure on every build and reports each problem
as an error at the part of the declaration at fault, such as a phase case's
name, an operation namespace's name, an edge's name or source parameter, or an
`activeIn:` element. Because it reads only declarations, an edge counts as soon
as its source is reachable and, for a completion edge, its operation may be
active there. The macro cannot know whether a function throws, which edge a
router chooses, or which effects an edge returns, so an error means that no
declared path exists. The initial phase, and each phase that `@Restoration` can
restore, is an entrance with no work running. The table below lists each check
and how to satisfy it.

| Error | What to change |
| --- | --- |
| `Phase 'archived' is unreachable from the initial phase 'draft'` | Declare a transition into the phase, make it restorable, or remove it. |
| `Phase 'approved' has no outgoing transitions` | Mark it `@Terminal` if the graph ends there, or declare a transition from it. An edge back to the same phase counts. |
| `Terminal phase 'approved' cannot have an outgoing transition` | Remove `@Terminal`, or remove the edge or router. |
| `Operation 'Sync' cannot be active in terminal phase 'done'` | Remove the phase from the operation's `activeIn` or scope, or remove `@Terminal`. |
| `Operation 'Sync' is never started` | List it in the `starts:` of a transition the graph can take, or remove it. |
| `Operation 'Sync' can start but never complete` | Declare a completion edge for it in a phase where it can be active, or give its completion router an edge to choose. |
| `Operation 'Sync' can start but its failure is never accepted` | Declare an `onFailure:` edge in a phase where it can be active, or give its failure router an edge to choose. The same holds for a success. |
| `Completion edge 'synced' can never fire` | Start the operation on a transition into that phase, or remove the phase from those where the operation is active. |
| `Completion router 'screen' can never run` | The same, for a router. |
| `Operation 'Sync' cannot fail: its Failure is Never` | Remove the edge or router, or declare the `Failure` the operation reports. |
| `Operation 'Sync' never succeeds: its Output is Never` | Remove the success edge or router, because an operation whose `Output` is `Never` ends only by failing. |
| `Operation 'Sync' can never finish` | Declare an `Output`, or a `Failure` the driver returns when it stops. With both `Never`, the driver could never return. |
| `Input case 'pay' carries Never` | Remove the case or give it an inhabited payload, because no input can carry `Never`. |
| `Event 'Tracked' carries Never` | Remove the event or give it an inhabited payload, because no transition can emit it. |
| `The name 'café' is not in Unicode Normalization Form C` | Write each accented character as one character, such as `é` for an `e` followed by a combining accent, where the name is declared and wherever it is used, or spell the name with other characters. To name a declaration outside the schema that you cannot rename, declare an alias of it with a composed name outside the schema. |
| `The macro cannot read this schema in full` | Fix the syntax errors the compiler reports, or nest the schema less deeply. The Swift parser that runs the macro reads 20 levels of nesting when SwiftSyntax is a debug build, which a package builds when one of its test targets depends on SwiftSyntax, and 256 otherwise. |
| `Type alias 'Item' names itself` | Give the alias a type that does not depend on it, directly or through other aliases. |
| `Move this '#if' outside the schema or into a function body` | Move the condition around the whole schema, into the body of a function, or into an extension of the schema, as [Know what the macro supports](<doc:DeclaringAGraph#Know-what-the-macro-supports>) shows. The macro reads every member of the schema, `Input`, `Scope`, and its namespaces without knowing which clause is active. |
| `Move this '#if' out of the declaration's attributes` | Write the attributes without a condition, or declare the member once per platform in separate schemas. |
| `Remove '@MainActor'` | Remove the attribute from the edge, router, or restoration function, which takes only `@discardableResult`, `@inlinable`, `@inline`, `@usableFromInline`, and `@available(*, deprecated)`. To confine an owner to the main actor, generate `.mainActorHost`. |
| `Remove '@available' and give the schema this availability instead` | Put the `@available` on the schema, and on the types it declares that need it, rather than on the function. A deprecation on every platform, `@available(*, deprecated)` with at most one `message:` and one `renamed:` in any order, is the one form a function keeps. |
| `Remove 'renamed:': the restoring initializers and resets this deprecation marks keep their names` | Describe the replacement in `message:`. A restoration function's deprecation marks `init(restoring:)` and `reset(restoring:)`, which no rename applies to. |
| `Write the bare name of the replacement edge in 'renamed:'` | Name the replacement edge, or router, by its function's name alone, such as `"submit"`, rather than `"Flow.submit(_:)"`. It must be another edge, or router, whose generated method exists wherever the deprecated one's does, meaning an edge that no router chooses, and an input edge when the deprecated one is an input edge of an observing owner. |
| `Remove 'mutating'` | An authored function is `static`, with an access modifier and `nonisolated` as its only other modifiers. |
| `Use .parallel(limit: N) with a positive integer literal` | Write the limit as an integer literal of at least 1, in any base Swift accepts, such as `8`, `1_000`, or `0x10`. |
| `Declare 'Draft' public` | Give the named type or alias the schema's access. |
| `This schema declares 700 phases; the macro accepts at most 600` | Split the graph into several schemas. The limits are 600 phases, 512 input cases, 256 operations, and 512 effect cases, counting each operation, two for each operation an edge cancels, and each event. |
| `'Flow' names another type inside the schema` | Rename the member of the schema's name that an extension of the schema declares, because generated code names the schema by its name. |
| `The schema's inheritance clause names Equatable` | Write `Swift::Equatable`, or `Swift::Hashable`, in the inheritance clause, or name another protocol of that name through its module. |
| `type 'Item' does not conform to the 'Sendable' protocol`, at a generated witness | An observing owner keeps the value it passes to `sending`. Take the payload or request as a plain, borrowing, or consuming parameter, give it a `Sendable` type, or, for an edge that alone consumes it, list only `.owned` in `owners:`. A request is `Sendable` when its input is. |
| `An Owned router takes this value as sending`, at a generated check | The router gives the value away before the edge it selects takes it. Take the value without `sending` in the router, or give it a `Sendable` type. |
| `One edge an Owned router may select takes this value as sending and another takes it without`, at a generated check | Take the value the same way in every edge the router may select, or give it a `Sendable` type. |
| `An Owned router reads this value with its source phase`, or `with the other value it passes on`, at a generated check | Borrowing the value in the router joins it with the source phase and the other value the router reads, so an edge that sends it carries them too. Make the value, or what it is joined with, `Sendable`, take the value without `sending` in every edge the router may select, or leave the request out of the router. |
| `This router takes its payload as its own`, at a generated check | The edge the router selects still takes the noncopyable payload, so take it `borrowing` in the router. Swift also reports that the generated method's parameter must specify ownership. |
| `Input is noncopyable, which only Owned supports`, or `The schema is noncopyable` | List only `.owned` in `owners:`, or make the type copyable, because every other owner keeps or publishes copies. |
| `This type nests too deeply, or reaches its type through too many aliases` | Spell the type directly or through fewer aliases. A chain of aliases that each name the next never reaches this bound, whereas nesting through structure, such as an array of an array at every level, does. |
| `Operation 'Sync' has no onSuccess: edge or router, so the macro reads its Output as Never`, at a generated check | Declare a success edge or router in each phase where the operation may run, or declare its `Output` as `Never`. The same holds for `onFailure:` and `Failure`. |
| `Operation 'Sync' succeeds without output, as its onSuccess: edges and routers take none`, at a generated check | Take the output after the source in the success edges and routers, or declare the `Output` as `Void`. |
| `Operation 'Sync' succeeds with output, so its success edge takes the output, unlabeled, after the source` | Take the output after the source, and the request, if any, last, labeled `request:`. |
| `Operation 'Sync' succeeds without output, so its success edge takes no output parameter` | Remove the unlabeled parameter, and take the request, if any, labeled `request:` right after the source. |
| `'_stateMachineTakesOutput' is unavailable`, or `'_stateMachineTakesFailure' is unavailable`, at a generated witness | The unlabeled parameter after the source is the outcome, so its type must be exactly the operation's `Output` or `Failure`. To take the request there, label it `request:`. |
| `'_stateMachineTakesRequest' is unavailable`, at a generated witness | The parameter labeled `request:` takes the operation's request, so spell its type `<Operation>Request` or an alias of it. Take any other value unlabeled. |
| `Take the request last, labeled request:` | Move the `request:` parameter after the source and the output or failure. |
| `cannot assign value of type '_TriggerPayloadMatchesDeclaration<Int?>'`, at a generated witness | Take the exact type the `Input` case carries, because no optional promotion, existential, function, tuple-label, or class conversion applies to a payload. |

An operation stays active along an edge whose destination keeps every scope
the operation holds and that invalidates none of them. The checks follow each
path with the outstanding executions of every operation together, so work that
one path starts never counts on a path that did not start it. They count
executions where the declarations bound them, tracking one for `.latest` and
`.rejectWhenActive`, and up to the limit for `.parallel(limit:)`. Each
completion retires one, and an edge that starts the operation may add as many
as its admission allows. A keyed operation holds independent work for every
key, so the completion of one key never retires another's. So a completion
edge is reported when no path that starts its operation reaches the edge's
source phase with work still outstanding, for example when the only way into
that phase is the operation's own completion, when a `.parallel(limit: 2)`
operation started once would need a third completion to get there, or when the
only path into the phase consumes another operation's work that the paths
holding this one never started.

The checks approximate in three ways, each of which can only accept more
graphs. A keyed operation and a `.parallel(limit:)` above 32 count as
unbounded, so no completion retires their last execution, even when the key
type or the limit allows fewer executions than a path needs. A graph whose
paths combine into more work states than the macro explores within a fixed
budget is checked per operation instead, which tracks each operation's work
apart from the others' and so can credit one path with work another started.
A schema that generates only `Owned` holds no work, because each completion
method needs only its source phase, so its checks cover phase paths and
routing without counting work. Passing the checks shows a declared path under
these rules, though it does not show that a run takes it or that every outcome
an accepting edge names can arrive there. A phase whose only edges lead back to
itself, such as `Gauge.ready`, is a legitimate long-lived phase, and a declared
edge that is never taken at run time is not diagnosed. To see the structure the
checks read, render the graph as <doc:ExportingAGraph> shows.

Every phase where an operation can be active needs a completion edge or router
for each of its outcomes, and somewhere among those phases an edge must accept
each one. A router that chooses no edge, `throws(...) -> Never`, refuses an
outcome in its phase. `Local` or a managed host then retains the outcome as a
pending completion that needs reconciliation, until `reconcile(id:)` admits it
in a phase that accepts it or `discardPending(id:)` drops it.

## Choose the owners to generate

Each mode generates every owner it supports, and a schema can name the ones it
needs instead.

| Mode | Phase data | Owners it supports |
| --- | --- | --- |
| `.shared` | `Copyable` and `Sendable` | `Owned`, `Local`, `Shared`, `ActorHost`, `MainActorHost`, `IsolatedHost` |
| `.isolated` | `Copyable`, confined to one actor | `Owned`, `Local`, `MainActorHost`, `IsolatedHost` |
| `.ownedOnly` | May be `~Copyable` | `Owned` |

In `shared` mode, phase data, inputs, effects, and operation outcomes must meet
checked `Sendable` requirements as well as the domain's value-semantics
contract. In `isolated` mode, copyable data stays within its permitted actor
without becoming `Sendable`. The enum stays `nonisolated`, and its payloads and
inputs may say `~Sendable`. In `ownedOnly` mode, phase payloads may be
noncopyable resources, which receive no copyable snapshots or shared storage.

`@StateMachine(mode: .shared, owners: [.local, .mainActorHost])` generates only
`Local` and `MainActorHost`, and only the support they use. A graph driven by
one `Local` has no driver bundle or shutdown vocabulary, and a graph without
`Owned` has no owned router results. The cases of ``StateMachineOwner`` are
`.owned`, `.local`, `.shared`, `.actorHost`, `.mainActorHost`, and
`.isolatedHost`. An empty list, a repeated owner, an owner the mode does not
support, and a `@Restoration` function in a graph that lists only `.owned` are
errors. <doc:HostingAGraph> explains how to choose among the owners.

## Restore saved data

A `shared` or `isolated` schema generates `Restoration`, an enum with one case
for each phase in which no operation is active. A schema may declare one
function marked `@Restoration` that validates saved data into one of those
cases. Declaring it gives every owner except `Owned` an `init(restoring:)` and a
`reset(restoring:)`, each with fresh authority and no outstanding work.
`@Restoration(allows:)` adds phases in which an operation can be active, and
`@Restoration(only:)` names the restorable phases exactly. <doc:Persistence>
covers the function, its phases, forking, and archives.

## Know what the macro supports

### Supported shapes and conditional compilation

Inputs have zero or one unlabeled payload. Every phase case has one unlabeled
payload, whose distinct struct or enum is declared directly inside the schema.
The macro rejects an input, key, or payload that is `Never`. It does not detect
other types without values, such as an enum without cases, so an operation
whose `Input` is one can never start. Fields can use imported types and nested
generic containers. Phase aliases, reusing a payload type for several phases,
generic schema or phase payload declarations, async edges, untyped throws,
`inout` sources, and generic edge functions other than single-parameter `from:`
transitions are unsupported. Generic `@StateMachine` schemas remain unsupported
so every graph, its coverage report, and its generated owners stay concrete.
Wrap a concrete schema in a generic helper or view type when callers need
generic input handling. A source parameter
is plain or `borrowing`, or `consuming` in `.ownedOnly`, and the underscored
`__shared` and `__owned` read as `borrowing` and `consuming`. Parentheses
change no type the graph reads, so `(Draft)`, `((Draft))`, and `(Self).Draft`
are the payload `Draft` as a phase case's payload, a source, or a destination,
and `(Route).Choose` and `(Change<Done, Effect.Finish>)` are the router's
choice and the edge's change.

Keep declarations inside the schema, because the macro does not discover
extensions or scan other files. It reads a schema only once the Swift parser
that runs it has read all of it, so a schema with a syntax error, or one nested
deeper than that parser reads, is refused as a whole rather than read in part.
It also cannot tell which clause of `#if` a build takes, so it refuses `#if`
among the members of the schema, `Input`, `Scope`, and each operation and event
namespace, and in the attributes of any of those members. It refuses `#if` inside
a `@PhaseSet` enum and its attributes for the same reason. A payload's own
members, the bodies of functions, and extensions of the schema may still use
`#if`. A helper that exists on one platform belongs in an extension, which the
macro does not read.

```swift
extension Approval {
    #if os(macOS)
    static func revealInFinder(_ draft: Draft) { /* ... */ }
    #endif
}
```

A graph whose inputs, phases, or transitions differ by platform is a separate
schema on each platform, each a complete graph of its own.

```swift
#if os(macOS)
@StateMachine(mode: .shared)
nonisolated enum Export: Sendable {
    struct Idle: Sendable {}
    struct Revealed: Sendable {}
    @Initial case idle(Idle)
    @Terminal case revealed(Revealed)
    enum Input: Sendable { case reveal }
    @Transition(on: Input.reveal)
    static func reveal(_ source: Idle) -> Revealed { Revealed() }
}
#else
@StateMachine(mode: .shared)
nonisolated enum Export: Sendable {
    struct Idle: Sendable {}
    struct Posted: Sendable {}
    @Initial case idle(Idle)
    @Terminal case posted(Posted)
    enum Input: Sendable { case post }
    @Transition(on: Input.post)
    static func post(_ source: Idle) -> Posted { Posted() }
}
#endif
```

### Attributes, availability, and deprecation

Generated members call edges, routers, and restoration functions from
nonisolated code and from every owner, and they have the schema's own
availability and no other. An authored function therefore takes only the
macro's markers, Swift's `@discardableResult`, `@inlinable`, `@inline`, and
`@usableFromInline`, and a deprecation on every platform, while any other
attribute, which could isolate it to a global actor such as `@MainActor`,
whatever its capitalization, or change how a call to it is checked, is refused. Availability
belongs on the schema. Apart from a deprecation on every platform, described
below, the macro cannot compare an `@available` on a function with the client's
deployment target, so it refuses `@available` and `@backDeployed` on the
function and asks for them on the schema, whose generated members then share
them, as do payload types that carry the same annotation. That includes
`@available(macOS 14, *)`, `unavailable`, `obsoleted:`, and a platform's
`deprecated:`, such as `@available(macOS, deprecated: 14)`. Beside `static`, an
authored function's only modifiers are its access and `nonisolated`.

An edge, router, or restoration function can be deprecated on every platform
with `@available(*, deprecated)`, which may add one `message:` and one
`renamed:`, in any order after `*`. The generated public members named for the
function repeat the attribute as written, covering an edge's `Owned` method
(and, for an input edge, its `Observed` method), a router's `Owned` and
`Observed` methods, and every `init(restoring:)` and `reset(restoring:)` for a
restoration function. A caller of one of those members gets Swift's deprecation
warning, with the rename as its fix-it, while sending an input, delivering a
completion, and creating an owner name nothing deprecated, and the schema's own
generated code calls the function without a warning, so a module that treats
warnings as errors still builds.

An edge that a router chooses has no public method of its own, so its
deprecation marks no generated member. Swift's fix-it replaces the name of the
deprecated generated method with the rename, so `renamed:` takes only the bare
name of another edge, or of another router for a router, that has a generated
method wherever the deprecated one has. A qualified or labeled name, such as
`"Flow.submit(_:)"`, would name the file-private authored function and is
refused at its string. The restoring initializers and resets keep their names,
so a restoration function's deprecation takes `message:` without `renamed:`. A
deprecation on the schema itself deprecates everything it generates.

```swift
@available(*, deprecated, renamed: "submit")
@Transition(on: Input.post)
static func post(_ source: Draft) -> Sent { Sent() }

@Transition(on: Input.submit)
static func submit(_ source: Draft) -> Sent { Sent() }
```

Here `owned.post()` warns that `post` is renamed to `submit`, and offers to
call `owned.submit()`, while `try flow.send(.post)` builds without a warning.

### Visibility, identifiers, and Unicode normalization

A `public` or `package` schema generates members of its access that name its
phase payloads, `Input`, its operation and event namespaces with their aliases,
and the types that its payloads, outputs, keys, requests, saved data, and
failures spell. It also checks `routed:` types when the router's choice enum
itself keeps that access, while a `fileprivate` or `internal` `@Route` narrows
`Route.<Router>` so its `routed:` types stay private to that access. Each declaration of the schema that one of those spellings
names, as Swift resolves the spelling where it is written, needs that access
too, such as `Notes` and `Notes.Detail` for an edge that takes a `Notes.Detail`,
and `Notes.Detail` again for `N.Detail` written through `typealias N = Notes`.
A generic type's arguments do not change which declaration its member is, so
`Box<Int>.Detail`, and `N.Detail` through `typealias N = Box<Int>`, need
`Box`'s `Detail` to have that access. A helper that none of them names may keep
less, even when it shares a name with one that does, and so may a helper named
like a built-in attribute, because `Sendable` in `@Sendable () -> Int` names
Swift's attribute rather than a type. The macro cannot see the access of a type
declared outside the schema, so Swift reports one that is less visible at the
generated declaration that names it. A limit such as `.parallel(limit: 8)` is
an integer literal, read as Swift reads one, so `1_000` and `0x10` are the
limits they spell.

Schema, case, operation, and edge names are Swift identifiers that need no
backticks. Redundant backticks are allowed and change no name, but a keyword
such as `default`, which needs them, cannot name a declaration the macro reads,
because generated code spells each name bare. Redundant backticks change no
attribute name or argument label either, so `discardableResult` and `escaping`
written in backticks after `@`, and the label `limit` of `.parallel(limit:)`
written in backticks, mean what they mean without them. Only `@available` is
read with its name bare, because Swift's parser reads the arguments of an
escaped one as ordinary expressions.

Write every name the macro reads in Unicode Normalization Form C, as most
editors and keyboards do, so an accented letter such as `é` is a single
composed character rather than an `e` followed by a combining accent. Swift
tells two names apart by their bytes, so it reads those two spellings as two
names, while the macro compares names as text, which would take them for one.
The macro therefore refuses a name that is not in that form anywhere it reads
one, including declarations, signatures, attributes and their arguments,
default values, and the initial phase's default. It offers no fix-it, because
the composed spelling is another name to Swift, which may name another
declaration or none. A name that composes to something that is no longer a
name, such as one that begins with U+1FEF GREEK VARIA, which composes to a
backtick, needs other characters. The bodies of functions, initializers, and
accessors, and closures, are code the macro never reads, so a name there, such
as that of an imported declaration a helper calls, may be written in any form,
as may the contents of string literals. A closure inside an attribute, a type,
or a phase case's default is read with it.

### Size limits and reserved names

The package compiles three stress graphs of 128 phases on every change, one
with 512 edges over four inputs, one where each of 512 edges has its own input,
and one with 32 operations. The macro accepts at most 600 phases, 512 input
cases, 256 operations, and 512 effect cases, counting each operation, two for
each operation an edge cancels, and each event. Generated code switches over
each of those enums, and Swift checks such a switch over about 630 cases that
carry values only within a fixed budget. The compiler's time also grows faster
than the schema, so 256 operations for every owner compile in seconds where 512
take more than a minute. A larger schema is refused with the limit it passes.

Generated member names are reserved, and which names are reserved depends on
what the schema generates. A schema that lists only `.local` may declare its
own type named `Shared` or `Configuration`, and a schema without a router that
chooses an edge may declare its own `Route`.

#### Unconditional reservations (every `@StateMachine`)

- `Change` and `Advance` are the short result types spelled by authored transitions.
- `Phase` is the generic parameter of `Owned` and `Observed`.
- `Effect` is the generated effect enum.
- `graph` is reserved at the signature of the generated `static let graph`, so a
  static property, a type, a case without a payload, or a synchronous static
  method without parameters of that name is diagnosed, while an instance member,
  a phase case (which carries a payload), an `async` static method such as
  `static func graph() async -> Int`, and a static method that takes arguments,
  such as `static func graph(_ index: Int)`, are other declarations.

#### Contextual reservations (only when the schema generates them)

- Generating `.owned` reserves `Owned` and `owned`.
- Generating any observing owner (`.local`, `.shared`, `.actorHost`,
  `.mainActorHost`, or `.isolatedHost`) reserves `Observed`, `Snapshot`,
  `Prepared`, `PreparationRejection`, `CommitResult`, `CommitRejection`,
  `Receipt`, `SendRejection`, `Restoration`, and `prepare`.
- An observing owner with a throwing `@Restoration` reserves `ResetRejection`.
- An observing owner with one or more `@Operation` declarations reserves
  `Completion`, `PendingStatus`, `PendingCompletionID`, `PendingCompletion`,
  `ReconcileResult`, and `DiscardResult`.
- Generating `.local` reserves `Local`, `LocalConfiguration`, and
  `InitialPhase`.
- Generating `.local` with `@Restoration` reserves `RestorationArchive` and
  `RestorationRejection`.
- Generating `.local` with one or more `@Operation` declarations reserves
  `ExecutionHandle`, `ExecutionDisposition`, `AcknowledgmentResult`, and
  `DeliveryResult`.
- Generating `.local` with one or more `@Operation` or `@Event` declarations
  reserves `Command` and `CommandBatch`.
- Generating any managed owner (`.shared`, `.actorHost`, `.mainActorHost`, or
  `.isolatedHost`) reserves `Configuration`, `SubscriptionFailure`,
  `ShutdownResult`, `ShutdownDiagnostics`, `FlushResult`, and `Host`.
- A managed owner with one or more `@Operation` declarations reserves
  `CompletionPolicy`.
- `.shared` mode with any managed owner reserves `Snapshots`, plus
  `PendingCompletionUpdates` when the schema declares an `@Operation`.
- `.isolated` mode with `.mainActorHost` reserves `MainActorSnapshots`, plus
  `PendingCompletionUpdates` when the schema declares an `@Operation`.
- `.isolated` mode with `.isolatedHost` reserves `IsolatedSnapshots`, plus
  `IsolatedPendingCompletionUpdates` when the schema declares an `@Operation`.
- Generating `.shared` reserves `Shared`, `Subscription`, plus `Drivers` when
  the schema declares an `@Operation`.
- Generating `.actorHost` reserves `ActorHost`, `Subscription`, plus `Drivers`
  when the schema declares an `@Operation`.
- Generating `.mainActorHost` reserves `MainActorHost`,
  `MainActorSubscription`, plus `MainActorDrivers` when the schema declares an
  `@Operation`.
- Generating `.isolatedHost` reserves `IsolatedHost`, `Owner`,
  `IsolatedSubscription`, plus `Drivers` when the schema declares an
  `@Operation`.
- Declaring one or more `@Route` functions with candidate edges reserves
  `Route`.

#### Operation-derived, schema-name, companion, and implementation reservations

- For each `@Operation` named `<Op>`, the expansion declares `<Op>Request` (when
  the operation has a `Key` or takes an `Input`), `<Op>Completion` (with any
  observing owner), `<Op>Work` (with `.local`), and `_<Op>Work` (with `.local`
  when `Output` is not `Never`). An operation cannot be named so any of those
  names collides with a fixed generated name above.
- The schema's own name cannot be any reserved name above, cannot be shadowed by
  a direct nested type or type alias of the same name, and—when the schema has
  an observing owner and at least one `@Operation`—cannot be `Outcome` or
  `Rejection`, which `PendingCompletion` declares.
- An edge with effects cannot be named `effect`, `type`, `protocol`, or match
  the schema's name. A choosing router cannot be named `route`, `type`,
  `protocol`, or match the schema's name, and when `.owned` is generated and
  the router needs an owned result enum, its `<Router>Result` type cannot match
  the schema's name. When `.owned` is generated, a throwing router cannot
  choose an edge named `rejected`, because its owned result enum uses
  `case rejected`. A phase case may share a name with a snapshot member such as
  `revision`, and an edge or router may share one with a phase-wrapper member
  unless its generated method would redeclare or shadow it: a zero-payload edge
  or router cannot be named `value`, `revision`, `description`, or (with
  `.owned`) `takeValue`, and a one-payload edge or router cannot be named
  `withValue` (with `.owned`). An operation's `<op>Driver:` label and an
  event's `on<Event>:` label share one managed initializer parameter list, so
  an operation `OnPrint` and an event `PrintDriver` cannot both be declared.
- Generated internal helpers and compiler witnesses begin with an
  underscore—covering the `_StateMachine*` and `_stateMachine*` families (such
  as `_StateMachineEngine`, `_StateMachineSchema`, `_StateMachineGraph`,
  `_StateMachineTypeN`, `_StateMachineChecked`), the witness types
  (`_TransitionSourceIsPhasePayload`, `_TransitionReturnsDeclaredResult`,
  `_TriggerPayloadMatchesDeclaration`, `_RouterSourceIsPhasePayload`,
  `_SharedModeRequiresSendable`, `_OperationFailureIsError`,
  `_OperationKeyIsHashable`, `_EffectIsCopyable`, `_SendingValueIsSendable`),
  and `_<Op>Work` for `.local` operations. Every generated `_`-prefixed name is
  reserved across every identifier token inside the schema body, covering both
  declarations and references, because the expansion's own declaration would
  hide an external declaration of the same name.

Generated code names every runtime and standard-library type through a module
selector, as `StateMachine::RuntimeState` and `Swift::Hashable`, so a schema
may declare its own types of those names, such as `Result` or `Error`, and even
types named `Swift` or `StateMachine`, at file scope or inside the schema. An
extension of a generated type, such as `Approval.Shared`, may add members, but
not a type named like one that the schema's signatures spell, such as `Draft`.
Generated members inside that type would name the extension's type instead, and
the macro cannot see extensions to avoid it. Diagnostics identify the
conflicting declaration and ask for a distinct name.
