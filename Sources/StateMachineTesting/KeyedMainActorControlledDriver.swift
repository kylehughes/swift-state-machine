/// A `MainActor` driver of a keyed operation whose every call waits until the test decides how it ends.
///
/// It behaves as ``MainActorControlledDriver`` does, for a keyed operation of a `MainActorHost` whose
/// inputs and outputs need not be `Sendable`, and each call also carries the key the host started it
/// for, as a ``KeyedControlledDriver`` call does. Pass its `run` method as the operation's driver, and
/// take each key's call with ``nextStarted(for:fileID:filePath:line:column:)`` on the main actor:
///
/// ```swift
/// let download = KeyedMainActorControlledDriver<Int, String, String, GeneratedTransfers.TransferFailure>()
/// let host = GeneratedTransfers.MainActorHost(downloadDriver: download.run, onLogged: { _ in })
/// try host.send(.download(1))
/// try host.send(.download(2))
/// let second = try await download.nextStarted(for: 2)
/// second.succeed("contents of \(second.input)")
/// ```
///
/// A host starts each execution in its own task, so calls for different keys can reach the driver in
/// either order; a wait for one key leaves the others queued. Key equality runs on the main actor, and
/// a comparison that starts another call or wait, or cancels the waiting task, cannot reorder the
/// queue: matching follows ``KeyedIsolatedControlledDriver``, whose owning actor is the main actor
/// here.
@MainActor public final class KeyedMainActorControlledDriver<Key: Hashable & Sendable, Input, Output, Failure: Error> {
    /// One started execution of the operation for one key, which the test finishes on the main actor.
    @MainActor public final class Call {
        /// The key the host started this execution for.
        public nonisolated let key: Key
        /// The input the host started this execution with.
        public let input: Input
        fileprivate let completion: IsolatedCallCompletion<MainActor, Output, Failure>

        fileprivate init(key: Key, input: Input) {
            self.key = key
            self.input = input
            completion = IsolatedCallCompletion(owner: MainActor.shared)
        }

        /// Whether the test has finished this execution.
        public var isFinished: Bool { completion.isFinished }
        /// Whether the host has cancelled this execution's task.
        public var isCancelled: Bool { completion.signal.isCancelled }

        /// Ends the execution with `result`; it reports `false` and changes nothing if it already ended.
        ///
        /// The result stays on the main actor, where the suspended driver reads it once it resumes, so
        /// an output may share state with the input or with other main-actor values.
        @discardableResult public func finish(_ result: Result<Output, Failure>) -> Bool {
            completion.finish(result, isolation: MainActor.shared)
        }
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

    /// Creates a driver with no started calls.
    public init() {}

    /// How many executions the host has started, for every key.
    public var startedCount: Int { calls.startedCount }

    /// Returns the oldest started execution not yet returned, for any key, waiting until the host
    /// starts one.
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
        try await awaitNextIsolatedCall(
            calls,
            where: nil,
            awaited: "another call",
            isolation: MainActor.shared,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
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
        try await awaitNextIsolatedCall(
            calls,
            where: { $0.key == key },
            awaited: "a call for \(key)",
            isolation: MainActor.shared,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    /// The driver of a fallible keyed operation: it waits until the test finishes the call.
    public func run(_ key: Key, _ input: Input) async -> Result<Output, Failure> {
        let call = Call(key: key, input: input)
        let calls = calls
        return await call.completion.wait(offering: { calls.offer(call) }, isolation: MainActor.shared)
    }
}

extension KeyedMainActorControlledDriver where Failure == Never {
    /// The driver of a keyed operation that cannot fail: it returns the output the test supplies.
    public func run(_ key: Key, _ input: Input) async -> Output {
        switch await run(key, input) as Result<Output, Never> {
        case .success(let output): output
        }
    }
}

extension KeyedMainActorControlledDriver where Input == Void {
    /// The driver of a fallible keyed operation that takes no input.
    public func run(_ key: Key) async -> Result<Output, Failure> { await run(key, ()) }
}

extension KeyedMainActorControlledDriver where Input == Void, Failure == Never {
    /// The driver of a keyed operation that takes no input and cannot fail.
    public func run(_ key: Key) async -> Output { await run(key, ()) }
}

extension KeyedMainActorControlledDriver.Call where Output == Void {
    /// Ends an execution that produces no value successfully.
    @discardableResult public func succeed() -> Bool { succeed(()) }
}
