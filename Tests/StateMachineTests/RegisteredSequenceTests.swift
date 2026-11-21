import StateMachine
import Testing
import os

// A host of one's own registers a `SnapshotSequence` through `init(register:)` and may keep the token
// it returns. The sequence, not that token's lifetime, decides when the registration ends.

/// A host double that keeps every token it returns, and the callbacks of its latest registration.
private final class RetainingHost: Sendable {
    private struct State {
        var tokens: [SnapshotSubscription] = []
        var receive: (@Sendable (Int) -> Void)?
        var finish: (@Sendable () -> Void)?
        var cancellations = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// What the double does inside `register`, before it returns the token.
    private let duringRegistration:
        @Sendable (_ receive: @Sendable (Int) -> Void, _ finish: @Sendable () -> Void) -> Void

    init(
        duringRegistration:
            @escaping @Sendable (_ receive: @Sendable (Int) -> Void, _ finish: @Sendable () -> Void) ->
            Void = { _, _ in }
    ) {
        self.duringRegistration = duringRegistration
    }

    var cancellations: Int { state.withLock { $0.cancellations } }

    func sequence() throws(SubscriptionFailure) -> SnapshotSequence<Int> {
        try SnapshotSequence { receive, finish in
            let token = SnapshotSubscription(onCancel: { self.state.withLock { $0.cancellations += 1 } })
            self.state.withLock { state in
                state.tokens.append(token)
                state.receive = receive
                state.finish = finish
            }
            self.duringRegistration(receive, finish)
            return token
        }
    }

    func offer(_ value: Int) { state.withLock { $0.receive }?(value) }
    func finish() { state.withLock { $0.finish }?() }
}

@Suite(.timeLimit(.minutes(1))) struct RegisteredSequenceTests {
    // The host still holds its token, so only the sequence's own end can cancel it.
    @Test func releasingAnUnreadSequenceCancelsARetainedToken() throws {
        let host = RetainingHost()
        var sequence: SnapshotSequence<Int>? = try host.sequence()
        #expect(host.cancellations == 0)
        sequence = nil
        #expect(host.cancellations == 1)
        withExtendedLifetime(sequence) {}
    }

    @Test func releasingTheSequenceAndItsIteratorCancelsARetainedTokenOnce() throws {
        let host = RetainingHost()
        var sequence: SnapshotSequence<Int>? = try host.sequence()
        var iterator = sequence?.makeAsyncIterator()
        sequence = nil
        #expect(host.cancellations == 0)
        iterator = nil
        #expect(host.cancellations == 1)
        withExtendedLifetime(iterator) {}
    }

    // Finishing with nothing pending ends the registration at once, without waiting for a read.
    @Test func finishingWithNothingPendingCancelsTheTokenAtOnce() async throws {
        let host = RetainingHost()
        let sequence = try host.sequence()
        var iterator = sequence.makeAsyncIterator()
        host.finish()
        #expect(host.cancellations == 1)
        #expect(await iterator.next() == nil)
        #expect(host.cancellations == 1)
    }

    // The registration ends at the finish; the element offered before it stays readable.
    @Test func finishingKeepsABufferedFinalElementReadable() async throws {
        let host = RetainingHost()
        let sequence = try host.sequence()
        host.offer(7)
        host.finish()
        #expect(host.cancellations == 1)
        var iterator = sequence.makeAsyncIterator()
        #expect(await iterator.next() == 7)
        #expect(await iterator.next() == nil)
        #expect(host.cancellations == 1)
    }

    // A host whose owner is already closed offers and finishes before `register` returns its token; the
    // token is cancelled as soon as the sequence receives it.
    @Test func aFinishBeforeRegistrationReturnsCancelsTheTokenWhenItArrives() async throws {
        let host = RetainingHost(duringRegistration: { receive, finish in
            receive(3)
            finish()
        })
        let sequence = try host.sequence()
        #expect(host.cancellations == 1)
        var iterator = sequence.makeAsyncIterator()
        #expect(await iterator.next() == 3)
        #expect(await iterator.next() == nil)
        #expect(host.cancellations == 1)
    }

    // Reading to the end cancels once, even though the host keeps the token.
    @Test func readingToTheEndCancelsARetainedTokenOnce() async throws {
        let host = RetainingHost()
        let sequence = try host.sequence()
        host.offer(1)
        var iterator = sequence.makeAsyncIterator()
        #expect(await iterator.next() == 1)
        #expect(host.cancellations == 0)
        host.finish()
        #expect(await iterator.next() == nil)
        #expect(host.cancellations == 1)
    }
}
