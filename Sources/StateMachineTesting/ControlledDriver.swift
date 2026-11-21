/// A driver whose every call waits until the test decides how it ends.
///
/// Pass its `run` method as an operation's driver to any managed host
/// whose values are `Sendable`: `Shared`, `ActorHost`, `MainActorHost`, or `IsolatedHost`. Each
/// time the host starts the operation, the driver suspends, and the test receives the call from
/// ``nextStarted(fileID:filePath:line:column:)`` with the input the host passed. The test then
/// finishes it with ``Call/succeed(_:)`` or ``Call/fail(_:)``, or leaves it running. Each step is an
/// explicit hand-off, so a test needs no sleeps or yields to order them:
///
/// ```swift
/// let fetch = ControlledDriver<ProfileRequest, Profile, ProfileFailure>()
/// let audit = ControlledDriver<String, Profile, ProfileFailure>()
/// let host = GeneratedProfile.ActorHost(idle, fetchDriver: fetch.run, auditDriver: audit.run)
/// try await host.send(.load(request))
/// let call = try await fetch.nextStarted()
/// #expect(call.input == request)
/// call.succeed(profile)
/// ```
///
/// The same `run` serves an infallible operation, whose driver returns its output directly, an
/// operation without input, and an `IsolatedHost`, whose driver receives its owning actor: the
/// contextual driver type selects the form. A call ignores cancellation, as a driver that does not
/// check for it would. When the host cancels the call's task, ``Call/isCancelled`` becomes `true`
/// and ``Call/waitForCancellation(fileID:filePath:line:column:)`` returns, and the call keeps running until
/// the test finishes it, so a test can deliver a result after cancellation and observe that the
/// host discards it. A call that the test never finishes never returns, and the host's shutdown
/// waits for it.
///
/// The driver grants no authority: it supplies a result to the host's own work, which only the
/// host can deliver.
nonisolated public final class ControlledDriver<Input: Sendable, Output: Sendable, Failure: Error>: Sendable {
    /// One started execution of the operation, which the test finishes.
    public final class Call: Sendable {
        /// The input the host started this execution with.
        public let input: Input
        private let slot = ResultSlot<Output, Failure>()
        fileprivate let signal = CancellationSignal()

        fileprivate init(input: Input) { self.input = input }

        /// Whether the test has finished this execution.
        public var isFinished: Bool { slot.isFinished }
        /// Whether the host has cancelled this execution's task.
        public var isCancelled: Bool { signal.isCancelled }

        /// Ends the execution with `result`; it reports `false` and changes nothing if it already ended.
        @discardableResult public func finish(_ result: Result<Output, Failure>) -> Bool { slot.finish(result) }
        /// Ends the execution with a successful output.
        @discardableResult public func succeed(_ output: Output) -> Bool { finish(.success(output)) }
        /// Ends the execution with a typed failure.
        @discardableResult public func fail(_ failure: Failure) -> Bool { finish(.failure(failure)) }

        /// Returns once the host has cancelled this execution's task.
        ///
        /// The execution keeps running afterward until the test finishes it. It throws when the
        /// waiting task is cancelled first, for example by a test's time limit.
        public func waitForCancellation(
            fileID: String = #fileID,
            filePath: String = #filePath,
            line: Int = #line,
            column: Int = #column
        ) async throws(StateMachineTestFailure) {
            try await awaitCancellation(signal, fileID: fileID, filePath: filePath, line: line, column: column)
        }

        fileprivate func run(offering calls: CallQueue<Call>) async -> Result<Output, Failure> {
            await withTaskCancellationHandler {
                await slot.wait(afterInstalling: { calls.offer(self) })
            } onCancel: {
                signal.cancel()
            }
        }
    }

    private let calls = CallQueue<Call>()

    /// Creates a driver with no started calls.
    public init() {}

    /// How many executions the host has started.
    public var startedCount: Int { calls.startedCount }

    /// How many queued calls and waits matching has examined, which tests read as its work.
    package var examinedCallEntries: Int { calls.examinedEntries }
    /// How many queued calls and waits the driver stores, which tests read as its storage.
    package var storedCallEntries: Int { calls.storedEntries }
    /// How many waits for a started call have registered and not ended.
    package var waitingCount: Int { calls.waitCount }

    /// Returns the oldest started execution not yet returned, waiting until the host starts one.
    ///
    /// It throws when the waiting task is cancelled first, for example by a test's time limit.
    public func nextStarted(
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) async throws(StateMachineTestFailure) -> Call {
        try await awaitNextCall(calls, fileID: fileID, filePath: filePath, line: line, column: column)
    }

    /// The driver of a fallible operation: it waits until the test finishes the call.
    public func run(_ input: Input) async -> Result<Output, Failure> {
        await Call(input: input).run(offering: calls)
    }

    /// The driver of a fallible operation on an `IsolatedHost`, which receives its owning actor.
    public func run<Owner: Actor>(_ owner: isolated Owner, _ input: Input) async -> Result<Output, Failure> {
        await Call(input: input).run(offering: calls)
    }
}

