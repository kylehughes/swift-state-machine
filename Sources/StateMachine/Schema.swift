/// Selects ownership and isolation surfaces at expansion time.
nonisolated public enum StateMachineMode: Sendable {
    /// Copyable, Sendable values with explicit shared ownership.
    case shared
    /// Copyable values confined to one isolation domain.
    case isolated
    /// Unique payloads with explicit consuming transitions.
    case ownedOnly
}

/// The admission policy for one operation and scope activation.
nonisolated public enum StateMachineAdmission: Sendable {
    /// Replaces older authority in the same operation group.
    case latest
    /// Rejects while an earlier group member remains active.
    case rejectWhenActive
    /// Allows at most the positive literal number of active group members.
    case parallel(limit: Int)
}

/// Expands a closed lexical enum schema into sealed ownership surfaces.
///
/// Phases are the enum's cases, each carrying a distinct nested payload type; `@Initial` marks the
/// starting phase. Inputs are the cases of a nested `Input` enum, and invalidation scopes are the
/// cases of an optional nested `Scope` enum, which a schema needs only when an operation names a
/// scope or an edge invalidates one. Other metadata is a reference the compiler resolves:
/// `Input.load`, `Scope.load`, `Loading.self`.
///
/// Every mode generates `Effect`, with one case per `@Operation` namespace, and the owners that
/// mode supports. The `.shared` and `.isolated` modes also generate typed work and completion
/// values for each operation and a `Restoration` enum for the phases a validator may restore. A
/// schema without operations generates no work, completion, command, or delivery surface.
///
/// A `Local` owner queues a command batch only for an acceptance that starts or cancels work, and
/// for closure, so it admits any number of other inputs without draining.
///
/// Schema, case, operation, and edge names use unescaped Swift identifiers.
/// Generated facade names and required support-type spellings are reserved in the schema.
@attached(member, names: arbitrary)
public macro StateMachine(mode: StateMachineMode) =
    #externalMacro(module: "StateMachineMacros", type: "StateMachineMacro")

/// Marks the phase case in which fresh authority is created.
///
/// Apply it to exactly one single-phase `case` declaration directly inside the schema.
///
/// This is the only case that may give its payload a default, as in `@Initial case idle(Idle = Idle())`.
/// Every fresh entry point then takes the initial payload as an optional argument: `owned(_:)`, `Local`,
/// `Shared`, `ActorHost`, and `MainActorHost`. The default is a call with no arguments that constructs the
/// payload, or calls a static function of the schema that returns it: `Idle()`, `makeIdle()`, or
/// `Lookup.makeIdle()`. The compiler checks the call, so a public schema needs a public initializer or
/// function. A `restoring:` initializer never has a default.
@attached(peer)
public macro Initial() = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Marks the function that validates saved data into a phase in which fresh authority is restored.
///
/// Apply it to at most one static function directly inside a `.shared` or `.isolated` schema. The
/// function takes the saved data as its one unlabeled parameter and returns the generated `Restoration`, which
/// has one case per phase in which no operation is active, plus one per phase listed in `allows`. It
/// may use typed throws to reject the data. Each generated owner except `Owned` then gains an
/// initializer labeled `restoring:` that calls it and creates fresh authority at revision zero in
/// the returned phase, with no outstanding work, exactly as a fresh owner starting in that phase.
/// Saved data never resumes work.
///
/// - Parameter allows: Phases that saved data may restore even when an operation may be active in
///   them, written `<Phase payload>.self`. A phase in which no operation is active is restorable
///   without being listed; listing it pins it, so it stays restorable if an operation later becomes
///   active there.
@attached(peer)
public macro Restoration(allows: [any (~Copyable).Type] = []) =
    #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Describes one synchronous authored transition taken when an input arrives.
///
/// The signature identifies the source and destination phases.
/// The first parameter is the source phase payload. Add a second parameter if the input case
/// carries a payload. Both parameters are unlabeled.
///
/// In `.shared` and `.isolated`, the source may be plain or `borrowing`. With an empty or omitted
/// `starts` list, return the destination payload. With a nonempty list, return
/// `Change<Destination, Effect.<Edge>>`. Either form may use typed throws.
///
/// In `.ownedOnly`, every edge takes a `consuming` source and cannot throw. Use the same return
/// types for success, or return `Advance<Source, Destination, Intent, Failure>` to give back the
/// source on rejection. `Intent` is `Never` for an empty or omitted `starts` list and
/// `Effect.<Edge>` for a nonempty list. The generated effect type contains only the listed operations.
///
/// - Parameters:
///   - on: The triggering case, written `Input.<case>`.
///   - invalidates: Scopes whose authority the edge revokes, written `Scope.<case>`.
///   - starts: Operations the edge may start, written `<Operation>.self`.
@attached(peer)
public macro Transition(on: Any, invalidates: [Any] = [], starts: [Any.Type] = []) =
    #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Describes one synchronous authored transition taken when an operation succeeds.
