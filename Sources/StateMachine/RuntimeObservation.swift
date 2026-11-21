import Observation

/// The Observation tokens of one `MainActor` owner.
///
/// Each token stands for one value a reader can track: the snapshot, the running count, the subscriber
/// count, and the retained completions. A read registers only its own token, so a change to one value
/// does not invalidate a reader of another. Where the Observation framework is unavailable, reading and
/// reporting do nothing, and the registrar is never created.
@MainActor package final class RuntimeObservation {
    /// One tracked value of a `MainActor` owner.
    package enum Token {
        case snapshot
        case runningCount
        case subscriberCount
        case pendingCompletions
    }

    // An `ObservationRegistrar` cannot be a stored property below iOS 17, so it is boxed and created only
    // where it exists.
    private let registrar: AnyObject?

    package init() {
        if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *) {
            registrar = RuntimeObservationRegistrar()
        } else {
            registrar = nil
        }
    }

    // The key paths Observation tracks. Each is a stored property with its own storage, so the four key
    // paths stay distinct however the getters are optimized or linked; the stored values are never read.
    private let snapshot: UInt8 = 0
    private let runningCount: UInt8 = 0
    private let subscriberCount: UInt8 = 0
    private let pendingCompletions: UInt8 = 0

    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *)
    private func keyPath(_ token: Token) -> KeyPath<RuntimeObservation, UInt8> {
        switch token {
        case .snapshot: \.snapshot
        case .runningCount: \.runningCount
        case .subscriberCount: \.subscriberCount
        case .pendingCompletions: \.pendingCompletions
        }
    }

    /// Registers a read of `token` with any active Observation tracking.
    package func access(_ token: Token) {
        guard #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *) else {
            return
        }
        guard let box = registrar as? RuntimeObservationRegistrar else { return }
        box.registrar.access(self, keyPath: keyPath(token))
    }

    /// Reports that the value behind `token` has already changed.
    ///
    /// Observers run synchronously, so the owner calls this only after its mutation has finished.
    package func changed(_ token: Token) {
        guard #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *) else {
            return
        }
        guard let box = registrar as? RuntimeObservationRegistrar else { return }
        box.registrar.withMutation(of: self, keyPath: keyPath(token)) {}
    }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *)
extension RuntimeObservation: Observable {}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *)
private final class RuntimeObservationRegistrar: Sendable {
    let registrar = ObservationRegistrar()
}
