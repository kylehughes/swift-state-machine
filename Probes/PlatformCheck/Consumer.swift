import StateMachine
import StateMachineExamples
import StateMachineSchema
import StateMachineUI

@StateMachine(mode: .shared)
nonisolated private enum PlatformWorkflow: Sendable {
    struct Idle: Sendable { let value: Int }
    @Initial case idle(Idle)
    enum Input: Sendable { case edit(Int) }
    enum Effect: Sendable {}

    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: borrowing Idle, _ value: Int) -> Change<Idle, Effect> {
        Change(Idle(value: value))
    }
}

/// Exercises the public shared-owner path in a linked library consumer.
public func stateMachinePlatformCheck() throws -> UInt64 {
    let user = try UserID("platform-check")
    let owner = ReferenceProfile.Shared(
        .init(userID: user),
        drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
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
    var owner = PlatformWorkflow.Local(.init(value: 0))
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
        drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
    )
    guard case .committed(let receipt) = try editor.load() else { return 0 }
    let presentation = editor.presentation
    let ingress = MainActorSnapshotIngress<GeneratedProfile.Snapshot> { [weak presentation] in
        presentation?.apply($0)
    }
    ingress.offer(receipt.snapshot, revision: receipt.revision)
    ingress.cancel()
    editor.dispose()
    return presentation.snapshot.revision
}

/// Links native actor admission and managed shutdown through normal public imports.
public func stateMachineActorPlatformCheck() async throws -> UInt64 {
    let user = try UserID("platform-actor")
    let owner = GeneratedProfile.ActorHost(
        .init(userID: user),
        drivers: .init(fetch: { _ in .failure(.unavailable) }, audit: { _ in .failure(.unavailable) })
    )
    guard case .committed(let receipt) = try await owner.send(.load(ProfileRequest(userID: user))) else { return 0 }
    await owner.shutdown()
    return receipt.revision
}