///
/// Delivery is the only way to prepare this edge for an owner, so the first outcome an owner
/// retains is the only one that can commit. An observed phase has no method for it; an `Owned`
/// phase has one that takes the operation's `Output`, unless a router chooses among this edge and
/// others, in which case the `Owned` phase has the router's method instead.
///
/// - Parameters:
///   - onSuccess: The completing operation, written `<Operation>.self`.
///   - invalidates: Scopes whose authority the edge revokes, written `Scope.<case>`.
///   - starts: Operations the edge may start, written `<Operation>.self`.
@attached(peer)
public macro Transition(onSuccess: Any.Type, invalidates: [Any] = [], starts: [Any.Type] = []) =
    #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Describes one synchronous authored transition taken when an operation fails.
///
/// Delivery is the only way to prepare this edge for an owner. An observed phase has no method
/// for it; an `Owned` phase has one that takes the operation's `Failure`, unless a router chooses
/// among this edge and others, in which case the `Owned` phase has the router's method instead.
///
/// - Parameters:
///   - onFailure: The completing operation, written `<Operation>.self`.
///   - invalidates: Scopes whose authority the edge revokes, written `Scope.<case>`.
///   - starts: Operations the edge may start, written `<Operation>.self`.
@attached(peer)
public macro Transition(onFailure: Any.Type, invalidates: [Any] = [], starts: [Any.Type] = []) =
    #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Declares one operation's typed aliases and its lifetime metadata.
///
/// The namespace is the operation's identity and declares `Input` and `Output` aliases, and a
/// `Failure` alias unless the operation cannot fail. Without one, `Failure` is `Never`, the
/// operation's driver returns its `Output` directly, and its completion and pending outcome carry
/// that output as a plain value instead of a `Result`. The generated `Effect` gains one case for it,
/// named by lower-casing the namespace's leading capitals: `Fetch` is requested with `.fetch(input)`.
///
/// - Parameters:
///   - scope: The primary scope whose authority the operation holds, written `Scope.<case>`.
///     Operations that share a primary scope declare the same `activeIn` phases, and an edge that
///     invalidates the scope revokes all of them. Without one, the operation holds a private scope
///     that is active exactly in its `activeIn` phases and that no edge can name.
///   - requires: Additional scopes the operation depends on, written `Scope.<case>`.
///   - activeIn: Phases in which the operation may run, written `<Phase payload>.self`. Leaving them
///     revokes the operation's work.
///   - admission: The policy for admitting concurrent work.
@attached(peer)
public macro Operation(
    scope: Any? = nil,
    requires: [Any] = [],
    activeIn: [any (~Copyable).Type],
    admission: StateMachineAdmission = .latest
) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Chooses among the edges that share a source phase and an input.
///
/// A router takes the source phase payload and, when the triggering case carries a payload, that
/// payload, as unlabeled parameters, and returns the generated `Route.<Router>` enum, which has
/// one case per candidate edge. It may use typed throws to decline. A router with no candidate
/// edge returns `Never` and throws.
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

/// Chooses among the edges that share a source phase and an operation's success.
///
/// The router takes the source phase payload and the operation's `Output` value, the same
/// parameters as the edge it selects. Delivery runs it, and an owned source phase has a method
/// named after it in place of its candidate edges, which returns as an input router's owned method does.
///
/// - Parameter onSuccess: The completing operation, written `<Operation>.self`.
@attached(peer)
public macro Route(onSuccess: Any.Type) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Chooses among the edges that share a source phase and an operation's failure.
///
/// The router takes the source phase payload and the operation's `Failure` value, the same
/// parameters as the edge it selects. Delivery runs it, and an owned source phase has a method
/// named after it in place of its candidate edges, which returns as an input router's owned method does.
///
/// - Parameter onFailure: The completing operation, written `<Operation>.self`.
@attached(peer)
public macro Route(onFailure: Any.Type) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")
