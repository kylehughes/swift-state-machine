/// Selects ownership and isolation surfaces at expansion time.
nonisolated public enum StateMachineMode: String, Sendable, Hashable, Codable {
    /// `Copyable`, `Sendable` values with explicit shared ownership.
    case shared
    /// `Copyable` values confined to one isolation domain.
    case isolated
    /// Unique payloads with explicit consuming transitions.
    case ownedOnly
}

/// An owner that `@StateMachine` can generate.
nonisolated public enum StateMachineOwner: String, Sendable, Hashable, Codable {
    /// `Owned`, unique authority over one phase that consuming transitions advance.
    case owned
    /// `Local`, a noncopyable manually driven owner.
    case local
    /// `Shared`, a synchronous owner that any isolation domain can share (available only in `.shared` mode).
    case shared
    /// `ActorHost`, a managed owner isolated to its own actor (available only in `.shared` mode).
    case actorHost
    /// `MainActorHost`, a managed owner isolated to the main actor.
    case mainActorHost
    /// `IsolatedHost<Owner>`, a managed owner confined to one actor instance that its creator chooses.
    case isolatedHost
}

/// The admission policy for one operation and scope activation.
nonisolated public enum StateMachineAdmission: Sendable, Hashable, Codable {
    /// Replaces older authority in the same operation group.
    case latest
    /// Rejects while an earlier group member remains active.
    case rejectWhenActive
    /// Allows at most the positive literal number of active group members.
    case parallel(limit: Int)
}

/// Expands a closed lexical enum schema into sealed ownership surfaces.
///
/// Phases are the enum's cases, each carrying a distinct nested payload type. `@Initial` marks the
/// starting phase, and `@Terminal` marks each phase the graph intends to end in. Inputs are the
/// cases of a nested `Input` enum, which an `.ownedOnly` schema may omit, and invalidation scopes
/// are the cases of an optional nested `Scope` enum, which a schema needs only when an operation
/// names a scope or an edge invalidates one. Other metadata is written as compiler-resolved
/// references such as `Input.load`, `Scope.load`, and `Loading.self`.
///
/// Every mode generates `Effect`, with one case per `@Operation` and `@Event` namespace, `graph`, a
/// ``StateMachineGraph`` of the declarations, and every owner that mode supports. The `.shared` and
/// `.isolated` modes also generate typed work and completion values for each operation and a
/// `Restoration` enum for the phases a validator may restore. A schema without operations generates
/// no work, completion, or delivery surface.
///
/// The macro checks the graph's structure from its declarations and reports each problem as an
/// error on the declaration at fault. It rejects any phase that neither the initial phase nor a
/// restorable phase reaches, any phase without an outgoing edge that is not `@Terminal`, any
/// operation that no reachable edge starts or whose result no reachable edge accepts, and any
/// completion edge whose operation can never be active in its source phase. A path counts as soon
/// as its edges are declared, because the macro cannot know which ones an authored function takes.
/// A phase whose only edges lead back to itself is a legitimate long-lived phase.
///
/// Edges that leave different phases may share a name, as Swift overloads that differ in their
/// source payload, while two edges or routers that leave one phase may not. An edge's effect type
/// is `Effect.<Phase>.<Edge>`, and a router's choice type is `Route.<Phase>.<Router>`, for its
/// source phase. The shorter `Effect.<Edge>` names the same type when the name belongs to one edge
/// that starts operations or when every edge of that name starts the same list. `Route.<Router>`
/// does so when every router of that name chooses among the same edges, and `Route.<Router>Result`
/// when one router has that name. A `PreparationRejection` case is named for the function that
/// threw, and prefixed with its source phase, as in `draftSave`, when functions of that name throw
/// different types.
///
/// A router's choice type is always `Sendable`, `Equatable`, `Hashable`, and `CaseIterable`. When the
/// schema's inheritance clause lists `Equatable` or `Hashable`, `Effect`, every edge's effect type, and
/// `Restoration` conform to it too, so a test in another module can compare effects.
///
/// A `Local` owner queues a command batch only for an acceptance that starts or cancels work or
/// emits an event, and for closure, so it admits any number of other inputs without draining.
///
/// Schema, case, operation, and edge names use unescaped Swift identifiers.
/// Generated facade names and required support-type spellings are reserved in the schema, and the
/// names of generated companion types and cases must be distinct in the namespace that holds them.
@attached(member, names: arbitrary)
public macro StateMachine(mode: StateMachineMode) =
    #externalMacro(module: "StateMachineMacros", type: "StateMachineMacro")

