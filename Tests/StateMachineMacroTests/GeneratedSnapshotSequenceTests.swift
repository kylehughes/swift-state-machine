import StateMachine
import StateMachineExamples
import Testing

@StateMachine(mode: .shared)
nonisolated private enum SequenceFlow: Sendable {
    struct Idle: Sendable {}
    struct Done: Sendable { let value: Int }
    @Initial case idle(Idle)
    case done(Done)
    enum Input: Sendable { case finish(Int) }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Idle, _ value: Int) -> Done { Done(value: value) }
}

@Suite(.timeLimit(.minutes(1))) struct GeneratedSnapshotSequenceTests {
    @MainActor @Test func mainActorHostSequenceFollowsTheOwnerToItsClosedSnapshot() async throws {
        let owner = SequenceFlow.MainActorHost(.init())
        var revisions: [UInt64] = []
        var values: [Int] = []
        var closed = false
        for await snapshot in try owner.snapshots() {
            revisions.append(snapshot.revision)
            closed = snapshot.isClosed
            switch snapshot {
            case .idle: try owner.send(.finish(7))
            case .done(let done):
                values.append(done.value.value)
                if !snapshot.isClosed { _ = owner.close() }
            }
        }
        #expect(revisions == [0, 1, 2] && values == [7, 7] && closed)
        await owner.shutdown()
    }

    @MainActor @Test func mainActorHostSequenceComposesWithSequenceOperators() async throws {
        let owner = SequenceFlow.MainActorHost(.init())
        let snapshots: SequenceFlow.Snapshots = try owner.snapshots()
        var revisions: [UInt64] = []
        for await revision in snapshots.map({ $0.revision }).prefix(2) {
            revisions.append(revision)
            if revision == 0 { try owner.send(.finish(7)) }
        }
        #expect(revisions == [0, 1])
        await owner.shutdown()
    }

    @Test func actorHostSequenceFollowsTheOwnerToItsClosedSnapshot() async throws {
        let owner = SequenceFlow.ActorHost(.init())
        var revisions: [UInt64] = []
        var closed = false
        for await snapshot in try await owner.snapshots() {
            revisions.append(snapshot.revision)
            closed = snapshot.isClosed
            switch snapshot {
            case .idle: try await owner.send(.finish(7))
            case .done: if !snapshot.isClosed { _ = await owner.close() }
            }
        }
        #expect(revisions == [0, 1, 2] && closed)
        await owner.shutdown()
    }

    @Test func sharedSequenceFollowsTheOwnerToItsClosedSnapshot() async throws {
        let owner = SequenceFlow.Shared(.init())
        var revisions: [UInt64] = []
        var closed = false
        for await snapshot in try owner.snapshots() {
            revisions.append(snapshot.revision)
            closed = snapshot.isClosed
            switch snapshot {
            case .idle: try owner.send(.finish(7))
            case .done: if !snapshot.isClosed { _ = owner.close() }
            }
        }
        #expect(revisions == [0, 1, 2] && closed)
        await owner.shutdown()
    }

    @Test func creationReportsExhaustedSubscriberCapacity() async throws {
        let owner = SequenceFlow.Shared(.init(), configuration: try .init(subscribers: 1))
        let held: SequenceFlow.Snapshots = try owner.snapshots()
        #expect(throws: SequenceFlow.SubscriptionFailure.capacityExceeded) { try owner.snapshots() }
        _ = held
        await owner.shutdown()
    }

    @MainActor @Test func isolatedSchemaSequenceCarriesConfinedSnapshots() async throws {
        let owner = GeneratedNote.MainActorHost(
            .init(text: "confined"),
            drivers: .init(save: { input in .init(text: input.text) })
        )
        let snapshots: GeneratedNote.MainActorSnapshots = try owner.snapshots()
        var revisions: [UInt64] = []
        var saved: [String] = []
        var closed = false
        for await snapshot in snapshots {
            revisions.append(snapshot.revision)
            closed = snapshot.isClosed
            switch snapshot {
            case .draft: try owner.send(.save)
            case .saving: break
            case .saved(let value):
                saved.append(value.value.text)
                if !snapshot.isClosed { _ = owner.close() }
            }
        }
        #expect(zip(revisions, revisions.dropFirst()).allSatisfy { $0 < $1 })
        #expect(saved.first == "confined" && closed)
        await owner.shutdown()
        #expect(owner.runningCount == 0 && owner.isQuiescent)
    }

    @MainActor @Test func isolatedSchemaProjectionComposesWithSequenceOperators() async throws {
        let owner = GeneratedNote.MainActorHost(
            .init(text: "confined"),
            drivers: .init(save: { input in .init(text: input.text) })
        )
        var revisions: [UInt64] = []
        for await revision in try owner.snapshots({ $0.revision }).prefix(2) {
            revisions.append(revision)
            if revision == 0 { try owner.send(.save) }
        }
        #expect(revisions.count == 2 && revisions[0] < revisions[1])
        _ = owner.close()
        await owner.shutdown()
    }
}