extension ControlledDriver where Failure == Never {
    /// The driver of an operation that cannot fail: it returns the output the test supplies.
    public func run(_ input: Input) async -> Output {
        switch await Call(input: input).run(offering: calls) {
        case .success(let output): output
        }
    }

    /// The driver of an operation that cannot fail on an `IsolatedHost`, which receives its owning actor.
    public func run<Owner: Actor>(_ owner: isolated Owner, _ input: Input) async -> Output {
        switch await Call(input: input).run(offering: calls) {
        case .success(let output): output
        }
    }
}

extension ControlledDriver where Input == Void {
    /// The driver of a fallible operation that takes no input.
    public func run() async -> Result<Output, Failure> { await run(()) }

    /// The driver of a fallible operation that takes no input on an `IsolatedHost`.
    public func run<Owner: Actor>(_ owner: isolated Owner) async -> Result<Output, Failure> { await run(()) }
}

extension ControlledDriver where Input == Void, Failure == Never {
    /// The driver of an operation that takes no input and cannot fail.
    public func run() async -> Output { await run(()) }

    /// The driver of an operation that takes no input and cannot fail on an `IsolatedHost`.
    public func run<Owner: Actor>(_ owner: isolated Owner) async -> Output { await run(()) }
}

extension ControlledDriver.Call where Output == Void {
    /// Ends an execution that produces no value successfully.
    @discardableResult public func succeed() -> Bool { succeed(()) }
}

/// A driver of a keyed operation whose every call waits until the test decides how it ends.
///
/// It behaves as ``ControlledDriver`` does, and each call also carries the key the host started it
/// for, so a test can finish one key's work and leave another's running. A host starts each execution
/// in its own task, so calls for different keys can reach the driver in either order;
/// ``nextStarted(for:fileID:filePath:line:column:)`` waits for one key's call and leaves the others
/// queued:
///
/// ```swift
/// let download = KeyedControlledDriver<Int, String, String, TransferFailure>()
/// let host = GeneratedTransfers.Shared(downloadDriver: download.run, onLogged: { _ in })
/// try host.send(.download(1))
/// try host.send(.download(2))
/// let first = try await download.nextStarted(for: 1)
/// let second = try await download.nextStarted(for: 2)
/// #expect(second.input == "file-2")
/// second.succeed("two")
/// ```
nonisolated public final class KeyedControlledDriver<
    Key: Hashable & Sendable,
    Input: Sendable,
    Output: Sendable,
    Failure: Error
