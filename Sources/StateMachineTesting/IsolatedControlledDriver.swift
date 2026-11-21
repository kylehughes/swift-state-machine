import os

/// A driver confined to one actor whose every call waits until the test decides how it ends.
///
/// It behaves as ``ControlledDriver`` does, for an `IsolatedHost` whose inputs and outputs need not be
/// `Sendable`, such as one of an `.isolated` graph. The driver, its calls, and their values stay with
/// the actor that owns the host: the actor stores the driver, its driver closure reaches the driver
/// through the actor it receives, and the test awaits
/// ``nextStarted(isolation:fileID:filePath:line:column:)`` on that actor:
///
/// ```swift
/// actor Editor {
///     let save = IsolatedControlledDriver<Editor, GeneratedNote.Draft, GeneratedNote.Saved, Never>()
///     private(set) var host: GeneratedNote.IsolatedHost<Editor>!
///
///     init() async {
///         host = GeneratedNote.IsolatedHost(
///             isolation: self,
///             saveDriver: { editor, draft in await editor.save.run(editor, draft) }
///         )
///     }
///
///     func save(as text: String) async throws {
///         try host.send(.edit(text))
///         try host.send(.save)
///         let call = try await save.nextStarted()
///         call.succeed(GeneratedNote.Saved(text: call.input().text))
///     }
/// }
/// ```
///
/// Every method that reaches a call's values takes the owning actor as an `isolated` parameter, which
/// a call on that actor passes by default: a call from another actor, or from a nonisolated context
/// such as the destructor of an ordinary class, does not compile. The first use binds the driver to
/// one instance of `Owner`, and a use that passes another instance stops the program. A call's
/// output stays on the actor too, so a test can finish a call with a value that shares state with its
/// input.
///
/// A call ignores cancellation, as a driver that does not check for it would. When the host cancels
/// the call's task, ``Call/isCancelled`` becomes `true` and
/// ``Call/waitForCancellation(isolation:fileID:filePath:line:column:)`` returns, and the call keeps running
/// until the test finishes it. A call that the test never finishes never returns, and the host's
/// shutdown waits for it.
///
/// The driver grants no authority: it supplies a result to the host's own work, which only the host
/// can deliver.
nonisolated public final class IsolatedControlledDriver<Owner: Actor, Input, Output, Failure: Error> {
    /// One started execution of the operation, which the test finishes on the owning actor.
    public final class Call {
        private let payload: Input
        fileprivate let completion: IsolatedCallCompletion<Owner, Output, Failure>

        fileprivate init(input: Input, owner: Owner) {
            payload = input
            completion = IsolatedCallCompletion(owner: owner)
        }

        /// The input the host started this execution with.
        public func input(isolation: isolated Owner = #isolation) -> Input {
            completion.check(isolation)
            return payload
        }

        /// Whether the test has finished this execution.
        public var isFinished: Bool { completion.isFinished }
        /// Whether the host has cancelled this execution's task.
        public var isCancelled: Bool { completion.signal.isCancelled }

        /// Ends the execution with `result`; it reports `false` and changes nothing if it already ended.
        @discardableResult public func finish(
            _ result: Result<Output, Failure>,
            isolation: isolated Owner = #isolation
        ) -> Bool {
            completion.finish(result, isolation: isolation)
        }
        /// Ends the execution with a successful output.
        @discardableResult public func succeed(_ output: Output, isolation: isolated Owner = #isolation) -> Bool {
            completion.finish(.success(output), isolation: isolation)
        }
        /// Ends the execution with a typed failure.
        @discardableResult public func fail(_ failure: Failure, isolation: isolated Owner = #isolation) -> Bool {
            completion.finish(.failure(failure), isolation: isolation)
        }

        /// Returns once the host has cancelled this execution's task.
        ///
        /// The execution keeps running afterward until the test finishes it. It throws when the
        /// waiting task is cancelled first, for example by a test's time limit.
        public func waitForCancellation(
            isolation: isolated Owner = #isolation,
            fileID: String = #fileID,
            filePath: String = #filePath,
            line: Int = #line,
            column: Int = #column
        ) async throws(StateMachineTestFailure) {
            completion.check(isolation)
            try await awaitCancellation(
                completion.signal,
                fileID: fileID,
                filePath: filePath,
                line: line,
                column: column
            )
        }
    }

    private let calls = IsolatedCallQueue<Call>()
    private let binding = OwnerBinding<Owner>()

    /// Creates a driver with no started calls.
    public init() {}

    /// How many executions the host has started.
    public var startedCount: Int { calls.startedCount }

    /// How many queued calls and waits matching has examined, which tests read as its work; read it on
    /// the owning actor.
    package var examinedCallEntries: Int { calls.examinedEntries }
    /// How many queued calls and waits the driver stores, which tests read as its storage; read it on
    /// the owning actor.
    package var storedCallEntries: Int { calls.storedEntries }
    /// How many waits for a started call have registered and not ended; read it on the owning actor.
    package var waitingCount: Int { calls.waitCount }

    /// Returns the oldest started execution not yet returned, waiting on the owning actor until the
    /// host starts one.
    ///
    /// It throws when the waiting task is cancelled first, for example by a test's time limit; a
    /// task that is already cancelled leaves every started execution for a later wait.
    public func nextStarted(
        isolation: isolated Owner = #isolation,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) async throws(StateMachineTestFailure) -> Call {
        binding.check(isolation)
        return try await awaitNextIsolatedCall(
            calls,
            where: nil,
            awaited: "another call",
            isolation: isolation,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    /// The driver of a fallible operation: it waits until the test finishes the call.
    public func run(_ owner: isolated Owner, _ input: Input) async -> Result<Output, Failure> {
        binding.check(owner)
        let call = Call(input: input, owner: owner)
        let calls = calls
        return await call.completion.wait(offering: { calls.offer(call) }, isolation: owner)
    }
}

extension IsolatedControlledDriver where Failure == Never {
    /// The driver of an operation that cannot fail: it returns the output the test supplies.
    public func run(_ owner: isolated Owner, _ input: Input) async -> Output {
        switch await run(owner, input) as Result<Output, Never> {
        case .success(let output): output
        }
    }
}

extension IsolatedControlledDriver where Input == Void {
    /// The driver of a fallible operation that takes no input.
    public func run(_ owner: isolated Owner) async -> Result<Output, Failure> { await run(owner, ()) }
}

extension IsolatedControlledDriver where Input == Void, Failure == Never {
    /// The driver of an operation that takes no input and cannot fail.
    public func run(_ owner: isolated Owner) async -> Output { await run(owner, ()) }
}

extension IsolatedControlledDriver.Call where Output == Void {
    /// Ends an execution that produces no value successfully.
    @discardableResult public func succeed(isolation: isolated Owner = #isolation) -> Bool {
        succeed((), isolation: isolation)
    }
}

/// The one instance of `Owner` that a confined controlled driver serves, bound by the driver's first use.
nonisolated final class OwnerBinding<Owner: Actor>: Sendable {
    private struct Binding: Sendable {
        var isBound = false
        weak var owner: Owner?
    }

    private let state = OSAllocatedUnfairLock(initialState: Binding())

    init() {}

    /// Binds the driver to `owner` on its first use, and stops the program when a later use passes
    /// another instance.
    func check(_ owner: Owner) {
        let matches = state.withLock { binding -> Bool in
            guard binding.isBound else {
                binding.isBound = true
                binding.owner = owner
                return true
            }
            return binding.owner === owner
        }
        precondition(matches, "A confined controlled driver was used on an actor other than its owner.")
    }
}

/// The result a test chooses for one confined driver call, kept on the owning actor.
///
/// The suspended driver resumes on that actor and reads the result there, so an output that shares
/// state with the actor never crosses an isolation boundary.
nonisolated final class IsolatedCallCompletion<Owner: Actor, Output, Failure: Error> {
    let signal = CancellationSignal()
    private weak var owner: Owner?
    private let finished = OSAllocatedUnfairLock(initialState: false)
    private var continuation: CheckedContinuation<Void, Never>?
    private var result: Result<Output, Failure>?

    init(owner: Owner) { self.owner = owner }

    /// Whether the test has finished the call; it may be read from any thread.
    var isFinished: Bool { finished.withLock { $0 } }

    /// Stops the program when `isolation` is not the actor that started the call.
    func check(_ isolation: Owner) {
        precondition(
            owner === isolation,
            "A confined controlled driver call was used on an actor other than its owner."
        )
    }

    /// Chooses the result once, reporting whether this call chose it.
    func finish(_ result: Result<Output, Failure>, isolation: isolated Owner) -> Bool {
        check(isolation)
        guard let continuation else { return false }
        self.continuation = nil
        self.result = result
        finished.withLock { $0 = true }
        continuation.resume()
        return true
    }

    /// Suspends the driver until the test chooses its result; cancellation does not end the wait.
    ///
    /// The continuation is installed before `offer` hands the call to a test, so a test can finish
    /// only an execution that is already waiting.
    func wait(offering offer: () -> Void, isolation: isolated Owner) async -> Result<Output, Failure> {
        let signal = signal
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.continuation = continuation
                offer()
            }
        } onCancel: {
            signal.cancel()
        }
        guard let result else { preconditionFailure("A confined driver call resumed without a result.") }
        self.result = nil
        return result
    }
}

