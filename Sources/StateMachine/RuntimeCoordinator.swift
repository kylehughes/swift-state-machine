import os

/// Owns physical execution separately from operation authority and outcome delivery.
///
/// Hosts validate batch ownership and order before forwarding starts and cancellations.
/// Callbacks synchronously consult or update the host, and none runs inside a worker task.
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
    private var entries: [Entry] = [] {
        didSet {
            let count = entries.count
            registered.withLock { $0 = count }
        }
    }
    private var waiters: [CheckedContinuation<Void, Never>] = []
    // Mirrors the entry count for synchronous readers and carries no authority.
    private nonisolated let registered = OSAllocatedUnfairLock(initialState: 0)

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

    /// The same count, read without entering the actor.
    package nonisolated var currentRunningCount: Int { registered.withLock { $0 } }

    /// Registers each authorized start without suspending between its authority checks.
    ///
    /// An already registered ticket is ignored. Hosts prevent replay of completed batches.
    /// Revocation before registration skips the driver. Revocation during registration
    /// cancels its retained handle and still requires actual termination.
    package func start(_ works: [RuntimeWork<Descriptor>]) {
        for work in works where !entries.contains(where: { $0.ticket == work.ticket }) {
            guard authorized(work.ticket) else {
                skipped(work.ticket)
                continue
            }

            let descriptor = work.descriptor
            let driver = driver
            let ticket = work.ticket
            let pause = DriverStartPause.beforeStarting
            let worker = Task.detached {
                pause?(ticket)
                return await driver(descriptor)
            }
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

/// A pause that a test inserts at the start of a detached driver task, which a `Shared` owner's
/// coordinator and an `ActorHost` launch, before the driver runs, with the ticket of the work it drives.
///
/// A detached task inherits no task-local value, so the owner reads the pause once where it launches
/// the driver task, on the task that processes the batch, and the driver task runs that value. The
/// task that processes the batch inherits the value from the call that scheduled that processing,
/// which can be an earlier call of the same owner, such as a registration, so a test binds the pause
/// around the owner's creation and every call up to the one that launches the work. A confined owner's
/// driver task runs on the owner's actor, which the pause would block, so it has none. It is `nil`
/// everywhere else.
nonisolated package enum DriverStartPause {
    @TaskLocal package static var beforeStarting: (@Sendable (RuntimeTicket) -> Void)?
}