>:
    Sendable
{
    /// One started execution of the operation for one key, which the test finishes.
    public final class Call: Sendable {
        /// The key the host started this execution for.
        public let key: Key
        /// The input the host started this execution with.
        public let input: Input
        private let slot = ResultSlot<Output, Failure>()
        fileprivate let signal = CancellationSignal()

        fileprivate init(key: Key, input: Input) {
            self.key = key
            self.input = input
        }

        /// Whether the test has finished this execution.
        public var isFinished: Bool { slot.isFinished }
        /// Whether the host has cancelled this execution's task.
        public var isCancelled: Bool { signal.isCancelled }

        /// Ends the execution with `result`; it reports `false` and changes nothing if it already ended.
        @discardableResult public func finish(_ result: Result<Output, Failure>) -> Bool { slot.finish(result) }
        /// Ends the execution with a successful output.
        @discardableResult public func succeed(_ output: Output) -> Bool { finish(.success(output)) }
        /// Ends the execution with a typed failure.
        @discardableResult public func fail(_ failure: Failure) -> Bool { finish(.failure(failure)) }

        /// Returns once the host has cancelled this execution's task.
        ///
        /// The execution keeps running afterward until the test finishes it. It throws when the
        /// waiting task is cancelled first, for example by a test's time limit.
        public func waitForCancellation(
            fileID: String = #fileID,
            filePath: String = #filePath,
            line: Int = #line,
            column: Int = #column
        ) async throws(StateMachineTestFailure) {
            try await awaitCancellation(signal, fileID: fileID, filePath: filePath, line: line, column: column)
        }

        fileprivate func run(offering calls: CallQueue<Call>) async -> Result<Output, Failure> {
            await withTaskCancellationHandler {
                await slot.wait(afterInstalling: { calls.offer(self) })
            } onCancel: {
                signal.cancel()
            }
        }
    }

    private let calls = CallQueue<Call>()

    /// Creates a driver with no started calls.
    public init() {}

    /// How many executions the host has started, for every key.
    public var startedCount: Int { calls.startedCount }

    /// Returns the oldest started execution not yet returned, for any key, waiting until the host starts one.
    ///
    /// Executions for different keys run in separate tasks, so their order here is the order in which
    /// those tasks reached the driver. It throws when the waiting task is cancelled first, for example
    /// by a test's time limit.
    public func nextStarted(
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) async throws(StateMachineTestFailure) -> Call {
        try await awaitNextCall(calls, fileID: fileID, filePath: filePath, line: line, column: column)
    }

    /// Returns the oldest started execution for `key` not yet returned, waiting until the host starts one.
    ///
    /// Calls for other keys stay queued for later waits, so a test can take each key's call without
    /// depending on the order in which the host's tasks start. It throws when the waiting task is
    /// cancelled first, for example by a test's time limit.
    public func nextStarted(
        for key: Key,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) async throws(StateMachineTestFailure) -> Call {
        try await awaitNextCall(
            calls,
            where: { $0.key == key },
            awaited: "a call for \(key)",
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    /// The driver of a fallible keyed operation: it waits until the test finishes the call.
    public func run(_ key: Key, _ input: Input) async -> Result<Output, Failure> {
        await Call(key: key, input: input).run(offering: calls)
    }

    /// The driver of a fallible keyed operation on an `IsolatedHost`, which receives its owning actor.
    public func run<Owner: Actor>(_ owner: isolated Owner, _ key: Key, _ input: Input) async -> Result<Output, Failure>
    {
        await Call(key: key, input: input).run(offering: calls)
    }
}

extension KeyedControlledDriver where Failure == Never {
    /// The driver of a keyed operation that cannot fail: it returns the output the test supplies.
    public func run(_ key: Key, _ input: Input) async -> Output {
        switch await Call(key: key, input: input).run(offering: calls) {
        case .success(let output): output
        }
    }

    /// The driver of a keyed operation that cannot fail on an `IsolatedHost`.
    public func run<Owner: Actor>(_ owner: isolated Owner, _ key: Key, _ input: Input) async -> Output {
        switch await Call(key: key, input: input).run(offering: calls) {
        case .success(let output): output
        }
    }
}

extension KeyedControlledDriver where Input == Void {
    /// The driver of a fallible keyed operation that takes no input.
    public func run(_ key: Key) async -> Result<Output, Failure> { await run(key, ()) }

    /// The driver of a fallible keyed operation that takes no input on an `IsolatedHost`.
    public func run<Owner: Actor>(_ owner: isolated Owner, _ key: Key) async -> Result<Output, Failure> {
        await run(key, ())
    }
}

extension KeyedControlledDriver where Input == Void, Failure == Never {
    /// The driver of a keyed operation that takes no input and cannot fail.
    public func run(_ key: Key) async -> Output { await run(key, ()) }

    /// The driver of a keyed operation that takes no input and cannot fail on an `IsolatedHost`.
    public func run<Owner: Actor>(_ owner: isolated Owner, _ key: Key) async -> Output { await run(key, ()) }
}

extension KeyedControlledDriver.Call where Output == Void {
    /// Ends an execution that produces no value successfully.
    @discardableResult public func succeed() -> Bool { succeed(()) }
}
