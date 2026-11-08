// Appended to the exact production storage source by the compiler harness.
extension AtomicRecordStorage {
    private func forbiddenAsyncLock() async -> Version {
        await storage.withLock { current in
            await Task.yield()
            return current
        }
    }
}
