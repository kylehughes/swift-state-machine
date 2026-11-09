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
/// The schema names nothing with strings. Phases are the enum's cases, each carrying a distinct
/// nested payload type; `@Initial` marks the starting phase. Invalidation scopes are the cases of
/// an optional nested `Scope` enum. Every other piece of metadata is a reference the compiler
/// resolves: `Input.load`, `Effect.fetch`, `Scope.load`, `Loading.self`.
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

/// Describes one synchronous authored transition taken when an input arrives.
///
/// The edge's endpoints are its signature: the first parameter's type is the source phase payload
/// and the returned `Change` or `Advance` names the destination phase payload.
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
/// The namespace is the operation's identity. Exactly one `Effect` case requests it, by carrying
/// the namespace's `Input` alias: `case fetch(Fetch.Input)`.
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

/// Selects an explicit typed preparation when an input has several legal edges.
///
/// The source phase is the router's `Observed<Source>` parameter.
///
/// - Parameter on: The triggering case, written `Input.<case>`.
@attached(peer)
public macro Route(on: Any) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Selects an explicit typed preparation when an operation's success has several legal edges.
///
/// - Parameter onSuccess: The completing operation, written `<Operation>.self`.
@attached(peer)
public macro Route(onSuccess: Any.Type) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Selects an explicit typed preparation when an operation's failure has several legal edges.
///
/// - Parameter onFailure: The completing operation, written `<Operation>.self`.
@attached(peer)
public macro Route(onFailure: Any.Type) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")
