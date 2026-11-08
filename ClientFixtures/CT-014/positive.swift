// Appended to the exact production storage source by the compiler harness.
extension AtomicRecordStorage {
    private func synchronousLockControl() -> Version {
        storage.withLock { current in current }
    }
}
