import StateMachine
import Testing
import os

private typealias CountedHost = RuntimeSharedHost<Int, Int, RuntimeTicket, Never>

@Suite(.timeLimit(.minutes(1))) struct SubscriberCountTests {
    // A shared owner holds registrations A and B and has room for three. The count loads that version of
    // the state, and before it reads the registrations' gates, C is registered, A cancelled, D
    // registered, and B cancelled, so the count passes through 2, 3, 2, 3, 2. The version it loaded
    // lists only A and B, both closed by then, which would read 0, a count that never held.
    @Test func aSharedOwnersSubscriberCountIsOneThatHeldWhileRegistrationsAreReplaced() throws {
        let host = CountedHost(
            manual: 0,
            scopes: [],
            limits: try .init(),
            subscriberCapacity: 3,
            ticket: { $0 },
            prepare: { _ in .failure(.admission(.plan(.invalidPlan))) }
        )
        let firstToken = try host.subscribe { _ in }
        let second = try host.subscribe { _ in }
        let later = OSAllocatedUnfairLock<[SnapshotSubscription]>(initialState: [])
        let replaced = OSAllocatedUnfairLock(initialState: false)
        let replace: @Sendable () -> Void = {
            let first = replaced.withLock { done -> Bool in
                defer { done = true }
                return !done
            }
            guard first else { return }
            do {
                let third = try host.subscribe { _ in }
                firstToken.cancel()
                let fourth = try host.subscribe { _ in }
                second.cancel()
                later.withLock { $0 = [third, fourth] }
            } catch {
                Issue.record("The owner refused a registration it had room for: \(error)")
            }
        }
        let count = CountReadPause.$afterLoading.withValue(replace) { host.subscriberCount }
        #expect(replaced.withLock { $0 })
        #expect(count == 2)
        #expect(host.subscriberCount == 2)
        for token in later.withLock({ $0 }) { token.cancel() }
        #expect(host.subscriberCount == 0)
    }
}