/// Hands each started call to the test that awaits it, in start order, on the one actor that holds
/// the queue.
///
/// The calls, the waits' predicates, and the queue never leave that actor, and a predicate, such as a
/// key's equality, runs there outside every lock. A predicate is test code, which can reenter the
/// queue on that actor before it returns: an immediate task can start another call or another wait,
/// and the waiting task can be cancelled. Matching therefore follows ``CallQueue``'s order: each
/// started call and each new wait is an arrival, one matcher at a time takes the arrivals in the order
/// they happened, and an arrival made while a predicate runs waits its turn. A call goes to the oldest
/// waiting test that accepts it and a wait receives the oldest unclaimed call it accepts, each named
/// by a stable identifier rather than a position, and a claim made after a predicate returns succeeds
/// only if the wait is still unanswered, so a wait cancelled during its comparison takes nothing.
///
/// Only a wait's continuation, which a cancellation may resume from any thread, sits behind a lock,
/// and it carries no call: a match gives the call to the wait's slot, and the wait reads it there once
/// it resumes on the actor.
nonisolated final class IsolatedCallQueue<Call> {
    /// A started call or a new wait, in the order they happened.
    private enum Arrival {
        case call(UInt64)
        case wait(UInt64)
    }

    /// Every started call no wait has claimed, by identifier.
    private var calls: [UInt64: Call] = [:]
    /// The matched calls that no wait accepted, in start order; a claimed one is skipped.
    private var unclaimed = ArrivalQueue<UInt64>()
    /// The calls each wait that has not ended accepts, or `nil` for one that accepts every call.
    private var predicates: [UInt64: ((Call) -> Bool)?] = [:]
    /// The matched waits that no call answered, in registration order; an ended one is skipped.
    private var unanswered = ArrivalQueue<UInt64>()
    /// The call each answered wait reads once it resumes.
    private var assigned: [UInt64: Call] = [:]
    /// The arrivals the matcher has not taken, oldest first.
    private var arrivals = ArrivalQueue<Arrival>()
    private var isMatching = false
    private var nextCall: UInt64 = 0
    private let waits = WaitList()

    init() {}

    /// How many calls have started; it may be read from any thread.
    var startedCount: Int { waits.startedCount }

    /// How many queued calls and waits matching has examined, which tests read as its work.
    var examinedEntries: Int { unclaimed.examined + unanswered.examined }
    /// How many queued calls and waits the queues store, ended ones included, which tests read as
    /// their storage.
    var storedEntries: Int { unclaimed.storedCount + unanswered.storedCount }
    /// How many waits have registered and not ended.
    var waitCount: Int { predicates.count }

    /// Records a started call and gives it to the oldest wait that accepts it, if any.
    func offer(_ call: Call) {
        waits.recordStart()
        nextCall += 1
        calls[nextCall] = call
        arrive(.call(nextCall))
    }

    /// The oldest call that `accepts` matches, or the oldest call when it is `nil`, that no test has
    /// taken, once one has started; `nil` if the waiting task is cancelled.
    ///
    /// A task that is already cancelled takes nothing, as a wait whose task is cancelled before a
    /// match answers it does, so the started calls stay for the next wait.
    func next(where accepts: ((Call) -> Bool)?, isolation: isolated (any Actor)?) async -> Call? {
        guard !Task.isCancelled else { return nil }
        let waits = waits
        let id = waits.register()
        predicates[id] = .some(accepts)
        let answered = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                if waits.install(continuation, for: id) { arrive(.wait(id)) }
            }
        } onCancel: {
            waits.cancel(id)
        }
        predicates[id] = nil
        guard answered else { return nil }
        return assigned.removeValue(forKey: id)
    }

    /// Records an arrival and, unless a matcher is already running further up this actor's stack,
    /// takes arrivals in order until none is left.
    private func arrive(_ arrival: Arrival) {
        arrivals.append(arrival)
        guard !isMatching else { return }
        isMatching = true
        while let next = arrivals.first {
            arrivals.removeFirst()
            switch next {
            case .call(let id): matchCall(id)
            case .wait(let id): matchWait(id)
            }
        }
        isMatching = false
    }

    /// Hands a started call to the oldest matched wait that accepts it, or leaves it unclaimed.
    ///
    /// Only the matcher claims, so the call stays unclaimed while the predicates run; a candidate wait
    /// can only end by cancellation, and the call then goes to the next one. The candidates end at the
    /// oldest wait that accepts every call, which needs no predicate.
    private func matchCall(_ id: UInt64) {
        guard let call = calls[id] else { return }
        let waits = waits
        // A candidate that accepted the call but ended meanwhile lets a later wait, beyond the oldest
        // that accepts every call, take it, so the candidates are read again.
        var ended = true
        while ended {
            ended = false
            let candidates = unanswered.live(
                where: { predicates[$0] != nil && waits.isWaiting($0) },
                through: { if case .some(.none) = predicates[$0] { true } else { false } }
            )
            for wait in candidates {
                guard let accepts = predicates[wait], accepts?(call) ?? true else { continue }
                guard let continuation = waits.answer(wait) else {
                    ended = true
                    continue
                }
                calls[id] = nil
                assigned[wait] = call
                continuation.resume(returning: true)
                return
            }
        }
        unclaimed.append(id)
    }

    /// Gives a new wait the oldest unclaimed call it accepts, or leaves it waiting.
    ///
    /// A wait that accepts every call takes the oldest unclaimed one. Otherwise only the matcher claims,
    /// so every unclaimed call stays available while the predicate runs; the wait can only end by
    /// cancellation, and it then takes nothing.
    private func matchWait(_ wait: UInt64) {
        guard waits.isWaiting(wait), let acceptance = predicates[wait] else { return }
        let candidates: [UInt64]
        if acceptance == nil {
            candidates = unclaimed.oldest(where: { calls[$0] != nil }).map { [$0] } ?? []
        } else {
            candidates = unclaimed.live(where: { calls[$0] != nil })
        }
        for id in candidates {
            guard let call = calls[id], acceptance?(call) ?? true else { continue }
            guard let continuation = waits.answer(wait) else { return }
            calls[id] = nil
            assigned[wait] = call
            continuation.resume(returning: true)
            return
        }
        if waits.isWaiting(wait) { unanswered.append(wait) }
    }
}

