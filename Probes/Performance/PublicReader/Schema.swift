import StateMachine

/// Compact public `.isolated`, `.local` schema for cross-module `Observed<Phase>.value` reads.
@StateMachine(mode: .isolated, owners: [.local])
nonisolated public enum PublicReaderFlow {
    /// Reference-backed handle carried in phase payloads.
    public final class Handle {
        /// Stable numeric identifier.
        public let id: UInt64
        /// Label text.
        public let label: String
        /// Creates a handle.
        public init(id: UInt64, label: String) { (self.id, self.label) = (id, label) }
    }

    /// Initial phase payload.
    public struct Idle {
        /// Reference handle.
        public let handle: Handle
        /// Creates an initial payload.
        public init(handle: Handle) { self.handle = handle }
    }

    /// Active phase with nontrivial reference-containing fields and a scalar score.
    public struct Active {
        /// Document title.
        public let title: String
        /// Secondary subtitle.
        public let subtitle: String
        /// Tag list.
        public let tags: [String]
        /// Key-value metadata.
        public let metadata: [String: String]
        /// Reference handle.
        public let handle: Handle
        /// Numeric score.
        public let score: UInt64
        /// Creates an active payload.
        public init(
            title: String,
            subtitle: String,
            tags: [String],
            metadata: [String: String],
            handle: Handle,
            score: UInt64
        ) {
            self.title = title
            self.subtitle = subtitle
            self.tags = tags
            self.metadata = metadata
            self.handle = handle
            self.score = score
        }
    }

    /// Terminal phase payload.
    public struct Done {
        /// Archived title.
        public let finalTitle: String
        /// Creates a terminal payload.
        public init(finalTitle: String) { self.finalTitle = finalTitle }
    }

    @Initial case idle(Idle)
    case active(Active)
    @Terminal case done(Done)

    /// Dynamic inputs advancing the owner from `idle` through `active` to `done`.
    public enum Input {
        case activate(Active)
        case update(Active)
        case finish(String)
    }

    @Transition(on: Input.activate)
    fileprivate static func activate(_ source: Idle, _ next: Active) -> Active { next }

    @Transition(on: Input.update)
    fileprivate static func update(_ source: Active, _ next: Active) -> Active { next }

    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Active, _ title: String) -> Done { Done(finalTitle: title) }
}