/// Expands a closed lexical enum schema into the listed owners only.
///
/// It is the `@StateMachine` expansion that generates the listed owners and only the support they
/// use, so a graph driven by one `Local` has no managed host, driver bundle, or shutdown vocabulary.
/// `.shared` mode supports every owner, `.isolated` supports `.owned`, `.local`, `.mainActorHost`,
/// and `.isolatedHost`, and `.ownedOnly` supports `.owned` alone. A `@Restoration` function needs an
/// owner other than `.owned`.
///
/// - Parameters:
///   - mode: The ownership and isolation of the graph's values.
///   - owners: At least one owner to generate, each listed once.
@attached(member, names: arbitrary)
public macro StateMachine(mode: StateMachineMode, owners: [StateMachineOwner]) =
    #externalMacro(module: "StateMachineMacros", type: "StateMachineMacro")

/// Marks the phase case in which fresh authority is created.
///
/// Apply it to exactly one single-phase `case` declaration directly inside the schema.
///
/// This is the only case that may give its payload a default, as in `@Initial case idle(Idle = Idle())`.
/// Every fresh entry point (`owned(_:)`, `Local`, `Shared`, `ActorHost`, `MainActorHost`, and
/// `IsolatedHost`) then takes the initial payload as an optional argument. The default is a
/// zero-argument call that constructs the payload or calls a static function of the schema returning
/// it, such as `Idle()`, `makeIdle()`, or `Lookup.makeIdle()`. The compiler checks the call, so a
/// public schema needs a public initializer or function. A `restoring:` initializer never has a default.
@attached(peer)
public macro Initial() = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Marks a phase case in which the graph intends to end.
///
/// Apply it to a single-phase `case` declaration directly inside the schema. A terminal phase has no
/// outgoing edge or router and no operation may be active in it. Every other phase needs an outgoing
/// edge, which may lead back to the phase itself.
@attached(peer)
public macro Terminal() = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Declares the phases in which one named scope stays active.
///
/// Apply it to a single-case declaration in the schema's `Scope` enum. An operation whose primary
/// scope is this case may run in exactly these phases, and leaving them revokes every operation that
/// holds the scope as its primary or a required scope. A `Scope` case without it is active in every
/// phase. Write `@StateMachine.Active` when the schema declares its own type named `Active`.
///
/// - Parameter phases: At least one phase, written `<Phase payload>.self`.
@attached(peer)
public macro Active(in phases: [any (~Copyable).Type]) =
    #externalMacro(module: "StateMachineMacros", type: "ActiveMacro")

/// Declares one inert event that an edge may emit alongside its effects.
///
/// The namespace is the event's identity and may declare a `Payload` alias. Without one, the payload
/// is `Void`, which the macro declares. The generated `Effect` gains one case for it, named by
/// lower-casing the namespace's leading capitals, so `Tracked` is emitted with `.tracked(payload)`,
/// or `.tracked` when its payload is `Void`. An event has no output, completion, scope, ticket, or
/// driver.
///
/// An edge lists the events it may emit in `emits:` and returns them in its effects, in any order
/// among the operations it starts. An `Owned` edge returns them, and a `Local` owner carries each in
/// its acceptance's command batch in authored order. Every managed owner takes one synchronous
/// handler per event, labeled `on<Event>:`, and calls it once per emission in commit order, after
/// the commit and outside every lock, from the turn that processes the acceptance's batch. Write
/// `@StateMachine.Event` when the schema declares its own type named `Event`.
@attached(peer)
@attached(member, names: named(Payload))
public macro Event() = #externalMacro(module: "StateMachineMacros", type: "EventMacro")

/// Marks the function that validates saved data into a phase in which fresh authority is restored.
///
/// Apply it to at most one static function directly inside a `.shared` or `.isolated` schema. The
/// function takes the saved data as its one unlabeled parameter and returns the generated `Restoration`, which
/// has one case per phase in which no operation is active, plus one per phase listed in `allows:`. It
/// may use typed throws to reject the data. Each generated owner except `Owned` then gains an
/// initializer labeled `restoring:` that calls it and creates fresh authority at revision zero in
/// the returned phase, with no outstanding work, exactly as a fresh owner starting in that phase,
/// and a `reset(restoring:)` that replaces an existing owner's model with that phase in a fresh
/// incarnation. Saved data never resumes work.
///
/// - Parameter allows: Phases that saved data may restore even when an operation may be active in
///   them, written `<Phase payload>.self`. A phase in which no operation is active is restorable
///   without being listed. Listing it pins it so it stays restorable if an operation later becomes
///   active there.
@attached(peer)
public macro Restoration(allows: [any (~Copyable).Type] = []) =
    #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Marks the function that validates saved data into exactly the listed phases.
