import StateMachine
import StateMachineExamples
import StateMachineSchema
import StateMachineUI
import Combine
import Foundation
import UIKit

nonisolated private struct SmokeFailure: Error { let message: String }
nonisolated private struct Check: Encodable {
    let id: String
    let status: String
    let observations: [String: String]
}
nonisolated private struct ResultFile: Encodable {
    let status: String
    let systemVersion: String
    let checks: [Check]
    let error: String?
}

@MainActor private final class Trace<Value> {
    private struct Waiter {
        let predicate: @MainActor (Value) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }
    private(set) var values: [Value] = []
    private var waiters: [Waiter] = []
    func record(_ value: Value) {
        values.append(value)
        let completed = waiters.filter { $0.predicate(value) }
        waiters.removeAll { $0.predicate(value) }
        for waiter in completed { waiter.continuation.resume() }
    }
    func wait(_ predicate: @escaping @MainActor (Value) -> Bool) async -> Value {
        while true {
            if let value = values.last(where: { predicate($0) }) { return value }
            await withCheckedContinuation { waiters.append(Waiter(predicate: predicate, continuation: $0)) }
        }
    }
}

@MainActor private final class SmokeSuite {
    private let label: UILabel
    private var checks: [Check] = []
    init(label: UILabel) { self.label = label }
    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw SmokeFailure(message: message) }
    }
    private func passed(_ id: String, _ observations: [String: String]) {
        checks.append(Check(id: id, status: "pass", observations: observations))
    }
    func run() async {
        var failure: String?
        do {
            try await profileScreen()
            try await isolatedEditor()
            try await actorAndLocal()
            try await persistence()
            try await terminalSubscription()
            try ownedResource()
        } catch { failure = String(describing: error) }
        let result = ResultFile(
            status: failure == nil ? "pass" : "fail",
            systemVersion: UIDevice.current.systemVersion,
            checks: checks,
            error: failure
        )
        do {
            let directory = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            try JSONEncoder().encode(result)
                .write(to: directory.appendingPathComponent("result.json"), options: .atomic)
            label.text =
                failure == nil ? "StateMachine: \(checks.count) checks passed" : "StateMachine failed: \(failure!)"
        } catch { label.text = "Could not write smoke result: \(error)" }
    }
    private func profileScreen() async throws {
        let user = try UserID("runtime-user")
        let request = try ProfileRequest(userID: user)
        let network = ControlledProfileNetwork()
        let drivers = network.drivers
        let editor = try ProfileEditor(request: request, drivers: .init(fetch: drivers.fetch, audit: drivers.audit))
        let trace = Trace<GeneratedProfile.Snapshot>()
        let observation = editor.presentation.$snapshot.sink { [label] snapshot in
            trace.record(snapshot)
            switch snapshot {
            case .idle: label.text = "Idle"
            case .loading: label.text = "Loading"
            case .loaded(let value): label.text = value.value.profile.name
            case .failed: label.text = "Failed"
            }
        }
        defer { observation.cancel() }
        _ = try editor.load()
        guard case .loading = editor.presentation.snapshot else {
            throw SmokeFailure(message: "UI load did not accept synchronously")
        }
        try require(
            editor.presentation.snapshot.ordinal == 1 && label.text == "Loading",
            "UI snapshot and UILabel did not advance in the input turn"
        )
        passed(
            "UI-SAME-TURN",
            ["ordinal": "1", "label": label.text ?? "", "isObserving": String(editor.presentation.isObserving)]
        )
        let first = await network.nextRequest()
        let failed = await network.complete(first.id, with: .failure(.unavailable))
        try require(failed, "Fake failure was not delivered")
        let failure = await trace.wait { if case .failed = $0 { true } else { false } }
        try require(failure.ordinal == 2 && label.text == "Failed", "Typed failure was not presented")
        _ = try editor.retry()
        let retry = await network.nextRequest()
        passed(
            "NETWORK-FAILURE-RETRY",
            ["failedOrdinal": String(failure.ordinal), "retryOrdinal": String(editor.presentation.snapshot.ordinal)]
        )
        let accepted = await network.complete(retry.id, with: .success(.init(userID: user, name: "Runtime success")))
        try require(accepted, "Retry success was not delivered")
        let loaded = await trace.wait { if case .loaded = $0 { true } else { false } }
        try require(loaded.ordinal == 4 && label.text == "Runtime success", "Success did not follow typed retry")
        passed("NETWORK-SUCCESS", ["ordinal": String(loaded.ordinal), "label": label.text ?? ""])
        _ = try editor.refresh(request)
        let cancelled = await network.nextRequest()
        _ = try editor.cancel()
        _ = try editor.load()
        let replacement = await network.nextRequest()
        let oldAccepted = await network.complete(cancelled.id, with: .success(.init(userID: user, name: "Obsolete")))
        let duplicate = await network.complete(cancelled.id, with: .failure(.unauthorized))
        try require(oldAccepted && !duplicate, "Fake did not enforce one physical completion")
        let replacementAccepted = await network.complete(
            replacement.id,
            with: .success(.init(userID: user, name: "Replacement"))
        )
        try require(replacementAccepted, "Replacement did not complete")
        let replaced = await trace.wait { snapshot in
            if case .loaded(let value) = snapshot { value.value.profile.name == "Replacement" } else { false }
        }
        try require(label.text == "Replacement", "Late response overwrote replacement UI")
        passed(
            "NETWORK-CANCEL-LATE",
            ["replacementOrdinal": String(replaced.ordinal), "duplicateAccepted": String(duplicate)]
        )
        _ = try editor.refresh(request)
        let accountRequest = await network.nextRequest()
        _ = try editor.accountChanged()
        let invalidatedOrdinal = editor.presentation.snapshot.ordinal
        let oldAccount = await network.complete(
            accountRequest.id,
            with: .success(.init(userID: user, name: "Prior account"))
        )
        try require(oldAccount, "Prior account response was not released")
        let openOwnerOrdinal = try openAccountInvalidation(request, user: user)
        editor.dispose()
        try require(
            !editor.presentation.isObserving && editor.presentation.snapshot.isClosed,
            "Navigation did not remove observation and close authority"
        )
        let disposedOrdinal = editor.presentation.snapshot.ordinal
        await editor.shutdown()
        try require(
            editor.isQuiescent && editor.presentation.snapshot.ordinal == disposedOrdinal,
            "Teardown did not join actual tasks"
        )
        guard case .loading = editor.presentation.snapshot else {
            throw SmokeFailure(message: "Revoked account response changed historical loading")
        }
        passed(
            "ACCOUNT-INVALIDATION",
            [
                "invalidatedOrdinal": String(invalidatedOrdinal), "closedOrdinal": String(disposedOrdinal),
                "historicalPhase": "loading", "openOwnerOrdinal": String(openOwnerOrdinal),
                "openOwnerOutcome": "stale",
            ]
        )
        let ordinals = trace.values.map(\.ordinal)
        try require(ordinals == ordinals.sorted(), "UI observations regressed")
        passed(
            "TEARDOWN",
            [
                "isQuiescent": String(editor.isQuiescent), "isObserving": String(editor.presentation.isObserving),
                "ordinals": String(describing: ordinals),
            ]
        )
    }
    private func openAccountInvalidation(_ request: ProfileRequest, user: UserID) throws -> UInt64 {
        var local = GeneratedProfile.Local(.init(userID: user))
        guard case .prepared(let start) = GeneratedProfile.prepare(.load(request), on: local.snapshot()),
            case .committed = local.commit(start),
            case .fetch(let work) = local.drainCommands(limit: 1).first?.commands.first,
            case .prepared(let invalidation) = GeneratedProfile.prepare(.authenticationChanged, on: local.snapshot()),
            case .committed = local.commit(invalidation)
        else { throw SmokeFailure(message: "Open-owner account invalidation setup failed") }
        let ordinal = local.snapshot().ordinal
        guard case .stale = local.deliver(.fetch(work.succeeded(.init(userID: user, name: "Unauthorized late value"))))
        else {
            throw SmokeFailure(message: "Account invalidation relied on close to revoke completion")
        }
        guard case .loading = local.snapshot() else {
            throw SmokeFailure(message: "Revoked result changed open-owner phase")
        }
        try require(
            local.snapshot().ordinal == ordinal && !local.snapshot().isClosed,
            "Revoked result changed open-owner revision"
        )
        let acknowledgment = local.acknowledgeExecution(work.execution, disposition: .terminated)
        try require(acknowledgment == .recorded, "Open-owner execution was not acknowledged")
        _ = local.close()
        _ = local.drainCommands(limit: 100)
        let settled = local.isQuiescent
        try require(settled, "Open-owner Local obligations did not settle")
        return ordinal
    }
    private func isolatedEditor() async throws {
        let owner = IsolatedNote.MainActorHost(
            .init(text: "Confined note", tags: ["editor"]),
            drivers: .init(save: { input in
                .success(.init(text: input.text, tags: input.tags))
            })
        )
        let trace = Trace<IsolatedNote.Snapshot>()
        let token = try owner.subscribe { trace.record($0) }
        _ = try owner.send(.save)
        let saved = await trace.wait { if case .saved = $0 { true } else { false } }
        try require(
            saved.value.text == "Confined note" && saved.value.tags == ["editor"],
            "Isolated value outcome changed"
        )
        token.cancel()
        await owner.shutdown()
        try require(owner.runningCount == 0 && owner.isQuiescent, "Isolated Void worker was not joined")
        passed(
            "ISOLATED-EDITOR",
            ["text": saved.value.text, "joinedWorkers": String(owner.runningCount), "ordinal": String(saved.ordinal)]
        )
    }
    private func actorAndLocal() async throws {
        let user = try UserID("actor-user")
        let request = try ProfileRequest(userID: user)
        var local = GeneratedProfile.Local(.init(userID: user))
        guard case .prepared(let preparation) = GeneratedProfile.prepare(.load(request), on: local.snapshot()),
            case .committed = local.commit(preparation),
            case .fetch(let work) = local.drainCommands(limit: 1).first?.commands.first
        else { throw SmokeFailure(message: "Local did not issue typed work") }
        guard case .committed = local.deliver(.fetch(work.succeeded(.init(userID: user, name: "Actor value")))) else {
            throw SmokeFailure(message: "Local rejected its own terminal completion")
        }
        let acknowledgment = local.acknowledgeExecution(work.execution, disposition: .terminated)
        try require(acknowledgment == .recorded, "Local did not record physical execution separately")
        _ = local.close()
        _ = local.drainCommands(limit: 100)
        let localQuiescent = local.isQuiescent
        try require(localQuiescent, "Local manual obligations did not settle")
        let actor = GeneratedProfile.ActorHost(
            .init(userID: user),
            drivers: .init(
                fetch: { input in
                    .success(.init(userID: input.userID, name: "Actor value"))
                },
                audit: { _ in .failure(.unavailable) }
            )
        )
        let (stream, events) = AsyncStream<GeneratedProfile.Snapshot>.makeStream()
        let token = try await actor.subscribe { events.yield($0) }
        _ = try await actor.send(.load(request))
        var iterator = stream.makeAsyncIterator()
        var final: GeneratedProfile.Snapshot?
        while let snapshot = await iterator.next() {
            if case .loaded = snapshot {
                final = snapshot
                break
            }
        }
        guard let final, case .loaded(let value) = final else {
            throw SmokeFailure(message: "Actor did not deliver success")
        }
        try require(value.value.profile.name == "Actor value", "Actor and Local domain values differ")
        token.cancel()
        events.finish()
        await actor.shutdown()
        let running = await actor.runningCount
        try require(running == 0, "Actor worker was not joined")
        passed(
            "ACTOR-LOCAL",
            [
                "profile": value.value.profile.name, "localAcknowledgment": "recorded",
                "actorJoinedWorkers": String(running),
            ]
        )
    }
    private func persistence() async throws {
        let user = try UserID("runtime-user")
        let archive = try ReferenceProfile.Archive(
            model: .loaded(.init(profile: .init(userID: user, name: "Persisted"))),
            presentation: "screen"
        )
        let data = try JSONEncoder().encode(archive)
        let directory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let path = directory.appendingPathComponent("profile.json")
        try data.write(to: path, options: .atomic)
        let decoded = try JSONDecoder().decode(ReferenceProfile.Archive.self, from: Data(contentsOf: path))
        let legacy = Data(#"{"model":{"idle":{"_0":{"userID":"runtime-user"}}},"presentation":"legacy"}"#.utf8)
        let migrated = try JSONDecoder().decode(ReferenceProfile.Archive.self, from: legacy)
        try require(migrated.presentation == "legacy", "Legacy archive did not migrate")
        var unknownRejected = false
        do {
            _ = try JSONDecoder().decode(ReferenceProfile.Archive.self, from: Data(#"{"version":2}"#.utf8))
        } catch ReferenceProfile.Archive.DecodingRejection.unsupportedVersion(2) { unknownRejected = true }
        try require(unknownRejected, "Unknown version did not fail before payload decode")
        var invalidRejected = false
        do {
            _ = try JSONDecoder()
                .decode(
                    ReferenceProfile.Archive.self,
                    from: Data(#"{"version":1,"model":{"idle":{"_0":{"userID":"bad id"}}},"presentation":""}"#.utf8)
                )
        } catch UserID.ValidationFailure.invalidIdentifier { invalidRejected = true }
        try require(invalidRejected, "Invalid decoded model became live data")
        let drivers = ReferenceProfile.Drivers(
            fetch: { _ in .failure(.unavailable) },
            audit: { _ in .failure(.unavailable) }
        )
        let source = ReferenceProfile.Shared.restore(archive, drivers: drivers)
        let restored = ReferenceProfile.Shared.restore(decoded, drivers: drivers)
        let old = source.snapshot().presentationChanged("foreign")
        guard case .rejected(.foreignOwner, _) = restored.commit(old) else {
            throw SmokeFailure(message: "Restoration adopted old owner authority")
        }
        _ = await source.shutdownAndWait()
        _ = await restored.shutdownAndWait()
        passed(
            "PERSISTENCE",
            [
                "version": String(ReferenceProfile.Archive.currentVersion), "legacyPresentation": migrated.presentation,
                "foreignProof": "rejected", "validatedPayload": "true",
            ]
        )
    }
    private func terminalSubscription() async throws {
        let owner = GeneratedNote.MainActorHost(
            .init(text: "terminal"),
            drivers: .init(save: { .success(.init(text: $0.text)) })
        )
        var ordinals: [UInt64] = []
        var finishes = 0
        let token = try owner.subscribe({ ordinals.append($0.ordinal) }, onFinish: { finishes += 1 })
        let receipt = owner.close()
        let processed = await owner.flush(through: receipt)
        try require(
            processed && ordinals == [0, 1] && finishes == 1 && owner.subscriberCount == 0,
            "Initial and terminal subscription contract failed"
        )
        token.cancel()
        await owner.shutdown()
        passed(
            "SUBSCRIPTION-TERMINAL",
            [
                "ordinals": String(describing: ordinals), "finishes": String(finishes),
                "subscribers": String(owner.subscriberCount),
            ]
        )
    }
    private func ownedResource() throws {
        let releases = AtomicRecordStorage<[Int]>([])
        let identifier = try finishResource(releases)
        try require(
            identifier == 7 && releases.load().value == [7],
            "Owned-only resource did not preserve and dispose unique ownership"
        )
        passed(
            "OWNED-RESOURCE",
            ["identifier": String(identifier), "releases": String(describing: releases.load().value)]
        )
    }
    private func finishResource(_ releases: AtomicRecordStorage<[Int]>) throws -> Int {
        let owned = ResourceWorkflow.start(
            .init(
                identifier: 7,
                onRelease: { id in
                    while true {
                        let before = releases.load()
                        if releases.install(.init(before.value + [id]), replacing: before) { return }
                    }
                }
            )
        )
        switch owned.finish(label: "done") {
        case .advanced(let next, let effects):
            try require(effects == [.audit(7), .publish("done")], "Owned inert effect order changed")
            return next.withValue { $0.identifier }
        case .rejected: throw SmokeFailure(message: "Owned transition unexpectedly rejected")
        }
    }
}

@main @MainActor final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    private var suite: Task<Void, Never>?
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let screen = UIViewController()
        let label = UILabel()
        label.numberOfLines = 0
        label.text = "Running StateMachine public-product checks"
        label.frame = CGRect(x: 24, y: 100, width: 340, height: 300)
        screen.view.backgroundColor = .systemBackground
        screen.view.addSubview(label)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UINavigationController(rootViewController: screen)
        window.makeKeyAndVisible()
        self.window = window
        suite = Task<Void, Never> { @MainActor in await SmokeSuite(label: label).run() }
        return true
    }
}
