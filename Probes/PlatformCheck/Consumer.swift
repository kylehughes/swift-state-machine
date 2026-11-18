import StateMachine
import StateMachineExamples
import StateMachineSchema
import StateMachineUI

@StateMachine(mode: .shared)
nonisolated private enum PlatformWorkflow: Sendable {
    struct Idle: Sendable { let value: Int }
    @Initial case idle(Idle)
    enum Input: Sendable { case edit(Int) }

    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: Idle, _ value: Int) -> Idle {
        Idle(value: value)
    }
}

/// Exercises the public shared-owner path in a linked library consumer.
public func stateMachinePlatformCheck() throws -> UInt64 {
    let user = try UserID("platform-check")
    let owner = ReferenceProfile.Shared(
        ReferenceProfile.Idle(userID: user),
        drivers: ReferenceProfile.Drivers(
            fetch: { _ in .failure(.unavailable) },
            audit: { _ in .failure(.unavailable) }
        )
    )
    guard case .idle(let idle) = owner.snapshot() else { return 0 }
    let request = try ProfileRequest(userID: user)
    let prepared = try idle.load(request)
    guard case .committed(let receipt) = owner.commit(consume prepared) else { return 0 }
    let after = owner.snapshot()
    let closing = owner.close()
    guard !after.isClosed, closing.snapshot.isClosed, closing.revision > after.revision else { return 0 }
    return receipt.revision + after.revision + closing.revision
}

/// Links a client-authored macro expansion and its manually driven value owner.
public func stateMachineSchemaPlatformCheck() throws -> UInt64 {
    var owner = PlatformWorkflow.Local(PlatformWorkflow.Idle(value: 0))
    guard case .idle(let initial) = owner.snapshot(),
        case .committed(let receipt) = owner.commit(try initial.edit(1))
    else { return 0 }
    let batches = owner.drainCommands(limit: 1)
    guard batches.count == 1 else { return 0 }
    _ = owner.close()
    _ = owner.drainCommands(limit: 1)
    return receipt.revision
}

/// Links the MainActor facade, observable presentation, and background ingress baseline.
@MainActor public func stateMachineUIPlatformCheck() throws -> UInt64 {
    let user = try UserID("platform-ui")
    let editor = try ProfileEditor(
        request: ProfileRequest(userID: user),
        drivers: GeneratedProfile.MainActorDrivers(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
    )
    let receipt = try editor.load()
    let background = SnapshotPresentation(editor.presentation.snapshot, revision: { $0.revision })
    let ingress = MainActorSnapshotIngress<GeneratedProfile.Snapshot> { [weak background] in
        background?.apply($0)
    }
    ingress.offer(receipt.snapshot, revision: receipt.revision)
    ingress.cancel()
    editor.dispose()
    return editor.presentation.snapshot.revision
}

/// Links native actor admission and managed shutdown through normal public imports.
public func stateMachineActorPlatformCheck() async throws -> UInt64 {
    let user = try UserID("platform-actor")
    let owner = GeneratedProfile.ActorHost(
        GeneratedProfile.Idle(userID: user),
        fetchDriver: { _ in .failure(.unavailable) },
        auditDriver: { _ in .failure(.unavailable) }
    )
    let receipt = try await owner.send(.load(ProfileRequest(userID: user)))
    await owner.shutdown()
    return receipt.revision
}

/// Links the snapshot sequences of every hosted owner and the presentation that observes one.
@MainActor public func stateMachineSequencePlatformCheck() async throws -> UInt64 {
    let note = GeneratedNote.MainActorHost(
        GeneratedNote.Draft(text: "platform-sequence"),
        saveDriver: { .success(GeneratedNote.Saved(text: $0.text)) }
    )
    var last: UInt64 = 0
    for await revision in try note.snapshots({ $0.revision }).prefix(1) { last += revision }
    for await snapshot in try note.snapshots() {
        last = snapshot.revision
        if !snapshot.isClosed { _ = note.close() }
    }
    let user = try UserID("platform-sequence")
    let shared = GeneratedProfile.Shared(
        GeneratedProfile.Idle(userID: user),
        fetchDriver: { _ in .failure(.unavailable) },
        auditDriver: { _ in .failure(.unavailable) }
    )
    let presentation = SnapshotPresentation(shared.snapshot())
    presentation.observe(try shared.snapshots())
    for await snapshot in try shared.snapshots() {
        last += snapshot.revision
        if !snapshot.isClosed { _ = shared.close() }
    }
    await presentation.follow(try shared.snapshots())
    if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
        let model = ObservableSnapshotPresentation(shared.snapshot())
        await model.follow(try shared.snapshots())
    }
    presentation.stopObserving()
    let actor = GeneratedProfile.ActorHost(
        GeneratedProfile.Idle(userID: user),
        fetchDriver: { _ in .failure(.unavailable) },
        auditDriver: { _ in .failure(.unavailable) }
    )
    for await snapshot in try await actor.snapshots() {
        last += snapshot.revision
        if !snapshot.isClosed { _ = await actor.close() }
    }
    let main = GeneratedProfile.MainActorHost(
        GeneratedProfile.Idle(userID: user),
        fetchDriver: { _ in .failure(.unavailable) },
        auditDriver: { _ in .failure(.unavailable) }
    )
    let sequence: GeneratedProfile.Snapshots = try main.snapshots()
    for await revision in sequence.map({ $0.revision }).prefix(1) { last += revision }
    presentation.observe(try main.snapshots())
    presentation.stopObserving()
    await main.shutdown()
    await note.shutdown()
    await shared.shutdown()
    await actor.shutdown()
    return last
}