///
/// It is the `@Restoration` validator whose `Restoration` has one case for each listed phase and no
/// other, whether or not an operation may be active in it, so changing where operations are active
/// never changes the phases an archive can name.
///
/// - Parameter only: At least one phase saved data may restore, written `<Phase payload>.self`.
@attached(peer)
public macro Restoration(only: [any (~Copyable).Type]) =
    #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Describes one synchronous authored transition taken when an input arrives.
///
/// The signature identifies the source and destination phases.
/// The first parameter is the source phase payload. Add a second parameter if the input case
/// carries a payload. Both parameters are unlabeled.
///
/// In `.shared` and `.isolated`, the source may be plain or `borrowing`. With empty or omitted
/// `starts` and `emits` lists, return the destination payload. Otherwise return
/// `Change<Destination, Effect.<Edge>>`, or `Change<Destination, Effect.<Phase>.<Edge>>` when the short
/// name does not exist. Either form may use typed throws.
///
/// In `.ownedOnly`, every edge takes a `consuming` source and cannot throw. Use the same return
/// types for success, or return `Advance<Source, Destination, Intent, Failure>` to give back the
/// source on rejection. `Intent` is `Never` for empty or omitted `starts` and `emits` lists and
/// `Effect.<Edge>` otherwise. The generated effect type contains only the listed operations and events.
///
/// - Parameters:
///   - on: The triggering case, written `Input.<case>`.
///   - invalidates: Scopes whose authority the edge revokes, written `Scope.<case>`.
///   - starts: Operations the edge may start, written `<Operation>.self`.
///   - cancels: Keyed operations whose work the edge may cancel, written `<Operation>.self`.
///   - emits: Events the edge may emit, written `<Event>.self`.
@attached(peer)
public macro Transition(
    on: Any,
    invalidates: [Any] = [],
    starts: [Any.Type] = [],
    cancels: [Any.Type] = [],
    emits: [Any.Type] = []
) =
    #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Describes one synchronous authored transition that an `.ownedOnly` schema's caller takes directly.
///
/// The function takes only its `consuming` source, and the owned source phase gains a method named
/// after it. An `.ownedOnly` schema has no routing surface, so its edges need no `Input` case and
/// the schema needs no `Input` enum. It returns as an input transition does.
///
/// - Parameters:
///   - invalidates: Scopes whose authority the edge revokes, written `Scope.<case>`.
///   - starts: Operations the edge may start, written `<Operation>.self`.
///   - cancels: Keyed operations whose work the edge may cancel, written `<Operation>.self`.
///   - emits: Events the edge may emit, written `<Event>.self`.
@attached(peer)
public macro Transition(
    invalidates: [Any] = [],
    starts: [Any.Type] = [],
    cancels: [Any.Type] = [],
    emits: [Any.Type] = []
) =
    #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Describes one synchronous authored transition taken from each of several phases when an input arrives.
