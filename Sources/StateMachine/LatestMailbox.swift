// A capacity-one serial mailbox. Client callbacks and displaced payload releases
// execute after the installation primitive has released its lock.
nonisolated package final class LatestMailbox<Value: Sendable>: Sendable {
    private struct Envelope: Sendable {
        let ordinal: UInt64
        let value: Value
        let terminal: Bool
    }
    private struct State: Sendable {
        var watermark: UInt64?
        var pending: Envelope?
        var scheduled = false
        var closed = false
    }
    private let storage: AtomicRecordStorage<State>
    private let receive: @Sendable (Value) -> Void
    private let finish: @Sendable () -> Void

    package init(
        initial: Value,
        ordinal: UInt64,
        terminal: Bool,
        receive: @escaping @Sendable (Value) -> Void,
        finish: @escaping @Sendable () -> Void
    ) {
        storage = AtomicRecordStorage(
            State(
                watermark: ordinal,
                pending: Envelope(ordinal: ordinal, value: initial, terminal: terminal)
            )
        )
        self.receive = receive
        self.finish = finish
    }

    // Called only after successful registration; a newer offer may already own
    // the same serial delivery loop and may have replaced the staged initial value.
    package func activate() {
        while true {
            let previous = storage.load()
            guard !previous.value.closed, !previous.value.scheduled, previous.value.pending != nil else { return }
            var next = previous.value
            next.scheduled = true
            if storage.install(AtomicRecordStorage.Version(next), replacing: previous) {
                Task { self.deliver() }
                return
            }
        }
    }

    package func offer(_ value: Value, ordinal: UInt64, terminal: Bool) {
        while true {
            let previous = storage.load()
            guard !previous.value.closed,
                previous.value.watermark.map({ ordinal > $0 }) ?? true
            else { return }
            var next = previous.value
            next.watermark = ordinal
            next.pending = Envelope(ordinal: ordinal, value: value, terminal: terminal)
            let wake = !next.scheduled
            next.scheduled = true
            if storage.install(AtomicRecordStorage.Version(next), replacing: previous) {
                if wake { Task { self.deliver() } }
                return
            }
        }
    }

    package func cancel() {
        while true {
            let previous = storage.load()
            guard !previous.value.closed else { return }
            var next = previous.value
            next.closed = true
            next.pending = nil
            if storage.install(AtomicRecordStorage.Version(next), replacing: previous) { return }
        }
    }

    private func deliver() {
        var delivered = 0
        while true {
            let previous = storage.load()
            var next = previous.value
            guard !next.closed, let envelope = next.pending else {
                next.scheduled = false
                if storage.install(AtomicRecordStorage.Version(next), replacing: previous) { return }
                continue
            }
            next.pending = nil
            if envelope.terminal { next.closed = true }
            guard storage.install(AtomicRecordStorage.Version(next), replacing: previous) else { continue }
            // Claiming an envelope is the invocation boundary. Cancellation can leave
            // this one in-flight callback, but no later callback is claimed.
            receive(envelope.value)
            if envelope.terminal {
                finish()
                return
            }
            delivered += 1
            if delivered == 32 {
                Task {
                    await Task.yield()
                    self.deliver()
                }
                return
            }
        }
    }
}
