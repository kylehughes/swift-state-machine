import StateMachine
import Testing
import os

@Suite struct AtomicRecordStorageTests {
    nonisolated final class Probe: Sendable {
        let onRelease: @Sendable () -> Void
        init(_ onRelease: @escaping @Sendable () -> Void) { self.onRelease = onRelease }
        deinit { onRelease() }
    }

    @Test func retiringAndRejectedPayloadsCanReenter_RT024() {
        let storage = AtomicRecordStorage<Probe?>(nil)
        let releases = OSAllocatedUnfairLock(initialState: 0)
        func replace() {
            let initial = storage.load()
            let payload = AtomicRecordStorage<Probe?>
                .Version(
                    Probe {
                        _ = storage.load()
                        releases.withLock { $0 += 1 }
                    }
                )
            #expect(storage.install(payload, replacing: initial))
            let empty = AtomicRecordStorage<Probe?>.Version(nil)
            #expect(storage.install(empty, replacing: payload))
            let rejected = AtomicRecordStorage<Probe?>
                .Version(
                    Probe {
                        _ = storage.load()
                        releases.withLock { $0 += 1 }
                    }
                )
            #expect(!storage.install(rejected, replacing: initial))
        }
        replace()
        #expect(releases.withLock { $0 } == 2)
        #expect(storage.load().value == nil)
    }

    @Test func equalPayloadCannotReuseVersionIdentity_RT005() {
        let storage = AtomicRecordStorage(1)
        let first = storage.load()
        let second = AtomicRecordStorage<Int>.Version(2)
        let third = AtomicRecordStorage<Int>.Version(1)
        #expect(storage.install(second, replacing: first))
        #expect(storage.install(third, replacing: second))
        #expect(!storage.install(.init(3), replacing: first))
        #expect(storage.load().value == 1)
    }
}