///
/// The function takes no source parameter, taking only the input's payload unlabeled when the input
/// carries one. Each listed phase gains the edge, exactly as if the function were declared once per
/// phase, so its observed and owned phases each have a method for it and `send` takes it from each.
/// Its effect type, when it starts operations, is one type that every listed phase's
/// `Effect.<Phase>.<Edge>` names.
///
/// - Parameters:
///   - from: At least one source phase, written `<Phase payload>.self`.
///   - on: The triggering case, written `Input.<case>`.
///   - invalidates: Scopes whose authority the edge revokes, written `Scope.<case>`.
///   - starts: Operations the edge may start, written `<Operation>.self`.
///   - cancels: Keyed operations whose work the edge may cancel, written `<Operation>.self`.
///   - emits: Events the edge may emit, written `<Event>.self`.
@attached(peer)
public macro Transition(
    from: [any (~Copyable).Type],
    on: Any,
    invalidates: [Any] = [],
    starts: [Any.Type] = [],
    cancels: [Any.Type] = [],
    emits: [Any.Type] = []
) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Describes one synchronous authored transition that an `.ownedOnly` schema's caller takes directly
/// from each of several phases.
///
/// The function takes no parameters, and each listed owned phase gains a method named after it.
///
/// - Parameters:
///   - from: At least one source phase, written `<Phase payload>.self`.
///   - invalidates: Scopes whose authority the edge revokes, written `Scope.<case>`.
///   - starts: Operations the edge may start, written `<Operation>.self`.
///   - cancels: Keyed operations whose work the edge may cancel, written `<Operation>.self`.
///   - emits: Events the edge may emit, written `<Event>.self`.
@attached(peer)
public macro Transition(
    from: [any (~Copyable).Type],
    invalidates: [Any] = [],
    starts: [Any.Type] = [],
    cancels: [Any.Type] = [],
    emits: [Any.Type] = []
) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Describes one synchronous authored transition taken when an operation succeeds.
///
/// Delivery is the only way to prepare this edge for an owner, so the first outcome an owner
/// retains is the only one that can commit. It takes the source and the operation's `Output`, and may
/// take the operation's request last, labeled `request:`. An observed phase has no method for it. An
/// `Owned` phase has one that takes the `Output` and, when the edge takes it, a `request:`, unless a
/// router chooses among this edge and others, in which case the `Owned` phase has the router's method
/// instead.
///
/// - Parameters:
///   - onSuccess: The completing operation, written `<Operation>.self`.
///   - invalidates: Scopes whose authority the edge revokes, written `Scope.<case>`.
///   - starts: Operations the edge may start, written `<Operation>.self`.
///   - cancels: Keyed operations whose work the edge may cancel, written `<Operation>.self`.
///   - emits: Events the edge may emit, written `<Event>.self`.
@attached(peer)
public macro Transition(
    onSuccess: Any.Type,
    invalidates: [Any] = [],
    starts: [Any.Type] = [],
    cancels: [Any.Type] = [],
    emits: [Any.Type] = []
) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Describes one synchronous authored transition taken when an operation fails.
///
/// Delivery is the only way to prepare this edge for an owner. It takes the source and the
/// operation's `Failure`, and may take the operation's request last, labeled `request:`. An observed
/// phase has no method for it. An `Owned` phase has one that takes the `Failure` and, when the edge
/// takes it, a `request:`, unless a router chooses among this edge and others, in which case the
/// `Owned` phase has the router's method instead.
///
/// - Parameters:
///   - onFailure: The completing operation, written `<Operation>.self`.
///   - invalidates: Scopes whose authority the edge revokes, written `Scope.<case>`.
///   - starts: Operations the edge may start, written `<Operation>.self`.
///   - cancels: Keyed operations whose work the edge may cancel, written `<Operation>.self`.
///   - emits: Events the edge may emit, written `<Event>.self`.
@attached(peer)
public macro Transition(
    onFailure: Any.Type,
    invalidates: [Any] = [],
    starts: [Any.Type] = [],
    cancels: [Any.Type] = [],
    emits: [Any.Type] = []
) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Declares one operation's typed aliases and its lifetime metadata.
///
/// The namespace is the operation's identity and may declare `Input`, `Output`, and `Failure`
/// aliases. Without an `Input` alias, the input is `Void`, and without an `Output` alias, the output
/// is `Void`. Without a `Failure` alias, `Failure` is `Never`, the operation's driver returns its
/// output directly, and its completion and pending outcome carry that output as a plain value
/// instead of a `Result`. The generated `Effect` gains one case for it, named by lower-casing the
/// namespace's leading capitals, so `Fetch` is requested with `.fetch(input)`. An operation whose
/// input is `Void` is requested with `.refresh`, its work has no `input`, and its driver takes no
/// argument. The macro declares an omitted `Input` or `Output` alias as `Void`, so `Refresh.Output`
/// always names the output a completion edge takes.
///
/// A `Key` alias, as in `typealias Key = Item.ID`, keys the operation's work by a domain instance. Its
/// effect names the key, `.download(key: id, input: url)` or `.download(key: id)` when the input is
/// `Void`, its driver takes the key before the input, and admission applies its policy to each key.
/// `.latest` replaces only that key's work, while `.rejectWhenActive` and `.parallel(limit:)` count
/// only that key's. An edge that lists it in `cancels:` may emit `.cancelDownload(key: id)` and
/// `.cancelAllDownload`. The key is `Hashable` and `Sendable` and is hashed and compared outside
/// every lock. A key that no work holds any longer is forgotten, so starting it again begins anew.
///
/// The macro also generates a request type, `DownloadRequest`, holding the work's `key` and `input`,
/// for every operation that has either. Work, its completion, and a retained outcome carry the request
/// admission captured, and a completion edge or router may take it last, labeled `request:`.
///
/// The operation may run in the phases of its primary scope that are also phases of every required
/// scope, and leaving them revokes its work. An edge that starts it must lead to one of them.
///
/// - Parameters:
///   - scope: The primary scope whose authority the operation holds, written `Scope.<case>`. The
///     operation runs in the phases that the case's `@Active(in:)` lists, or in every phase when the
///     case has none, and an edge that invalidates the scope revokes every operation that holds it.
///   - requires: Additional scopes the operation depends on, written `Scope.<case>`.
///   - admission: The policy for admitting concurrent work.
@attached(peer)
@attached(member, names: named(Input), named(Output))
public macro Operation(
    scope: Any,
    requires: [Any] = [],
    admission: StateMachineAdmission = .latest
) = #externalMacro(module: "StateMachineMacros", type: "OperationMacro")

