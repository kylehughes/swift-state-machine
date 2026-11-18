/// Owns physical execution separately from operation authority and outcome delivery.
///
/// Hosts validate batch ownership and order before forwarding starts and cancellations.
/// Callbacks synchronously consult or update the host; none runs inside a worker task.
package actor RuntimeCoordinator<Descriptor: Sendable, Outcome: Sendable> {
    private struct Entry {
        let ticket: RuntimeTicket
        let identity: RuntimeIdentity
        let worker: Task<Outcome, Never>
        var watcher: Task<Void, Never>?
        var cancellationRequested = false
    }

    private let driver: @Sendable (Descriptor) async -> Outcome
    private let authorized: @Sendable (RuntimeTicket) -> Bool
    private let terminated: @Sendable (RuntimeTicket, Outcome, RuntimeCoordinator<Descriptor, Outcome>) -> Void
    private let skipped: @Sendable (RuntimeTicket) -> Void
    private var entries: [Entry] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Creates an execution owner with synchronous host authority and settlement hooks.
    package init(
        driver: @escaping @Sendable (Descriptor) async -> Outcome,
        authorized: @escaping @Sendable (RuntimeTicket) -> Bool,
        terminated: @escaping @Sendable (RuntimeTicket, Outcome, RuntimeCoordinator<Descriptor, Outcome>) -> Void,
        skipped: @escaping @Sendable (RuntimeTicket) -> Void
    ) {
        self.driver = driver
        self.authorized = authorized
        self.terminated = terminated
        self.skipped = skipped
    }

    deinit {
        for entry in entries {
            entry.worker.cancel()
            entry.watcher?.cancel()
        }
    }

    /// The number of workers whose actual termination has not yet been processed.
    package var runningCount: Int { entries.count }

    /// Registers each authorized start without suspending between its authority checks.
    ///
    /// An already registered ticket is ignored. Hosts prevent replay of completed batches.
    /// Revocation before registration skips the driver; revocation during registration
    /// cancels its retained handle and still requires actual termination.
    package func start(_ works: [RuntimeWork<Descriptor>]) {
        for work in works where !entries.contains(where: { $0.ticket == work.ticket }) {
            guard authorized(work.ticket) else {
                skipped(work.ticket)
                continue
            }

            let descriptor = work.descriptor
            let driver = driver
            let worker = Task.detached { await driver(descriptor) }
            let ticket = work.ticket
            let identity = RuntimeIdentity()
            entries.append(Entry(ticket: ticket, identity: identity, worker: worker))
            let index = entries.count - 1
            let watcher = Task.detached { [weak self] in
                let outcome = await worker.value
                await self?.complete(ticket, identity: identity, outcome: outcome)
            }
            entries[index].watcher = watcher

            if !authorized(ticket) {
                entries[index].cancellationRequested = true
                worker.cancel()
            }
        }
    }

    /// Requests cancellation while retaining handles until their drivers actually return.
    package func cancel(_ tickets: [RuntimeTicket]) {
        for ticket in tickets {
            guard let index = entries.firstIndex(where: { $0.ticket == ticket }),
                !entries[index].cancellationRequested
            else { continue }
            entries[index].cancellationRequested = true
            entries[index].worker.cancel()
        }
    }

    /// Waits until no registered worker remains, including workers registered during the wait.
    ///
    /// Cancelling the waiting task neither ends the wait early nor acknowledges driver termination.
    package func join() async {
        guard !entries.isEmpty else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func complete(_ ticket: RuntimeTicket, identity: RuntimeIdentity, outcome: Outcome) {
        guard let index = entries.firstIndex(where: { $0.ticket == ticket && $0.identity === identity }) else {
            return
        }
        entries.remove(at: index)
        terminated(ticket, outcome, self)
        guard entries.isEmpty else { return }
        let completed = waiters
        waiters = []
        for waiter in completed { waiter.resume() }
    }
}
