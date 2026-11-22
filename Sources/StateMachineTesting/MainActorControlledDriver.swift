/// A `MainActor` driver whose every call waits until the test decides how it ends.
///
/// It behaves as ``ControlledDriver`` does, for a `MainActorHost` whose inputs and outputs need not
/// be `Sendable`, such as one of an `.isolated` graph. The driver, its calls, and their values stay
/// on the main actor, so the test that awaits ``nextStarted(fileID:filePath:line:column:)`` runs
/// there too.
///
/// ```swift
/// let save = MainActorControlledDriver<GeneratedNote.Draft, GeneratedNote.Saved, Never>()
/// let host = GeneratedNote.MainActorHost(saveDriver: save.run)
/// try host.send(.save)
/// let call = try await save.nextStarted()
/// call.succeed(GeneratedNote.Saved(text: call.input.text))
/// ```
@MainActor public final class MainActorControlledDriver<Input, Output, Failure: Error> {
    /// One started execution of the operation, which the test finishes on the main actor.
    @MainActor public final class Call {
        /// The input the host started this execution with.
        public let input: Input
        /// Whether the test has finished this execution.
        public private(set) var isFinished = false
        fileprivate let signal = CancellationSignal()
        private var continuation: CheckedContinuation<Void, Never>?
        private var result: Result<Output, Failure>?

        fileprivate init(input: Input) { self.input = input }

        /// Whether the host has cancelled this execution's task.
        public var isCancelled: Bool { signal.isCancelled }

        /// Ends the execution with `result`, returning `false` without changing anything if it already ended.
        ///
        /// The result stays on the main actor, where the suspended driver reads it once it resumes, so
        /// an output may share state with the input or with other main-actor values.
        @discardableResult public func finish(_ result: Result<Output, Failure>) -> Bool {
            guard !isFinished, let continuation else { return false }
            isFinished = true
            self.continuation = nil
            self.result = result
            continuation.resume()
            return true
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
            try await awaitCancellation(signal, fileID: fileID, filePath: filePath, line: line, column: column)
        }

        // The continuation is installed before the call is offered, so a test can finish only an
        // execution that is already waiting.
        fileprivate func run(offering calls: CallQueue<Call>) async -> Result<Output, Failure> {
            let signal = signal
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.continuation = continuation
                    calls.offer(self)
                }
            } onCancel: {
                signal.cancel()
            }
            guard let result else { preconditionFailure("A main-actor driver call resumed without a result.") }
            self.result = nil
            return result
        }
    }

    private let calls = CallQueue<Call>()

    /// Creates a driver with no started calls.
    public init() {}

    /// How many executions the host has started.
    public var startedCount: Int { calls.startedCount }

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

    /// Runs as the driver of a fallible operation, waiting until the test finishes the call.
    public func run(_ input: Input) async -> Result<Output, Failure> {
        await Call(input: input).run(offering: calls)
    }
}

extension MainActorControlledDriver where Failure == Never {
    /// Runs as the driver of an operation that cannot fail, returning the output the test supplies.
    public func run(_ input: Input) async -> Output {
        switch await Call(input: input).run(offering: calls) {
        case .success(let output): output
        }
    }
}

extension MainActorControlledDriver where Input == Void {
    /// The driver of a fallible operation that takes no input.
    public func run() async -> Result<Output, Failure> { await run(()) }
}

extension MainActorControlledDriver where Input == Void, Failure == Never {
    /// The driver of an operation that takes no input and cannot fail.
    public func run() async -> Output { await run(()) }
}

extension MainActorControlledDriver.Call where Output == Void {
    /// Ends an execution that produces no value successfully.
    @discardableResult public func succeed() -> Bool { succeed(()) }
}