/// Declares one operation's typed aliases and a private scope active in the listed phases.
///
/// It is the `@Operation` whose primary scope belongs to it alone, active in exactly the `activeIn`
/// phases so no edge can name it to invalidate it. The operation may run in those phases that are
/// also phases of every required scope.
///
/// - Parameters:
///   - requires: Additional scopes the operation depends on, written `Scope.<case>`.
///   - activeIn: At least one phase in which the operation may run, written `<Phase payload>.self`.
///   - admission: The policy for admitting concurrent work.
@attached(peer)
@attached(member, names: named(Input), named(Output))
public macro Operation(
    requires: [Any] = [],
    activeIn: [any (~Copyable).Type],
    admission: StateMachineAdmission = .latest
) = #externalMacro(module: "StateMachineMacros", type: "OperationMacro")

/// Chooses among the edges that share a source phase and an input.
///
/// A router takes the source phase payload and, when the triggering case carries a payload, that
/// payload, as unlabeled parameters, and returns the generated `Route.<Router>` enum, or
/// `Route.<Phase>.<Router>` when the short name does not exist, which has one case per candidate
/// edge. It may use typed throws to decline. A router with no candidate edge returns `Never` and throws.
///
/// The router's name becomes the method of the observed and owned source phase for that input,
/// and its candidate edges have no methods of their own, so a typed call obeys the router exactly
/// as `send` does. The observed method returns `Prepared` and throws the failure type that the
/// router and its candidates share, or `PreparationRejection` when their failure types differ. The
/// owned method returns the candidates' shared result when the router cannot throw and they all
/// return one type, and otherwise `Route.<Router>Result`, with a case per candidate and, when the
/// router throws, `rejected(_:_:)` holding the failure and the unchanged source.
///
/// - Parameter on: The triggering case, written `Input.<case>`.
@attached(peer)
public macro Route(on: Any) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Chooses among the edges that share a source phase and an input, and fixes the failure its
/// observed method throws.
///
/// It is the input router whose observed method throws `failure` however its router and candidate
/// edges spell what they throw, so adding or changing a throwing candidate keeps the method's
/// signature. The compiler checks that the router and every throwing candidate throw that type.
/// The owned method's `rejected(_:_:)` case holds it too.
///
/// - Parameters:
///   - on: The triggering case, written `Input.<case>`.
///   - failure: The failure the observed method throws, written `<Failure>.self`.
@attached(peer)
public macro Route(on: Any, failure: any Error.Type) =
    #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Chooses among the edges that share a source phase and an operation's success.
///
/// The router takes the source phase payload and the operation's `Output` value, and optionally the
/// operation's request, as the edges it selects may. Delivery runs it, and an owned source phase has a method
/// named after it in place of its candidate edges, which returns as an input router's owned method does.
///
/// - Parameter onSuccess: The completing operation, written `<Operation>.self`.
@attached(peer)
public macro Route(onSuccess: Any.Type) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Chooses among the edges that share a source phase and an operation's failure.
///
/// The router takes the source phase payload and the operation's `Failure` value, and optionally the
/// operation's request, as the edges it selects may. Delivery runs it, and an owned source phase has a method
/// named after it in place of its candidate edges, which returns as an input router's owned method does.
///
/// - Parameter onFailure: The completing operation, written `<Operation>.self`.
@attached(peer)
public macro Route(onFailure: Any.Type) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")