/// Waits on the owning actor for the next started call that `accepts` matches, failing at the
/// caller's location when the waiting task ends first.
func awaitNextIsolatedCall<Call>(
    _ calls: IsolatedCallQueue<Call>,
    where accepts: ((Call) -> Bool)?,
    awaited description: String,
    isolation: isolated (any Actor)?,
    fileID: String,
    filePath: String,
    line: Int,
    column: Int
) async throws(StateMachineTestFailure) -> Call {
    guard let call = await calls.next(where: accepts, isolation: isolation) else {
        throw StateMachineTestFailure(
            "The test's task was cancelled before the driver started \(description)",
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }
    return call
}

/// The waits of an ``IsolatedCallQueue``, in registration order, which a cancellation may end from
/// any thread.
nonisolated private final class WaitList: Sendable {
    /// Where one wait is between its registration and its result.
    private enum Wait: Sendable {
        case registering
        case cancelledWhileRegistering
        case waiting(CheckedContinuation<Bool, Never>)
    }

    private struct State: Sendable {
        /// Every wait that has not ended, by identifier; identifiers increase in registration order.
        var waits: [UInt64: Wait] = [:]
        var next: UInt64 = 0
        var started = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var startedCount: Int { state.withLock { $0.started } }

    func recordStart() { state.withLock { $0.started += 1 } }

    /// Gives a new wait its identifier, before it installs its continuation.
    func register() -> UInt64 {
        state.withLock { state in
            state.next += 1
            state.waits[state.next] = .registering
            return state.next
        }
    }

    /// Installs a wait's continuation and reports whether it did, or resumes it with `false` when its
    /// task was cancelled first.
    func install(_ continuation: CheckedContinuation<Bool, Never>, for id: UInt64) -> Bool {
        let cancelled = state.withLock { state -> Bool in
            guard case .registering? = state.waits[id] else {
                state.waits[id] = nil
                return true
            }
            state.waits[id] = .waiting(continuation)
            return false
        }
        if cancelled { continuation.resume(returning: false) }
        return !cancelled
    }

    /// Whether a wait is installed and unanswered.
    func isWaiting(_ id: UInt64) -> Bool {
        state.withLock { state in
            guard case .waiting? = state.waits[id] else { return false }
            return true
        }
    }

    /// Ends an installed wait, returning it for a match to answer, or `nil` if it already ended.
    func answer(_ id: UInt64) -> CheckedContinuation<Bool, Never>? {
        state.withLock { state in
            guard case .waiting(let continuation)? = state.waits[id] else { return nil }
            state.waits[id] = nil
            return continuation
        }
    }

    /// Ends a wait whose task was cancelled.
    func cancel(_ id: UInt64) {
        let continuation = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            switch state.waits[id] {
            case .registering?:
                state.waits[id] = .cancelledWhileRegistering
                return nil
            case .waiting(let continuation)?:
                state.waits[id] = nil
                return continuation
            case .cancelledWhileRegistering?, nil: return nil
            }
        }
        continuation?.resume(returning: false)
    }
}
