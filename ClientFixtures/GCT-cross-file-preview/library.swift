import StateMachine

/// A separate-module isolated state machine used to verify inline `MainActorHost()` inside `#Preview`.
@StateMachine(mode: .isolated, owners: [.owned, .local, .mainActorHost])
public nonisolated enum ImportedPreviewMachine {
    /// Initial configuration phase.
    public struct Configuring {
        /// Creates the initial configuration payload.
        public init() {}
    }

    /// Terminal saved phase.
    public struct Saved {
        /// Creates the saved payload.
        public init() {}
    }

    @Initial
    case configuring(Configuring = Configuring())
    @Terminal
    case saved(Saved)

    /// Dynamic inputs accepted by the preview machine.
    public enum Input {
        case save
    }

    @Transition(on: Input.save)
    fileprivate static func save(_ source: Configuring) -> Saved {
        Saved()
    }
}
