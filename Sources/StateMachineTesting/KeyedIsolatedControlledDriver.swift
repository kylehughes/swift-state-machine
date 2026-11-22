/// A driver of a keyed operation, confined to one actor, whose every call waits until the test
/// decides how it ends.
///
/// It behaves as ``IsolatedControlledDriver`` does, and each call also carries the key the host
/// started it for, as a ``KeyedControlledDriver`` call does, so a test on the owning actor can finish
/// one key's work and leave another's running while the inputs and outputs stay on that actor. A host
/// starts each execution in its own task, so calls for different keys can reach the driver in either
/// order. ``nextStarted(for:isolation:fileID:filePath:line:column:)`` waits for one key's call and
/// leaves the others queued, as in this `.isolated` graph `Reader` whose `Open` operation is keyed
/// by a book's identifier.
///
/// ```swift
/// actor Shelf {
///     let open = KeyedIsolatedControlledDriver<Shelf, Int, Reader.Request, Reader.Book, Never>()
///     private(set) var host: Reader.IsolatedHost<Shelf>!
///
///     init() async {
///         host = Reader.IsolatedHost(
///             isolation: self,
///             openDriver: { shelf, id, request in await shelf.open.run(shelf, id, request) }
///         )
///     }
///
///     func openTwo() async throws {
///         try host.send(.open(1))
///         try host.send(.open(2))
///         let second = try await open.nextStarted(for: 2)
///         second.succeed(Reader.Book(title: second.input().title))
///     }
/// }
/// ```
///
/// Its methods take the owning actor as an `isolated` parameter, which a call on that actor passes
/// by default, and a use on another instance of `Owner` stops the program, as an
/// ``IsolatedControlledDriver``'s does. Key equality runs on the owning actor, and a comparison that
/// starts another call or wait on that actor, or cancels the waiting task, cannot change which call
/// each wait receives because starts and waits are matched in arrival order and a wait cancelled
/// during its comparison takes nothing.
nonisolated public final class KeyedIsolatedControlledDriver<
    Owner: Actor,
    Key: Hashable & Sendable,
    Input,
    Output,
    Failure: Error
> {
    /// One started execution of the operation for one key, which the test finishes on the owning actor.
    public final class Call {
        /// The key the host started this execution for.
        public let key: Key
        private let payload: Input
        fileprivate let completion: IsolatedCallCompletion<Owner, Output, Failure>

        fileprivate init(key: Key, input: Input, owner: Owner) {
            self.key = key
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

        /// Ends the execution with `result`, returning `false` without changing anything if it already ended.
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

    /// How many executions the host has started, for every key.
    public var startedCount: Int { calls.startedCount }

    /// Returns the oldest started execution not yet returned, for any key, waiting on the owning actor
    /// until the host starts one.
    ///
    /// Executions for different keys run in separate tasks, so their order here is the order in which
    /// those tasks reached the driver. It throws when the waiting task is cancelled first, for example
    /// by a test's time limit.
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

    /// Returns the oldest started execution for `key` not yet returned, waiting on the owning actor
    /// until the host starts one.
    ///
    /// Calls for other keys stay queued for later waits, so a test can take each key's call without
    /// depending on the order in which the host's tasks start. It throws when the waiting task is
    /// cancelled first, for example by a test's time limit.
    public func nextStarted(
        for key: Key,
        isolation: isolated Owner = #isolation,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column
    ) async throws(StateMachineTestFailure) -> Call {
        binding.check(isolation)
        return try await awaitNextIsolatedCall(
            calls,
            where: { $0.key == key },
            awaited: "a call for \(key)",
            isolation: isolation,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column
        )
    }

    /// Runs as the driver of a fallible keyed operation, waiting until the test finishes the call.
    public func run(_ owner: isolated Owner, _ key: Key, _ input: Input) async -> Result<Output, Failure> {
        binding.check(owner)
        let call = Call(key: key, input: input, owner: owner)
        let calls = calls
        return await call.completion.wait(offering: { calls.offer(call) }, isolation: owner)
    }
}

extension KeyedIsolatedControlledDriver where Failure == Never {
    /// Runs as the driver of a keyed operation that cannot fail, returning the output the test supplies.
    public func run(_ owner: isolated Owner, _ key: Key, _ input: Input) async -> Output {
        switch await run(owner, key, input) as Result<Output, Never> {
        case .success(let output): output
        }
    }
}

extension KeyedIsolatedControlledDriver where Input == Void {
    /// The driver of a fallible keyed operation that takes no input.
    public func run(_ owner: isolated Owner, _ key: Key) async -> Result<Output, Failure> {
        await run(owner, key, ())
    }
}

extension KeyedIsolatedControlledDriver where Input == Void, Failure == Never {
    /// The driver of a keyed operation that takes no input and cannot fail.
    public func run(_ owner: isolated Owner, _ key: Key) async -> Output { await run(owner, key, ()) }
}

extension KeyedIsolatedControlledDriver.Call where Output == Void {
    /// Ends an execution that produces no value successfully.
    @discardableResult public func succeed(isolation: isolated Owner = #isolation) -> Bool {
        succeed((), isolation: isolation)
    }
}
