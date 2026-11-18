# Declaring a graph

Keep each phase's data distinct and declare the edges a caller may take.

A schema is a `nonisolated enum` marked with `@StateMachine(mode:)`. Its cases
are phases, and each carries one distinct nested payload type. `import
StateMachine` is the only import a graph needs, because the macros live in that
module. This graph has one legal transition, from a draft to an approved value:

```swift
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Approval: Sendable {
    struct Draft: Sendable { let title: String }
    struct Approved: Sendable { let title: String }

    @Initial case draft(Draft)
    case approved(Approved)

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
exposes `approve`; `Owned<Approved>` does not. Calling the edge consumes the
draft owner and returns `Owned<Approved>`. An edge that starts nothing returns
its destination payload directly, and the macro derives the edge's endpoints
from its signature: `approve` takes a `Draft` and returns an `Approved`, so it
leads from the `draft` phase to the `approved` phase. Its trigger,
`Input.approve`, is an ordinary reference that the compiler resolves, so a
misspelled case fails to compile at the attribute.

The plain `Draft` and `Approved` values remain ordinary data. Constructing an
`Approved` does not construct an `Owned<Approved>`.

## Name each declaration

| To declare | Write |
| --- | --- |
| The ownership contract | `@StateMachine(mode: .shared)`, `.isolated`, or `.ownedOnly` on a `nonisolated enum` |
| A phase | A `case` with one payload type declared inside the schema |
| The initial phase | `@Initial` on exactly one `case` |
| A default initial payload | A default on the initial case, as in `@Initial case idle(Idle = Idle())` |
| An input | A case of the nested `enum Input` |
| An edge that starts nothing | `@Transition(on: Input.approve)` on a function returning the destination payload |
| An edge that starts operations | `@Transition(on: Input.begin, starts: [Fetch.self])` on a function returning `Change<Destination, Effect.Begin>` |
| An operation | `@Operation(activeIn: [Searching.self])` on an enum with `Input` and `Output` aliases, and a `Failure` alias when the work can fail |
| A completion edge | `@Transition(onSuccess: Fetch.self)` or `@Transition(onFailure: Fetch.self)` |
| Several edges for one source and trigger | `@Route(on:)`, `@Route(onSuccess:)`, or `@Route(onFailure:)` on a selector function |
| Authority that several operations share | A case of the nested `enum Scope`, named by `@Operation(scope: Scope.account, ...)` |
| Authority an edge revokes without leaving the active phases | `invalidates: [Scope.account]` |
| A dependency on a scope another operation owns | `requires: [Scope.session]` |
| Validation of saved data | `@Restoration` on one function returning `Restoration`, with `allows:` for phases where an operation is active |

Write each reference in an attribute exactly as shown: `Input.approve`,
`Scope.account`, `Fetch.self`, and `.shared`. The macro reads the spelling, so
it rejects qualified forms such as `Lookup.Input.approve`, implicit members such
as `.approve`, and computed expressions. An attribute may include its module
name, as in `@StateMachine.Transition`. A phase payload in an edge signature
may be written `Draft`, `Self.Draft`, or `Approval.Draft`. An operation can
spell its infallible `Failure` as `Never` or `Swift.Never`. An `Input` case can
also carry a type declared inside `Input`.

The `@Initial` case, and only that case, may give its payload a default. Every
fresh entry point then takes the initial payload as an optional argument:
`Local`, `Shared`, `ActorHost`, `MainActorHost`, and `owned(_:)`. An
`init(restoring:)` is unaffected, because saved data is always explicit. The
default is a call with no arguments. It either constructs the payload, as in
`Idle()`, or calls a static function of the schema that returns the payload, as
in `makeIdle()` or `Lookup.makeIdle()`. An owner created without the payload
evaluates the call once. The macro rejects any other expression, so to default
to something more involved, put the construction in a static function that
returns the payload and name that function. Swift checks the call itself: a
public schema needs a public initializer or function, and a payload whose
construction can throw or fail has no default. Declare one only when an empty
start is true to the domain. A payload that carries required data, such as a
user identifier, is passed explicitly.

## Start an operation

An operation is work the host runs and whose result returns through a
completion edge. This schema starts a search and handles its result:

```swift
@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable {
    struct Idle: Sendable {}
    struct Searching: Sendable { let query: String }
    struct Found: Sendable { let answer: String }

    @Initial case idle(Idle = Idle())
    case searching(Searching)
    case found(Found)

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

The operation namespace declares `Input` (what the work receives) and `Output`.
Its `activeIn` list names the phases where it may run, and leaving them revokes
the work: here, `cancel` returns to `Idle`, so a result that arrives afterward
is stale. Without a `scope:`, the operation holds a private scope of its own
that is active exactly in its `activeIn` phases. Its `admission:` is `.latest`
unless it says otherwise, which replaces older work with the newer start. The
other policies are `.rejectWhenActive` and `.parallel(limit:)`. Work receives
the post-commit activation of every scope it holds.

The macro generates the `Effect` type. It has one case per operation, named in
lower camel case. For example, `Fetch` becomes `.fetch`, and `URLFetch` becomes
`.urlFetch`. Each edge that lists `starts:` also gets its own effect type named
after the function, so `begin` has `Effect.Begin`. That type contains only the
listed operations, and returning an effect outside `starts:` does not compile.
Two edges with the same `starts:` have distinct effect types.

Each operation needs a success edge or router in every `activeIn` phase. A
completion edge may also list `starts:` to chain a successor operation.

### Declare a failure

An operation whose work can fail adds a `Failure` alias. Without one, `Failure`
is `Never`, the namespace cannot fail, and the driver returns the `Output`
itself. With one, the operation also needs a failure edge or router in every
`activeIn` phase, and its driver returns `Result<Output, Failure>`:

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
    case done(Done)
    case failed(Failed)

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

### Share authority with a scope

A named scope is for authority that more than one thing needs to reach. Declare
a case of the nested `Scope` enum, name it in `scope:`, and every operation with
that primary scope shares one activation, so an edge that invalidates it revokes
all of them. `requires:` lists scopes an operation depends on without owning
them. Leaving the active phases already revokes an operation's work, so
`invalidates:` is for the other case: revoking work while staying in a phase
where the operation is active. This schema keeps its fetch under an account
scope, and `switchAccount` revokes the running fetch and starts another for the
new account without leaving `Loading`:

```swift
@StateMachine(mode: .shared)
nonisolated enum Feed: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable { let account: String }
    struct Loaded: Sendable { let items: [String] }

    @Initial case idle(Idle = Idle())
    case loading(Loading)
    case loaded(Loaded)

    enum Scope { case account }
    enum Input: Sendable { case load(String), switchAccount(String) }

    @Operation(scope: Scope.account, activeIn: [Loading.self])
    enum Fetch {
        typealias Input = String
        typealias Output = [String]
    }

    @Transition(on: Input.load, starts: [Fetch.self])
    fileprivate static func begin(_ source: Idle, _ account: String) -> Change<Loading, Effect.Begin> {
        Change(Loading(account: account), effects: [.fetch(account)])
    }

    @Transition(on: Input.switchAccount, invalidates: [Scope.account], starts: [Fetch.self])
    fileprivate static func switchAccount(
        _ source: Loading,
        _ account: String
    ) -> Change<Loading, Effect.SwitchAccount> {
        Change(Loading(account: account), effects: [.fetch(account)])
    }

    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Loading, _ items: Fetch.Output) -> Loaded {
        Loaded(items: items)
    }
}
```

## Host the graph

Each schema mode generates the owners it supports:

| Generated owner | Available modes | Execution ownership |
| --- | --- | --- |
| `MainActorHost` | `shared`, `isolated` | `MainActor` owns state and manages work. |
| `ActorHost` | `shared` | A native actor owns state and manages work. |
| `Shared` | `shared` | A shared runtime manages work and synchronous admission. |
| `Local` | `shared`, `isolated` | Caller drains batches and acknowledges each execution. |
| `Owned<Phase>` | All | Caller executes the returned inert effects. |

In `shared` mode, phase data, inputs, effects, and operation outcomes must meet
checked `Sendable` requirements as well as the domain's value-semantics
contract. In `isolated` mode, copyable data can remain within its permitted
actor without becoming `Sendable`. In `ownedOnly` mode, phase payloads may be
noncopyable resources; they do not receive copyable snapshots or shared
storage.

An `isolated` schema is declared the same way. The enum stays `nonisolated`, and
its payloads and inputs do not need to be `Sendable`; this example says so with
`~Sendable`. The owner confines the values, so a `MainActorHost` keeps them on
the main actor:

```swift
@StateMachine(mode: .isolated)
nonisolated enum Note {
    struct Draft: ~Sendable { let text: String }
    struct Saved: ~Sendable { let text: String }

    @Initial case draft(Draft)
    case saved(Saved)

    enum Input: ~Sendable { case save }

    @Transition(on: Input.save)
    fileprivate static func save(_ source: Draft) -> Saved { Saved(text: source.text) }
}

@MainActor
func saveNote() throws {
    let host = Note.MainActorHost(Note.Draft(text: "Outline"))
    try host.send(.save)
}
```

A graph with no operations has no drivers, `runningCount`, delivery,
reconciliation, or completion-policy surface on any owner, as
`Note.MainActorHost` shows above, and its `Local` queues no commands, so it
needs no draining.

A managed owner takes a driver for each operation when it is created. A driver
for an operation that cannot fail returns the `Output` directly. A fallible
operation's driver returns `Result<Output, Failure>`, as `Upload` shows. Pass
each driver as its own closure, labelled with the operation's effect case
followed by `Driver`, so `Fetch` takes `fetchDriver:`. The closures follow the
order the operations are declared, and each is required. With the default that
`Lookup` declares, the host also needs no initial payload:

```swift
@MainActor
func search() async throws {
    let host = Lookup.MainActorHost(fetchDriver: { query in "Results for \(query)" })

    let receipt = try host.send(.search("swift"))
    print("Accepted revision \(receipt.revision)")

    await host.shutdown()
}
```

The same owner also takes a `Drivers` value through `drivers:`, or a
`MainActorDrivers` value for `MainActorHost`. Prefer the value when one set of
drivers serves several owners, when a test injects stubs, and when a graph has
many operations, where one value is easier to read and pass than a long list of
closures:

```swift
func makeOwners(drivers: Lookup.Drivers) -> (Lookup.Shared, Lookup.ActorHost) {
    (Lookup.Shared(drivers: drivers), Lookup.ActorHost(drivers: drivers))
}
```

Every owner except `Owned` routes, prepares, and attempts to admit an `Input`
through `send(_:)`. It returns a `Receipt` or throws `SendRejection`.
`ActorHost.send(_:)` is `async`, and `Local.send(_:)` is `mutating`.
`.preparation(PreparationRejection)` covers a missing route (`.invalidPhase`)
and a router or edge that declines the input. `.commit(CommitRejection)` means
the owner refused the prepared change, including `.commit(.plan(_))` for a
defective effect plan. A closed owner reports `.commit(.closed)` before any plan
defect, because closing removes the scopes that a plan's work needs.
`CommitRejection` and the `Capacity` and `PolicyFailure` values it carries are
types of the `StateMachine` module, shared by every graph. `Shared.send` makes
exactly one attempt and is the only
owner where a concurrent write can cause `.commit(.conflict)`. The
`MainActorHost` and `ActorHost` read, prepare, and admit in one isolated turn.

The receipt carries the accepted `revision` and the complete `Snapshot`. A
snapshot has one case per phase, holding an `Observed<Phase>` whose `value` is
the payload. A `Snapshot` and a `Receipt` print the phase, the revision, and
`closed` when they record closure, as in `searching, revision 1`. An `Observed`
prints its payload type in place of the phase, as in `Searching, revision 1`.
None of them prints payload contents.

`MainActorHost`, `ActorHost`, and `Shared` also offer `snapshots()`, which
registers an observer and returns a single-pass asynchronous sequence of
complete snapshots. Creating it throws `SubscriptionFailure` when subscriber
capacity is exhausted; iterating never throws. `ActorHost.snapshots()` is
`async`.

```swift
@MainActor
func watch(_ host: Lookup.MainActorHost) async throws {
    for await snapshot in try host.snapshots() {
        print(snapshot.revision)
    }
}
```

To show a hosted graph in SwiftUI, wrap a `MainActorHost` in
`StateMachinePresentation`, or in `StateMachineObservableObject` before iOS 17,
as the `StateMachineUI` documentation describes.

The runtime types behind the generated owners are available through aliases
inside the schema: `Subscription` and `MainActorSubscription`, which name
`SnapshotSubscription` and `MainActorSnapshotSubscription`,
`SubscriptionFailure`, `MainActorSnapshots`, `Snapshots`, `PendingStatus`,
`Configuration`, and `LocalConfiguration`. `Snapshots` exists in `shared` mode
and `MainActorSnapshots` in `isolated` mode. Each managed owner also nests a
`CompletionPolicy`. Because the aliases live inside the schema, importing
Combine beside State Machine leaves a bare `Subscription` meaning Combine's
protocol and `Lookup.Subscription` meaning the registration.

Actor isolation does not prevent two snapshots from sharing a mutable reference.
Use value storage, immutable objects, or detached projections when a graph
promises historical observations. The macro cannot establish business validity,
deep value semantics, or the purity of arbitrary function bodies.

### Choose a completion policy

When an operation's driver returns, the host prepares the completion edge from
the current state and tries to admit it. Another commit can win that race. A
managed owner's `completionPolicy:` decides what happens next, and it is one of
three values:

- `.retryPure`, the default, prepares the completion again against the newer
  state, at most four times per turn before yielding to other work. It notifies
  no one.
- `.retryPure(onReconciliationRequired:)` retries the same way and passes a
  handler every completion that still needs reconciliation.
- `.manual(onReconciliationRequired:)` never prepares a completion again on its
  own. Every completion that needs reconciliation, including one that lost a
  race, goes to the handler.

A completion needs reconciliation when its completion edge or router threw, its
effect plan is defective, the owner refused its admission, or an explicit
`reconcile(id:)` did not commit. The handler runs outside the owner's critical
section, each time a retained completion's status becomes
`.reconciliationRequired`, and receives a `PendingCompletion`. Its `outcome` is
plain data with one case per operation, holding what the driver returned: the
output itself for an operation that cannot fail, and a `Result` for one that
can. A handler can read it without any authority to apply it.
`PendingCompletionID` is specific to the graph, so an identifier from another
graph does not type-check.

Retrying evaluates a completion's edge and router again after another commit
wins the race, so `.retryPure`, the default, assumes that every completion edge
and router is deterministic and free of side effects. Capture network
responses, decoded values, time, and other external inputs once, before they
reach an edge. The compiler does not check this; when an edge is not pure, use
`.manual(onReconciliationRequired:)`. Until a retained completion is settled the
owner keeps only its first terminal outcome. Settle it with `reconcile(id:)`,
which authorizes one fresh preparation and reports `.inProgress` if another
attempt holds the claim, or end it with `discardPending(id:)`:

```swift
func makeLookup() -> Lookup.Shared {
    Lookup.Shared(
        fetchDriver: { query in "Results for \(query)" },
        completionPolicy: .manual(onReconciliationRequired: { pending in
            print("Needs reconciliation: \(pending.id), \(pending.status)")
        })
    )
}

func settle(_ lookup: Lookup.Shared) {
    for pending in lookup.pendingCompletions() {
        switch lookup.reconcile(id: pending.id) {
        case .committed(let receipt):
            print("Applied at revision \(receipt.revision)")
        case .pending(_, let status):
            print("Still waiting: \(status)")
        case .inProgress, .notPending:
            break
        }
    }
}
```

A managed owner has no `deliver`: a caller never holds a work value there, so a
completion reaches the owner only through its own driver. `Local` is the owner
where a caller delivers completions, as the section on running effects shows.

## Act on the observation a caller saw

`send(_:)` acts on whatever the owner currently holds. Use it for an event that
should apply to the current state: a tap that means "cancel the current
search", a push notification, or a timer.

`Observed<Phase>` also has one method for each edge whose source is that phase.
Each returns a `Prepared` proposal, which an owner's `commit(_:)` consumes and
admits only if that observation is still the owner's current revision. An edge
that cannot fail needs no `try`, and an edge that throws a typed failure throws
exactly that failure from the observed method. `commit` returns a
`CommitResult`, either `.committed(receipt)` or `.rejected(reason, current:)`,
and the result is not discardable. A defective effect plan is carried inside
`Prepared` with the snapshot it was prepared from, and `commit` reports it as
`.rejected(.plan(_), current:)` unless that snapshot belongs to another owner or
the owner has closed, which it reports first. A rejected commit changes neither
model data nor operation authority. Every owner except `Owned`, and both
`StateMachinePresentation` and `StateMachineObservableObject` in
`StateMachineUI`, have `commit(_:)`.
`ActorHost.commit(_:)` is `async`, and `Local.commit(_:)` is `mutating`. A
presentation shows the result in the same turn.

Use this path when the action belongs to the exact observation the user saw, and
handle `.conflict` if an intervening commit advances the same open owner.
Closing the owner takes precedence and produces `.closed`.

```swift
@MainActor
func cancel(_ searching: Lookup.Observed<Lookup.Searching>, on host: Lookup.MainActorHost) {
    switch host.commit(searching.cancel()) {
    case .committed:
        print("Cancelled")
    case .rejected(.conflict, let current):
        print("The search changed first: \(current)")
    case .rejected(let reason, _):
        print("Cancel was not accepted: \(reason)")
    }
}
```

The compiler checks the call. If `cancel` is removed from the schema or moves to
another phase, this function stops compiling, whereas `send(.cancel)` routes at
run time and fails with `.preparation(.invalidPhase)`. A completion edge has no
method on an observation: an owner admits a completion only through its own
delivery, so a caller cannot commit a result the driver never produced.
`prepare(_:on:)` routes an input against a snapshot the way `send` does and
throws `PreparationRejection`; it returns a `Prepared` for `commit(_:)`.

## Choose among edges with a router

When several edges share a source and trigger, a router selects among them. It
is a function marked `@Route` that receives the plain source payload and trigger
payload, and returns a generated enum with one case per candidate edge:

```swift
@StateMachine(mode: .shared)
nonisolated enum Session: Sendable {
    struct Active: Sendable { let name: String }
    struct Ended: Sendable { let name: String }

    @Initial case active(Active)
    case ended(Ended)

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

`Route.Choose` has the cases `.keep` and `.end`, one per candidate edge. A
router may use typed throws to decline, and `send` reports the failure as a
`PreparationRejection` case named after the router. The observed method throws
the failure type that the router and its candidate edges share, however many of
them throw, and `PreparationRejection` only when their failure types differ. A
router with no candidate
edge returns `Never` and must throw. If a completion router declared with
`@Route(onSuccess:)` or `@Route(onFailure:)` selects an edge, the edge must
match its source phase, operation, and success or failure trigger. Terminal
phases and unused edges are legal. Restoration can enter a phase unreachable
from the initial phase.

A routed input has one public method, named after the `@Route` function, on
`Observed` and on `Owned`. A completion router has one on `Owned`, since an
observation has no completion methods, and delivery runs it too. Each runs the
router and then the edge it selects, so a typed call obeys the router exactly as
`send` or delivery does. The candidate edges have no methods of their own.
`send(.refresh(true))` goes through `choose`, which selects `end`, and so does
the observed call:

```swift
func finish(_ active: Session.Observed<Session.Active>) -> Session.Prepared {
    active.choose(true)
}
```

On `Owned`, the method returns the candidates' shared result when the router
cannot throw and every candidate returns one type. Otherwise it returns
`Route.<Router>Result`, with a case for each candidate. When the router throws,
that enum adds `rejected(_:_:)`, which holds the failure and the unchanged
source. Here the candidates return different phases, so `choose` returns
`Route.ChooseResult`:

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

## Handle fallible edges

An edge may use typed `throws(Failure)`. The generated `Owned` edge returns an
`Advance` that gives back the original owner on rejection. Hosted preparation
through `send` reports the failure as a `PreparationRejection` case named after
the edge, and the observed method throws the failure itself, so only a call
that can fail needs `try`:

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

An `ownedOnly` edge consumes its source with `consuming`. If it can fail, it
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
    case sealed(Sealed)

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

Inputs have zero or one unlabeled payload. Every phase case has one unlabeled
payload, whose distinct struct or enum is declared directly inside the schema.
Fields can use imported types and nested generic containers. Phase aliases,
reusing a payload type for several phases, generic schema or phase payload
declarations, async edges, untyped throws, `inout` sources, and generic edge
functions are unsupported. Keep declarations inside the schema; the macro does
not discover extensions or scan other files.

The package compiles three stress graphs of 128 phases on every change: one
with 512 edges over four inputs, one where each of 512 edges has its own input,
and one with 32 operations. Larger graphs are not measured.

Generated member names and the support types used by expansion are reserved. For
example, a value graph cannot name a phase case `model`, `record`, `revision`,
`isClosed`, or `description`, because its snapshot already uses those members,
and `Restoration`, `ShutdownResult`, and `ShutdownDiagnostics` are reserved type
names. Diagnostics identify the conflicting declaration and ask for a distinct
name.

## Run effects with `Local` and `Owned`

`Local` and `Owned` leave execution to the caller. `Local` is a noncopyable
value with no automatic runner or observation subscription. Its caller drains
whole batches after acceptance, then releases mutating access before executing
any work. `Local` queues a batch only for an acceptance that starts or cancels
work, and for closure. Any other acceptance returns its receipt from `send` or
`commit` and queues nothing, so a run of plain edits never waits for a drain.
This synchronous example sends the input, prints the message, seals that
execution's result, and acknowledges that the print has finished:

```swift
@StateMachine(mode: .shared)
nonisolated enum MessageFlow: Sendable {
    struct Ready: Sendable { let message: String }
    struct Sent: Sendable { let message: String }
    @Initial case ready(Ready)
    case sent(Sent)

    enum Input: Sendable { case send }

    @Operation(activeIn: [Ready.self])
    enum Publication {
        typealias Input = String
        typealias Output = Void
    }

    @Transition(on: Input.send, starts: [Publication.self])
    fileprivate static func send(_ source: Ready) -> Change<Ready, Effect.Send> {
        Change(source, effects: [.publication(source.message)])
    }

    @Transition(onSuccess: Publication.self)
    fileprivate static func published(_ source: Ready, _ output: Publication.Output) -> Sent {
        Sent(message: source.message)
    }
}

func publishLocally() throws {
    var machine = MessageFlow.Local(MessageFlow.Ready(message: "Approved"))
    try machine.send(.send)

    for batch in machine.drainCommands(limit: 8) {
        for command in batch.commands {
            switch command {
            case .publication(let work):
                print(work.input)
                let delivery = machine.deliver(work.succeeded())
                let acknowledgment = machine.acknowledgeExecution(work.execution, disposition: .terminated)
                print("Delivery: \(delivery); execution: \(acknowledgment)")
            case .cancel:
                // An asynchronous runner requests cancellation here and
                // acknowledges only after its task actually terminates.
                break
            }
        }
    }

    // Closure also produces a batch, even with no new work.
    _ = machine.close()
    _ = machine.drainCommands(limit: 8)
    print("Settled: \(machine.isQuiescent)")
}
```

`Local.deliver` accepts one operation's sealed completion directly.
`work.succeeded(value)` and `work.failed(value)` build it, and an operation
whose `Output` is `Void` has `succeeded()`. An operation that cannot fail has no
`failed`, and its completion's `value` is the output itself, where a fallible
operation's completion holds a `result`. An ordinary output value cannot stand
in for that authority. Copying a
valid completion permits repeated delivery attempts, while successful terminal
admission retires the operation at most once.

Returning a completion and acknowledging termination are separate obligations.
`deliver(_:)` returns a `DeliveryResult`: `.committed(receipt)`,
`.pending(id, status)` when the outcome is retained, `.stale` when the operation
has lost its authority or its outcome already settled, and `.foreignOwner` when
a different owner issued the completion. `AcknowledgmentResult` is `.recorded`,
`.duplicate`, or `.foreignOwner`. An asynchronous runner must retain its
execution handles until the tasks terminate, and a cancellation request alone
does not acknowledge termination. A retained delivery may still need admission
or explicit reconciliation after execution has ended. Draining and
acknowledging never admit a retained completion. For a completion pending on
capacity, `retryAdmission(id:)` rechecks the prepared candidate. It commits if
capacity is available and the candidate is still current. An intervening
revision requires `reconcile(id:)` while the operation remains active. Both
return a `ReconcileResult`: `.committed`, `.pending`, `.inProgress`, or
`.notPending`. `discardPending(id:)` returns a `DiscardResult`: `.discarded`,
`.rejected`, or `.notPending`.

`Owned` runs the authored edge and leaves its effects to the caller. If the edge
returns the destination payload without throwing, the consuming method returns
the next `Owned` directly. If it returns `Change` without throwing, the method
returns `Change<Owned<Next>, Effect.<Edge>>` with ordered effects. An edge that
uses typed throws or returns `Advance` produces
`Advance<Owned<Source>, Owned<Next>, Intent, Failure>`, with `Never` for
`Intent` when `starts:` is empty and `Effect.<Edge>` otherwise. The `effect`
property on each value widens it to the schema-wide `Effect`. A completion edge
is an `Owned` method too, taking the operation's `Output` or `Failure`, unless a
completion router chooses among it and other edges; then `Owned` offers the
router's method instead. `takeValue()` consumes an owner and returns its
payload, whereas `withValue` borrows it for a closure, which can return a
noncopyable value or throw a typed error that `withValue` rethrows:

```swift
func ownedSearch() {
    let change = Lookup.owned().begin("swift")
    print(change.effects.map(\.effect))

    let idle = change.next.cancel()
    idle.withValue { _ in }
}

func ownedFound() {
    let change = Lookup.owned().begin("swift")
    let found = change.next.received("Swift.org")
    print(found.takeValue().answer)
}
```

`Owned<Searching>` offers `cancel()` and `received(_:)`, and `Owned<Idle>`
offers only `begin(_:)`.

To compare effects in a test, declare `extension Lookup.Effect: Equatable {}` in
the file that declares the schema. The compiler synthesizes `==` only in the
file that declares the type, so the extension fails to compile anywhere else.
Then compare `change.effects.map(\.effect)` with an array of `Lookup.Effect`
values. The [testing guide](<doc:TestingAGraph>) shows this in a test.

## Restore saved data

A `shared` or `isolated` schema generates `Restoration`, an enum with one case
for each phase in which no operation is active. A schema may declare one
function marked `@Restoration` that validates saved data into one of those
cases:

```swift
@StateMachine(mode: .shared)
nonisolated enum Download: Sendable {
    struct Idle: Sendable { let name: String }
    struct Running: Sendable { let name: String }
    struct Finished: Sendable {
        let name: String
        let bytes: Int
    }

    @Initial case idle(Idle)
    case running(Running)
    case finished(Finished)

    enum Input: Sendable { case start, cancel }

    @Operation(activeIn: [Running.self])
    enum Transfer {
        typealias Input = String
        typealias Output = Int
    }

    enum RestoreRejection: Error, Sendable { case emptyName }

    @Restoration
    fileprivate static func restore(_ saved: Self) throws(RestoreRejection) -> Restoration {
        switch saved {
        case .idle(let idle):
            guard !idle.name.isEmpty else { throw .emptyName }
            return .idle(idle)
        case .running(let running):
            // Saved work has no task to resume, so start over from the resting phase.
            return .idle(Idle(name: running.name))
        case .finished(let finished):
            return .finished(finished)
        }
    }

    @Transition(on: Input.start, starts: [Transfer.self])
    fileprivate static func start(_ source: Idle) -> Change<Running, Effect.Start> {
        Change(Running(name: source.name), effects: [.transfer(source.name)])
    }

    @Transition(on: Input.cancel)
    fileprivate static func cancel(_ source: Running) -> Idle { Idle(name: source.name) }

    @Transition(onSuccess: Transfer.self)
    fileprivate static func received(_ source: Running, _ bytes: Transfer.Output) -> Finished {
        Finished(name: source.name, bytes: bytes)
    }
}

@MainActor
func resume(_ saved: Download) async throws {
    let host = try Download.MainActorHost(
        restoring: saved,
        transferDriver: { name in name.count }
    )
    print(host.snapshot().revision)

    try host.send(.start)
    await host.shutdown()
}
```

The function takes the saved data as its one parameter, which can be any type
that the application defines, and returns `Restoration`. It may use typed
`throws`. Declaring it gives every owner except `Owned` an `init(restoring:)`
that mirrors the ordinary initializer, takes the saved data in place of the
initial payload, and throws exactly when the function does. A managed owner's
`init(restoring:)` also has the form with one closure per operation, as
`transferDriver:` does here. A restored owner starts at revision zero with fresh
authority. It adopts no ticket, task, or pending completion from any other
owner.

A phase in which an operation is active has no `Restoration` case unless the
function lists it in `allows:`, so saved data cannot resume running work.
Returning `.running(...)` from `restore` here does not compile: the compiler
reports that `Download.Restoration` has no member `running`. The author either
rejects that saved shape or maps it to a resting phase, as `restore` does for
`.running`, and then sends an input to start fresh work. Listing a phase in
`allows:` adds it to `Restoration`, and an owner restored into it holds no
outstanding work. A phase in which no operation is active may be listed too;
listing pins it, so it stays restorable if an operation later becomes active
there. The <doc:Persistence> article covers these cases. A schema with no
operations has a case for every phase.

Forking is restoring a saved copy of `snapshot.model`. Because `restore` takes
the schema itself, a fork of a running owner is one initializer call:

```swift
func fork(_ original: Download.Shared) throws -> Download.Shared {
    try Download.Shared(
        restoring: original.snapshot().model,
        transferDriver: { name in name.count }
    )
}
```
