import os

/// A lower-guarantee immutable-record installation primitive for generated runtimes.
///
/// This storage provides identity-checked atomic replacement only. It does not validate
/// domain transitions, issue authority, execute effects, or provide value semantics for
/// reference-bearing payloads. Generated facades keep their instance and versions private.
/// Prepare records before calling `install(_:replacing:)`. No client callback runs while the lock is held.
nonisolated public final class AtomicRecordStorage<Value: Sendable>: Sendable {
    /// An immutable retained record and its unique installation identity.
    public final class Version: Sendable {
        /// The immutable record supplied by its creator.
        public let value: Value
        /// Creates a fresh version identity containing the supplied record.
        public init(_ value: Value) { self.value = value }
    }

    private let storage: OSAllocatedUnfairLock<Version>

    /// Creates independent storage with an initial version.
    public init(_ value: Value) { storage = OSAllocatedUnfairLock(initialState: Version(value)) }

    /// Retains the current version without exposing protected mutable storage.
    public func load() -> Version { storage.withLock { $0 } }

    /// Reports whether a captured record is still the current one.
    public func isCurrent(_ expected: Version) -> Bool {
        let result = storage.withLock { $0 === expected }
        return withExtendedLifetime(expected) { result }
    }

    /// Replaces the current record only when its identity matches `expected`.
    ///
    /// Returns whether replacement occurred. Retired records are kept alive until after unlocking,
    /// and a failed comparison leaves the current record unchanged.
    public func install(_ next: Version, replacing expected: Version) -> Bool {
        let retirement: Version? = storage.withLock { current in
            guard current === expected else { return nil }
            let retired = current
            current = next
            return retired
        }
        return withExtendedLifetime((expected, next, retirement)) { retirement != nil }
    }
}
