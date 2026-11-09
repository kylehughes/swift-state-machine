import StateMachine
import StateMachineSchema
import Testing
import os

@StateMachine(mode: .shared)
nonisolated private enum ChainFlow: Sendable {
    struct Idle: Sendable { let value: Int }
    struct First: Sendable { let value: Int }
    struct Second: Sendable { let value: Int }
    struct Done: Sendable { let value: Int }
    @Initial case idle(Idle)
    case first(First)
    case second(Second)
    case done(Done)
    enum Scope { case first, second }
    enum Input: Sendable { case begin }
    enum Effect: Sendable {
        case firstOperation(FirstOperation.Input)
        case secondOperation(SecondOperation.Input)
    }
    @Operation(scope: Scope.first, activeIn: [First.self], admission: .latest)
    enum FirstOperation {
        typealias Input = Int
        typealias Output = Int
        typealias Failure = Never
    }
    @Operation(scope: Scope.second, activeIn: [Second.self], admission: .latest)
    enum SecondOperation {
        typealias Input = Int
        typealias Output = Int
        typealias Failure = Never
    }
    @Transition(on: Input.begin, starts: [FirstOperation.self])
    fileprivate static func begin(_ source: borrowing Idle) -> Change<First, Effect> {
        Change(First(value: source.value), effects: [.firstOperation(source.value)])
    }
    @Transition(onSuccess: FirstOperation.self, starts: [SecondOperation.self])
    fileprivate static func firstReceived(
        _ source: borrowing First,
        _ value: FirstOperation.Output
    ) -> Change<Second, Effect> {
        Change(Second(value: value), effects: [.secondOperation(value)])
    }
    @Transition(onSuccess: SecondOperation.self)
    fileprivate static func secondReceived(
        _ source: borrowing Second,
        _ value: SecondOperation.Output
    ) -> Change<Done, Effect> {
        Change(Done(value: value))
    }
}

@Test func generatedManagedTerminalStartsSuccessorUsingItsOwnReservationCredit_RT039() async throws {
    enum Failure: Error { case unexpected }
    let calls = OSAllocatedUnfairLock(initialState: [Int]())
    let owner = ChainFlow.Shared(
        .init(value: 1),
        drivers: .init(
            firstOperation: { value in
                calls.withLock { $0.append(value) }
                return .success(value + 1)
            },
            secondOperation: { value in
                calls.withLock { $0.append(value) }
                return .success(value + 1)
            }
        ),
        configuration: try .init(commits: 1, descriptors: 1, executions: 1)
    )
    let (snapshots, events) = AsyncStream<ChainFlow.Snapshot>.makeStream()
    let token = try owner.subscribe { events.yield($0) }
    defer {
        token.cancel()
        events.finish()
    }
    guard case .idle(let idle) = owner.snapshot(), case .committed(let receipt) = owner.commit(try idle.begin()) else {
        throw Failure.unexpected
    }
    #expect(await owner.flush(through: receipt))
    var iterator = snapshots.makeAsyncIterator()
    var finalOrdinal: UInt64?
    while let snapshot = await iterator.next() {
        if case .done(let done) = snapshot {
            #expect(done.value.value == 3)
            finalOrdinal = snapshot.ordinal
            break
        }
    }
    #expect(finalOrdinal == 3)
    #expect(calls.withLock { $0 } == [1, 2])
    #expect(owner.pendingCompletions().isEmpty)
    await owner.shutdown()
    #expect(owner.isQuiescent)
}

@MainActor @Test(.timeLimit(.minutes(1)))
func mainActorTerminalCandidateRetriesAfterActualWorkerJoin_RT032() async throws {
    let calls = OSAllocatedUnfairLock(initialState: [Int]())
    let owner = ChainFlow.MainActorHost(
        .init(value: 1),
        drivers: .init(
            firstOperation: { value in
                calls.withLock { $0.append(value) }
                return .success(value + 1)
            },
            secondOperation: { value in
                calls.withLock { $0.append(value) }
                return .success(value + 1)
            }
        ),
        configuration: try .init(commits: 1, descriptors: 1, executions: 1)
    )
    var done = false
    var waiter: CheckedContinuation<Void, Never>?
    var ordinals: [UInt64] = []
    let token = try owner.subscribe { snapshot in
        ordinals.append(snapshot.ordinal)
        if case .done(let value) = snapshot {
            #expect(value.value.value == 3)
            done = true
            waiter?.resume()
            waiter = nil
        }
    }
    _ = try owner.send(.begin)
    if !done { await withCheckedContinuation { waiter = $0 } }
    #expect(calls.withLock { $0 } == [1, 2])
    #expect(ordinals == [0, 1, 2, 3])
    #expect(owner.pendingCompletions().isEmpty)
    token.cancel()
    await owner.shutdown()
    #expect(owner.isQuiescent && owner.runningCount == 0)
}

@Test(.timeLimit(.minutes(1)))
func nativeActorTerminalCandidateRetriesAfterActualWorkerJoin_RT032() async throws {
    let owner = ChainFlow.ActorHost(
        .init(value: 1),
        drivers: .init(
            firstOperation: { .success($0 + 1) },
            secondOperation: { .success($0 + 1) }
        ),
        configuration: try .init(commits: 1, descriptors: 1, executions: 1)
    )
    let (stream, events) = AsyncStream<ChainFlow.Snapshot>.makeStream()
    let token = try await owner.subscribe { events.yield($0) }
    _ = try await owner.send(.begin)
    var iterator = stream.makeAsyncIterator()
    var ordinals: [UInt64] = []
    while let snapshot = await iterator.next() {
        ordinals.append(snapshot.ordinal)
        if case .done(let done) = snapshot {
            #expect(done.value.value == 3)
            break
        }
    }
    #expect(ordinals == [0, 1, 2, 3])
    #expect(await owner.pendingCompletions().isEmpty)
    token.cancel()
    events.finish()
    await owner.shutdown()
    #expect(await owner.isQuiescent)
    #expect(await owner.runningCount == 0)
}
