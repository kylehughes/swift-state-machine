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
/// cases of an optional nested `Scope` enum. Other metadata is a reference the compiler resolves:
/// `Input.load`, `Scope.load`, `Loading.self`.
///
/// The expansion generates `Effect`, with one case per `@Operation` namespace, the owners the
/// mode permits, and the typed work and completion values for each operation. The `.shared` and
/// `.isolated` modes also generate `Restoration`, the phases a `@Restoration` function may restore.
///
/// Schema, case, operation and edge names use unescaped Swift identifiers.
/// Generated facade names and required support-type spellings are reserved in the schema.
@attached(member, names: arbitrary)
public macro StateMachine(mode: StateMachineMode) =
    #externalMacro(module: "StateMachineMacros", type: "StateMachineMacro")

/// Marks the phase case in which fresh authority is created.
///
/// Apply it to exactly one single-phase `case` declaration directly inside the schema.
@attached(peer)
public macro Initial() = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Marks the function that validates saved data into a phase in which fresh authority is restored.
///
/// Apply it to at most one static function directly inside a `.shared` or `.isolated` schema. The
/// function takes the saved data as its one parameter and returns the generated `Restoration`, which
/// has one case per phase in which no operation is active, so saved data can never resume work. It
/// may use typed throws to reject the data. Each generated owner except `Owned` then gains an
/// initializer labeled `restoring:` that calls it and creates fresh authority at revision zero in
/// the returned phase.
@attached(peer)
public macro Restoration() = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Describes one synchronous authored transition taken when an input arrives.
///
/// The edge's endpoints are its signature. The first parameter is the source phase payload. An
/// edge that starts no operation returns the destination phase payload itself. An edge with a
/// `starts` list returns `Change<Destination, Effect.<Edge>>`, where the generated `Effect.<Edge>`
/// holds only the listed operations, so no other effect can be emitted.
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
/// - Parameters:
///   - onSuccess: The completing operation, written `<Operation>.self`.
///   - invalidates: Scopes whose authority the edge revokes, written `Scope.<case>`.
///   - starts: Operations the edge may start, written `<Operation>.self`.
@attached(peer)
public macro Transition(onSuccess: Any.Type, invalidates: [Any] = [], starts: [Any.Type] = []) =
    #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Describes one synchronous authored transition taken when an operation fails.
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
/// The namespace is the operation's identity and declares `Input`, `Output` and `Failure`
/// aliases. The generated `Effect` gains one case for it, named by lower-casing the namespace's
/// leading capitals: `Fetch` is requested with `.fetch(input)`.
///
/// - Parameters:
///   - scope: The primary scope whose authority the operation holds, written `Scope.<case>`.
///   - requires: Additional scopes the operation depends on, written `Scope.<case>`.
///   - activeIn: Phases in which the operation may run, written `<Phase payload>.self`.
///   - admission: The policy for admitting concurrent work.
@attached(peer)
public macro Operation(
    scope: Any,
    requires: [Any] = [],
    activeIn: [any (~Copyable).Type],
    admission: StateMachineAdmission
) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Chooses among the edges that share a source phase and an input.
///
/// A router takes the source phase payload and the input's payload, and returns the generated
/// `Route.<Router>` enum, which has one case per candidate edge. It may use typed throws to
/// decline. A router with no candidate edge returns `Never` and throws.
///
/// - Parameter on: The triggering case, written `Input.<case>`.
@attached(peer)
public macro Route(on: Any) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Chooses among the edges that share a source phase and an operation's success.
///
/// The router takes the source phase payload and the operation's `Output` value, the same
/// parameters as the edge it selects.
///
/// - Parameter onSuccess: The completing operation, written `<Operation>.self`.
@attached(peer)
public macro Route(onSuccess: Any.Type) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Chooses among the edges that share a source phase and an operation's failure.
///
/// The router takes the source phase payload and the operation's `Failure` value, the same
/// parameters as the edge it selects.
///
/// - Parameter onFailure: The completing operation, written `<Operation>.self`.
@attached(peer)
public macro Route(onFailure: Any.Type) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")
