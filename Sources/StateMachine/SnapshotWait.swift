/// How a bounded or unbounded wait on a ``SnapshotSequence`` ended.
nonisolated public enum SnapshotWaitResult<Element> {
    /// An element satisfied the predicate before the wait ended.
    case matched(Element)
    /// The deadline passed before any element satisfied the predicate.
    case timedOut
    /// The calling task was cancelled before a matching element arrived.
    case cancelled
    /// The sequence ended before any element satisfied the predicate, for example because its owner
    /// closed or was released, or because the sequence was already consumed or cancelled externally.
    case ended
}

extension SnapshotWaitResult: Sendable where Element: Sendable {}
extension SnapshotWaitResult: Equatable where Element: Equatable {}
extension SnapshotWaitResult: Hashable where Element: Hashable {}

extension SnapshotSequence {
    // Maximum consecutive non-suspending elements evaluated in one turn before yielding the
    // caller's actor, matching `drainTurn` and `SnapshotPublisher` turn fairness.
    private static var synchronousTurnLimit: Int { 32 }

    /// Waits until an element satisfies `predicate`, optionally bounded by `deadline` on
    /// `ContinuousClock`.
    ///
    /// The wait runs on the caller's isolation (`nonisolated(nonsending)`), so `predicate` stays
    /// on the caller's actor without needing `@Sendable`. Claiming the sequence follows the same
    /// single-pass rule as ``makeAsyncIterator()``: if another consumer already claimed this
    /// sequence, this method returns ``SnapshotWaitResult/ended`` immediately without disturbing
    /// that consumer.
    ///
    /// Once claimed, this method always cancels the sequence on the caller's isolation before
    /// returning, freeing its subscriber slot according to ``cancel(isolation:)``.
    ///
    /// - Parameters:
    ///   - deadline: The `ContinuousClock` instant at which waiting stops, or `nil` to wait until
    ///     a match, task cancellation, or sequence completion.
    ///   - predicate: Returns `true` for the first element that should satisfy the wait.
    /// - Returns: Whether an element matched, the deadline passed, the calling task was cancelled,
    ///   or the sequence ended first.
    nonisolated(nonsending) public func wait(
        deadline: ContinuousClock.Instant? = nil,
        where predicate: (Element) -> Bool
    ) async -> SnapshotWaitResult<Element> {
        if let deadline {
            return await wait(deadline: deadline, clock: ContinuousClock(), where: predicate)
        }
        guard let consumer = claim() else { return .ended }
        defer { cancel(isolation: #isolation) }
        if Task.isCancelled { return .cancelled }
        var synchronousReads = 0
        while true {
            let (step, suspended) = await consumer.nextStep()
            if suspended { synchronousReads = 0 }
            switch step {
            case .element(let element):
                if predicate(element) { return .matched(element) }
                if Task.isCancelled { return .cancelled }
                synchronousReads += 1
                if synchronousReads == Self.synchronousTurnLimit {
                    synchronousReads = 0
                    await Task.yield()
                    if Task.isCancelled { return .cancelled }
                }
            case .finished:
                return .ended
            case .timedOut:
                return .timedOut
            case .cancelled:
                return Task.isCancelled ? .cancelled : .ended
            }
        }
    }

    /// Waits until an element satisfies `predicate` or `timeout` elapses on `ContinuousClock`.
    ///
    /// Equivalent to calling ``wait(deadline:clock:where:)`` with
    /// `ContinuousClock.now.advanced(by: timeout)` and `ContinuousClock()`.
    ///
    /// - Parameters:
    ///   - timeout: How long to wait from now before returning ``SnapshotWaitResult/timedOut``.
    ///   - predicate: Returns `true` for the first element that should satisfy the wait.
    /// - Returns: Whether an element matched, `timeout` elapsed, the calling task was cancelled,
    ///   or the sequence ended first.
    nonisolated(nonsending) public func wait(
        timeout: Duration,
        where predicate: (Element) -> Bool
    ) async -> SnapshotWaitResult<Element> {
        await wait(
            deadline: ContinuousClock.now.advanced(by: timeout),
            clock: ContinuousClock(),
            where: predicate
        )
    }

    /// Waits until an element satisfies `predicate` or `deadline` passes on `clock`.
    ///
    /// The wait runs on the caller's isolation (`nonisolated(nonsending)`), so `predicate` stays
    /// on the caller's actor without needing `@Sendable`. Passing a custom `Clock` allows
    /// deterministic deadline testing without wall-clock sleeps.
    ///
    /// ### Ordering and tie rules
    ///
    /// 1. **Single-pass ownership**: If another iterator or `wait` already claimed this sequence,
    ///    returns ``SnapshotWaitResult/ended`` immediately without cancelling the existing consumer.
    /// 2. **Caller cancellation on entry**: If `Task.isCancelled` is already `true`, cancels this
    ///    sequence and returns ``SnapshotWaitResult/cancelled`` without evaluating `predicate` or
    ///    starting a timer.
    /// 3. **Already-buffered element before deadline**: Synchronously drains any element already
    ///    buffered in the sequence before checking `clock.now >= deadline`. On `MainActorHost`,
    ///    `ActorHost`, `IsolatedHost`, and an already-closed `Shared` owner, registration buffers
    ///    the initial snapshot synchronously, so an already-matching state returns
    ///    ``SnapshotWaitResult/matched(_:)`` without starting a timer, even when `deadline` has
    ///    already passed. On an open `Shared` owner, the initial snapshot arrives asynchronously
    ///    from its serial delivery mailbox; check `host.snapshot()` before registering when a
    ///    synchronous already-matching fast path is needed.
    /// 4. **Concurrent timeout vs buffered element**: When the deadline fires, an element already
    ///    buffered in or handed to the sequence still finishes delivery and is tested against
    ///    `predicate`; ``SnapshotWaitResult/timedOut`` is returned only if no buffered element
    ///    matches.
    /// 5. **First terminal cause wins**: Under the sequence's lock, whichever of owner completion
    ///    (`finish`), deadline expiry, or cancellation records the end first determines whether
    ///    the result is ``SnapshotWaitResult/ended``, ``SnapshotWaitResult/timedOut``, or
    ///    ``SnapshotWaitResult/cancelled`` (an external ``cancel(isolation:)`` without calling-task
    ///    cancellation reports ``SnapshotWaitResult/ended``). If calling-task cancellation aborts
    ///    reading an element that was still buffered after closure or deadline expiry, the wait
    ///    reports ``SnapshotWaitResult/cancelled`` rather than claiming that buffered element
    ///    failed to match.
    /// 6. **Turn fairness and subscription cleanup**: Under continuous non-matching offers, `wait`
    ///    yields the caller's actor after 32 consecutive synchronous evaluations so other work on
    ///    that actor is not starved. On every exit path after claiming, the timer task is cancelled
    ///    and ``cancel(isolation:)`` runs on the caller's isolation before this method returns.
    ///    Because `SnapshotSequence` is latest-value (capacity one), intermediate transitions that
    ///    both enter and leave a matching state before the wait reads them can coalesce.
    ///
    /// - Parameters:
    ///   - deadline: The instant on `clock` at which waiting stops.
    ///   - clock: The clock used to measure `deadline`.
    ///   - predicate: Returns `true` for the first element that should satisfy the wait.
    /// - Returns: Whether an element matched, `deadline` passed, the calling task was cancelled,
    ///   or the sequence ended first.
    nonisolated(nonsending) public func wait<C: Clock>(
        deadline: C.Instant,
        clock: C,
        where predicate: (Element) -> Bool
    ) async -> SnapshotWaitResult<Element> {
        guard let consumer = claim() else { return .ended }
        defer { cancel(isolation: #isolation) }
        if Task.isCancelled { return .cancelled }

        var synchronousReads = 0
        while let step = consumer.pollStep(expiring: clock.now >= deadline) {
            switch step {
            case .element(let element):
                if predicate(element) { return .matched(element) }
                if Task.isCancelled { return .cancelled }
                synchronousReads += 1
                if synchronousReads == Self.synchronousTurnLimit {
                    synchronousReads = 0
                    if clock.now < deadline {
                        await Task.yield()
                        if Task.isCancelled { return .cancelled }
                    }
                }
            case .finished:
                return .ended
            case .timedOut:
                return .timedOut
            case .cancelled:
                return Task.isCancelled ? .cancelled : .ended
            }
        }

        let timer = Task {
            do {
                try await clock.sleep(until: deadline, tolerance: nil)
                guard !Task.isCancelled else { return }
                consumer.timeOut()
            } catch {}
        }
        defer { timer.cancel() }

        synchronousReads = 0
        while true {
            if clock.now >= deadline { consumer.timeOut() }
            let (step, suspended) = await consumer.nextStep()
            if suspended { synchronousReads = 0 }
            switch step {
            case .element(let element):
                if predicate(element) { return .matched(element) }
                if Task.isCancelled { return .cancelled }
                synchronousReads += 1
                if synchronousReads == Self.synchronousTurnLimit {
                    synchronousReads = 0
                    if clock.now < deadline {
                        await Task.yield()
                        if Task.isCancelled { return .cancelled }
                    }
                }
            case .finished:
                return .ended
            case .timedOut:
                return .timedOut
            case .cancelled:
                return Task.isCancelled ? .cancelled : .ended
            }
        }
    }
}
