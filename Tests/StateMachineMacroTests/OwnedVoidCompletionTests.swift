import StateMachine
import Testing

@StateMachine(mode: .shared)
nonisolated private enum Indexer: Sendable, Equatable {
    struct Idle: Sendable, Equatable {}
    struct Running: Sendable, Equatable { let pass: Int }
    struct Verifying: Sendable, Equatable { let pass: Int }
    struct Done: Sendable, Equatable { let pass: Int }
    struct Failed: Sendable, Equatable { let pass: Int }

    @Initial case idle(Idle = Idle())
    case running(Running)
    case verifying(Verifying)
    @Terminal case done(Done)
    @Terminal case failed(Failed)

    enum Input: Sendable, Equatable { case begin(Int) }
    enum Mismatch: Error, Equatable { case checksum }

    @Operation(activeIn: [Running.self])
    enum Index {}

    @Operation(activeIn: [Verifying.self])
    enum Verify {
        typealias Key = Int
        typealias Failure = Mismatch
    }

    @Transition(on: Input.begin, starts: [Index.self])
    fileprivate static func begin(_ source: Idle, _ pass: Int) -> Change<Running, Effect.Begin> {
        Change(Running(pass: pass), effects: [.index])
    }

    @Transition(onSuccess: Index.self, starts: [Verify.self])
    fileprivate static func indexed(_ source: Running) -> Change<Verifying, Effect.Indexed> {
        Change(Verifying(pass: source.pass), effects: [.verify(key: source.pass)])
    }

    @Transition(onSuccess: Index.self)
    fileprivate static func skipped(_ source: Running) -> Done { Done(pass: source.pass) }

    /// Verifies every pass after the first.
    @Route(onSuccess: Index.self)
    fileprivate static func finish(_ source: Running) -> Route.Finish {
        source.pass > 1 ? .indexed : .skipped
    }

    @Transition(onSuccess: Verify.self)
    fileprivate static func verified(_ source: Verifying, request: VerifyRequest) -> Done {
        Done(pass: request.key)
    }

    @Transition(onFailure: Verify.self)
    fileprivate static func rejected(_ source: Verifying, _ failure: Verify.Failure) -> Failed {
        Failed(pass: source.pass)
    }
}

@StateMachine(mode: .ownedOnly)
nonisolated private enum Buffer: ~Copyable {
    struct Empty: ~Copyable {}
    struct Filling: ~Copyable { let count: Int }
    struct Flushed: ~Copyable { let count: Int }

    @Initial case empty(Empty)
    case filling(Filling)
    @Terminal case flushed(Flushed)

    @Operation(activeIn: [Filling.self])
    enum Flush {}

    @Transition(starts: [Flush.self])
    fileprivate static func fill(_ source: consuming Empty) -> Change<Filling, Effect.Fill> {
        Change(Filling(count: 4), effects: [.flush])
    }

    @Transition(onSuccess: Flush.self)
    fileprivate static func flushed(_ source: consuming Filling) -> Flushed {
        Flushed(count: source.count)
    }
}

@Suite struct OwnedVoidCompletionTests {
    private struct Unexpected: Error {}

    @Test func aRoutedSuccessOfAVoidOutputTakesNoOutputArgument() throws {
        let running = Indexer.owned().begin(2)
        #expect(running.effects == [.index])
        guard case .indexed(let verifying) = running.next.finish() else { throw Unexpected() }
        #expect(verifying.effects == [.verify(key: 2)])
        // A success that takes its request still takes no output argument.
        let done = verifying.next.verified(request: Indexer.VerifyRequest(key: 2))
        #expect(done.takeValue() == Indexer.Done(pass: 2))
        let first = Indexer.owned().begin(1)
        guard case .skipped(let skipped) = first.next.finish() else { throw Unexpected() }
        #expect(skipped.takeValue() == Indexer.Done(pass: 1))
    }

    @Test func aFailureStillTakesItsFailure() throws {
        let running = Indexer.owned().begin(3)
        guard case .indexed(let verifying) = running.next.finish() else { throw Unexpected() }
        let failed = verifying.next.rejected(.checksum)
        #expect(failed.takeValue() == Indexer.Failed(pass: 3))
    }

    @Test func anOwnedOnlySuccessOfAVoidOutputTakesNoOutputArgument() {
        let filling = Buffer.owned(Buffer.Empty()).fill()
        let flushed = filling.next.flushed()
        #expect(flushed.withValue { $0.count } == 4)
    }

    @Test func aLocalOwnerSealsTheSameSuccessWithoutAnArgument() throws {
        var local = Indexer.Local()
        try local.send(.begin(2))
        guard case .index(let index)? = local.drainCommands().first?.commands.first else { throw Unexpected() }
        guard case .committed = local.deliver(index.succeeded()) else { throw Unexpected() }
        guard case .verifying = local.snapshot() else { throw Unexpected() }
    }
}
