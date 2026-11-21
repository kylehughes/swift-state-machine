import StateMachine
import StateMachineExamples
import Testing

// An isolated host's registration is bound to the owning actor: only that actor cancels it, and a
// confined stream that ends there removes its registration in the same turn.

/// An actor that owns an isolated host and the registrations it hands out.
private actor Desk {
    private var host: GeneratedNote.IsolatedHost<Desk>!
    private var cancelled = 0
    private let released = AtomicRecordStorage(0)

    init() async {
        host = GeneratedNote.IsolatedHost(
            isolation: self,
            saveDriver: { _, draft in GeneratedNote.Saved(text: draft.text) }
        )
    }

    /// Cancels a registration on this actor and reports the live count before and after.
    func cancelOnTheOwner() throws -> (before: Int, after: Int) {
        let token = try host.subscribe { _ in }
        let before = host.subscriberCount()
        token.cancel()
        return (before, host.subscriberCount())
    }

    /// Reads a confined stream until it ends and reports the live count in that turn.
    func endAStream() async throws -> (before: Int, after: Int) {
        var snapshots = try host.snapshots()
        let before = host.subscriberCount()
        _ = await snapshots.next()
        host.close()
        while await snapshots.next() != nil {}
        return (before, host.subscriberCount())
    }

    /// Creates a test double's registration on this actor, then cancels one and drops another.
    func doubleRegistrations() -> (cancelled: Int, released: Int) {
        let releases = released
        let first = IsolatedSnapshotSubscription<Desk>(onCancel: { self.cancelled += 1 })
        first.cancel()
        first.cancel()
        do {
            _ = IsolatedSnapshotSubscription<Desk>(
                onCancel: { self.cancelled += 100 },
                onRelease: {
                    while true {
                        let before = releases.load()
                        if releases.install(.init(before.value + 1), replacing: before) { return }
                    }
                }
            )
        }
        return (cancelled, releases.load().value)
    }

    func quiescence() async -> (running: Int, quiescent: Bool) {
        _ = await host.shutdown()
        return (host.runningCount(), host.isQuiescent())
    }
}

@Suite(.timeLimit(.minutes(1))) struct IsolatedRegistrationTests {
    @Test func cancellingOnTheOwningActorRemovesTheRegistrationBeforeReturning() async throws {
        let desk = await Desk()
        let (before, after) = try await desk.cancelOnTheOwner()
        #expect(before == 1 && after == 0)
        _ = await desk.quiescence()
    }

    @Test func aConfinedStreamThatEndsOnTheOwningActorRemovesItsRegistrationInThatTurn() async throws {
        let desk = await Desk()
        let (before, after) = try await desk.endAStream()
        #expect(before == 1 && after == 0)
        _ = await desk.quiescence()
    }

    @Test func aTestDoublesRegistrationCancelsOnceOrReportsItsRelease() async {
        let desk = await Desk()
        let (cancelled, released) = await desk.doubleRegistrations()
        #expect(cancelled == 1)
        #expect(released == 1)
        _ = await desk.quiescence()
    }

    @Test func theOwningActorReadsTheHostsCounts() async {
        let desk = await Desk()
        let (running, quiescent) = await desk.quiescence()
        #expect(running == 0 && quiescent)
    }
}
