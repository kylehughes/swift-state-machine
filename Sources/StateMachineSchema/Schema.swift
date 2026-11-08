/// Selects ownership and isolation surfaces at expansion time.
nonisolated public enum StateMachineMode: Sendable {
    /// Copyable, Sendable values with explicit shared ownership.
    case shared
    /// Copyable values confined to one isolation domain.
    case isolated
    /// Unique payloads with explicit consuming transitions.
    case ownedOnly
}

/// The lexical trigger of an authored edge or router.
nonisolated public enum StateMachineTrigger: Sendable {
    /// A declared dynamic input case.
    case input(String)
    /// A declared operation's sealed successful outcome.
    case success(String)
    /// A declared operation's sealed failed outcome.
    case failure(String)
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
/// Schema, case, operation and edge names use unescaped Swift identifiers.
/// Generated facade names and required support-type spellings are reserved in the schema.
@attached(member, names: arbitrary)
public macro StateMachine(mode: StateMachineMode, initial: String, scopes: [String] = []) =
    #externalMacro(module: "StateMachineMacros", type: "StateMachineMacro")

/// Describes one synchronous authored transition for the enclosing schema.
@attached(peer)
public macro Transition(
    from: String,
    to: String,
    on: StateMachineTrigger,
    invalidates: [String] = [],
    starts: [String] = []
) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Binds one effect case to typed operation aliases and its lifetime metadata.
@attached(peer)
public macro Operation(
    effect: String,
    scope: String,
    requires: [String] = [],
    activeIn: [String],
    admission: StateMachineAdmission
) = #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")

/// Selects an explicit typed preparation when a trigger has several legal edges.
@attached(peer)
public macro Route(from: String, on: StateMachineTrigger) =
    #externalMacro(module: "StateMachineMacros", type: "MetadataMacro")
