import StateMachine
import StateMachineExamples
import StateMachineTesting
import StateMachineUI
import Combine
import Foundation
import Observation
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

/// Appends a value to shared storage from any isolation.
nonisolated private func append<Value: Sendable>(_ value: Value, to storage: AtomicRecordStorage<[Value]>) {
    while true {
        let before = storage.load()
        if storage.install(AtomicRecordStorage<[Value]>.Version(before.value + [value]), replacing: before) { return }
    }
}

/// An actor that owns a confined profile host and runs one load on it.
private actor SmokeDesk {
    private var host: GeneratedProfile.IsolatedHost<SmokeDesk>?

    func load(_ request: ProfileRequest) async throws -> (revision: UInt64, name: String, joined: Bool) {
        let host = GeneratedProfile.IsolatedHost(
            GeneratedProfile.Idle(userID: request.userID),
            isolation: self,
            fetchDriver: { _, input in .success(Profile(userID: input.userID, name: "Isolated value")) },
            auditDriver: { _, _ in .failure(.unavailable) }
        )
        self.host = host
        let snapshots = try host.snapshots()
        try host.send(.load(request))
        var loaded: (revision: UInt64, name: String)?
        for await snapshot in snapshots {
            guard case .loaded(let value) = snapshot else { continue }
            loaded = (snapshot.revision, value.value.profile.name)
            break
        }
        let result = await host.shutdown()
        self.host = nil
        guard let loaded else { throw SmokeFailure(message: "The isolated host's sequence ended before the load") }
        // The count is read here, on the owning actor, rather than inside the `&&` autoclosure.
        let running = host.runningCount()
        return (loaded.revision, loaded.name, result == .quiescent && running == 0)
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
            try await snapshotSequence()
            try ownedResource()
            try await keyedTransfers()
            try await resetHost()
            try graphExport()
            try await isolatedHost()
            try await snapshotPublisher()
            try await distinctSnapshots()
            try testingProduct()
            try await mainActorObservation()
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
        let editor = ProfileEditor(
            request: request,
            drivers: GeneratedProfile.MainActorDrivers(fetch: drivers.fetch, audit: drivers.audit)
        )
        let trace = Trace<GeneratedProfile.Snapshot>()
        let observation = editor.presentation.presentedSnapshots.sink { [label] snapshot in
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
            editor.presentation.snapshot.revision == 1 && label.text == "Loading",
            "UI snapshot and UILabel did not advance in the input turn"
        )
        passed(
            "UI-SAME-TURN",
            ["revision": "1", "label": label.text ?? "", "isObserving": String(editor.presentation.isObserving)]
        )
        let first = await network.nextRequest()
        let failed = await network.complete(first.id, with: .failure(.unavailable))
        try require(failed, "Fake failure was not delivered")
        let failure = await trace.wait { if case .failed = $0 { true } else { false } }
        try require(failure.revision == 2 && label.text == "Failed", "Typed failure was not presented")
        _ = try editor.retry()
        let retry = await network.nextRequest()
        passed(
            "NETWORK-FAILURE-RETRY",
            ["failedRevision": String(failure.revision), "retryRevision": String(editor.presentation.snapshot.revision)]
        )
        let accepted = await network.complete(retry.id, with: .success(Profile(userID: user, name: "Runtime success")))
        try require(accepted, "Retry success was not delivered")
        let loaded = await trace.wait { if case .loaded = $0 { true } else { false } }
        try require(loaded.revision == 4 && label.text == "Runtime success", "Success did not follow typed retry")
        passed("NETWORK-SUCCESS", ["revision": String(loaded.revision), "label": label.text ?? ""])
        _ = try editor.refresh(request)
        let cancelled = await network.nextRequest()
        _ = try editor.cancel()
        _ = try editor.load()
        let replacement = await network.nextRequest()
        let oldAccepted = await network.complete(cancelled.id, with: .success(Profile(userID: user, name: "Obsolete")))
        let duplicate = await network.complete(cancelled.id, with: .failure(.unauthorized))
        try require(oldAccepted && !duplicate, "Fake did not enforce one physical completion")
        let replacementAccepted = await network.complete(
            replacement.id,
            with: .success(Profile(userID: user, name: "Replacement"))
        )
        try require(replacementAccepted, "Replacement did not complete")
        let replaced = await trace.wait { snapshot in
            if case .loaded(let value) = snapshot { value.value.profile.name == "Replacement" } else { false }
        }
        try require(label.text == "Replacement", "Late response overwrote replacement UI")
        passed(
            "NETWORK-CANCEL-LATE",
            ["replacementRevision": String(replaced.revision), "duplicateAccepted": String(duplicate)]
        )
        _ = try editor.refresh(request)
        let accountRequest = await network.nextRequest()
        _ = try editor.accountChanged()
        let invalidatedRevision = editor.presentation.snapshot.revision
        let oldAccount = await network.complete(
            accountRequest.id,
            with: .success(Profile(userID: user, name: "Prior account"))
        )
        try require(oldAccount, "Prior account response was not released")
        let openOwnerRevision = try openAccountInvalidation(request, user: user)
        editor.dispose()
        try require(
            !editor.presentation.isObserving && editor.presentation.snapshot.isClosed,
            "Navigation did not remove observation and close authority"
        )
        let disposedRevision = editor.presentation.snapshot.revision
        await editor.shutdown()
        try require(
            editor.isQuiescent && editor.presentation.snapshot.revision == disposedRevision,
            "Teardown did not join actual tasks"
        )
        guard case .loading = editor.presentation.snapshot else {
            throw SmokeFailure(message: "Revoked account response changed historical loading")
        }
        passed(
            "ACCOUNT-INVALIDATION",
            [
                "invalidatedRevision": String(invalidatedRevision), "closedRevision": String(disposedRevision),
                "historicalPhase": "loading", "openOwnerRevision": String(openOwnerRevision),
                "openOwnerOutcome": "stale",
            ]
        )
        let revisions = trace.values.map(\.revision)
        try require(revisions == revisions.sorted(), "UI observations regressed")
        passed(
            "TEARDOWN",
            [
                "isQuiescent": String(editor.isQuiescent), "isObserving": String(editor.presentation.isObserving),
                "revisions": String(describing: revisions),
            ]
        )
    }
    private func openAccountInvalidation(_ request: ProfileRequest, user: UserID) throws -> UInt64 {
        var local = GeneratedProfile.Local(GeneratedProfile.Idle(userID: user))
        guard case .committed = local.commit(try GeneratedProfile.prepare(.load(request), on: local.snapshot())),
            case .fetch(let work) = local.drainCommands(limit: 1).first?.commands.first,
            case .committed = local.commit(try GeneratedProfile.prepare(.authenticationChanged, on: local.snapshot()))
        else { throw SmokeFailure(message: "Open-owner account invalidation setup failed") }
        let revision = local.snapshot().revision
        guard case .stale = local.deliver(.fetch(work.succeeded(Profile(userID: user, name: "Unauthorized late value"))))
        else {
            throw SmokeFailure(message: "Account invalidation relied on close to revoke completion")
        }
        guard case .loading = local.snapshot() else {
            throw SmokeFailure(message: "Revoked result changed open-owner phase")
        }
        try require(
            local.snapshot().revision == revision && !local.snapshot().isClosed,
            "Revoked result changed open-owner revision"
        )
        let acknowledgment = local.acknowledgeExecution(work.execution, disposition: .terminated)
        try require(acknowledgment == .recorded, "Open-owner execution was not acknowledged")
        _ = local.close()
        _ = local.drainCommands(limit: 100)
        let settled = local.isQuiescent
        try require(settled, "Open-owner Local obligations did not settle")
        return revision
    }
    private func isolatedEditor() async throws {
        let owner = IsolatedNote.MainActorHost(
            IsolatedNote.Draft(text: "Confined note", tags: ["editor"]),
            drivers: IsolatedNote.MainActorDrivers(save: { input in
                .success(IsolatedNote.Saved(text: input.text, tags: input.tags))
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
            ["text": saved.value.text, "joinedWorkers": String(owner.runningCount), "revision": String(saved.revision)]
        )
    }
    private func actorAndLocal() async throws {
        let user = try UserID("actor-user")
        let request = try ProfileRequest(userID: user)
        var local = GeneratedProfile.Local(GeneratedProfile.Idle(userID: user))
        guard case .committed = local.commit(try GeneratedProfile.prepare(.load(request), on: local.snapshot())),
            case .fetch(let work) = local.drainCommands(limit: 1).first?.commands.first
        else { throw SmokeFailure(message: "Local did not issue typed work") }
        guard case .committed = local.deliver(.fetch(work.succeeded(Profile(userID: user, name: "Actor value")))) else {
            throw SmokeFailure(message: "Local rejected its own terminal completion")
        }
        let acknowledgment = local.acknowledgeExecution(work.execution, disposition: .terminated)
        try require(acknowledgment == .recorded, "Local did not record physical execution separately")
        _ = local.close()
        _ = local.drainCommands(limit: 100)
        let localQuiescent = local.isQuiescent
        try require(localQuiescent, "Local manual obligations did not settle")
        let actor = GeneratedProfile.ActorHost(
            GeneratedProfile.Idle(userID: user),
            fetchDriver: { input in
                .success(Profile(userID: input.userID, name: "Actor value"))
            },
            auditDriver: { _ in .failure(.unavailable) }
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
            model: .loaded(ReferenceProfile.Loaded(profile: Profile(userID: user, name: "Persisted"))),
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
        await source.shutdown()
        await restored.shutdown()
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
            GeneratedNote.Draft(text: "terminal"),
            saveDriver: { GeneratedNote.Saved(text: $0.text) }
        )
        var revisions: [UInt64] = []
        var finishes = 0
        let token = try owner.subscribe({ revisions.append($0.revision) }, onFinish: { finishes += 1 })
        let receipt = owner.close()
        let processed = await owner.flush(through: receipt)
        try require(
            processed == .processed && revisions == [0, 1] && finishes == 1 && owner.subscriberCount == 0,
            "Initial and terminal subscription contract failed"
        )
        token.cancel()
        await owner.shutdown()
        passed(
            "SUBSCRIPTION-TERMINAL",
            [
                "revisions": String(describing: revisions), "finishes": String(finishes),
                "subscribers": String(owner.subscriberCount),
            ]
        )
    }
    private func snapshotSequence() async throws {
        let owner = GeneratedNote.MainActorHost(
            GeneratedNote.Draft(text: "sequence"),
            saveDriver: { GeneratedNote.Saved(text: $0.text) }
        )
        let label = UILabel()
        var revisions: [UInt64] = []
        var snapshots = try owner.snapshots()
        while let snapshot = await snapshots.next() {
            revisions.append(snapshot.revision)
            switch snapshot {
            case .draft(let draft):
                label.text = draft.value.text
                if snapshot.revision == 0 {
                    _ = try owner.send(.edit("sequence edited"))
                } else if !snapshot.isClosed {
                    _ = owner.close()
                }
            case .saving, .saved: break
            }
        }
        try require(
            revisions == [0, 1, 2] && label.text == "sequence edited" && owner.subscriberCount == 0,
            "Snapshot sequence did not follow the owner to its closed snapshot"
        )
        await owner.shutdown()
        passed(
            "SNAPSHOT-SEQUENCE",
            ["revisions": String(describing: revisions), "label": label.text ?? ""]
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
    /// Runs keyed downloads of two files through a controlled driver, cancels one key, and reads the log.
    private func keyedTransfers() async throws {
        let download = KeyedControlledDriver<Int, String, String, GeneratedTransfers.TransferFailure>()
        let lines = AtomicRecordStorage<[String]>([])
        let owner = GeneratedTransfers.Shared(downloadDriver: download.run, onLogged: { append($0, to: lines) })
        let snapshots = try owner.snapshots()
        try owner.send(.download(1))
        try owner.send(.download(2))
        // Each execution runs in its own task, so each key's call is taken by its key.
        let second = try await download.nextStarted(for: 2)
        let first = try await download.nextStarted(for: 1)
        try require([first.key, second.key] == [1, 2], "Keyed work did not reach the driver under its own key")
        try owner.send(.cancel(1))
        try await first.waitForCancellation()
        try require(!second.isCancelled, "Cancelling one key cancelled another key's work")
        second.succeed("two")
        first.succeed("late")
        var files: [Int: String] = [:]
        for await snapshot in snapshots {
            guard case .browsing(let browsing) = snapshot, !browsing.value.files.isEmpty else { continue }
            files = browsing.value.files
            break
        }
        try require(files == [2: "two"], "A keyed completion was not filed under its own key")
        let result = await owner.shutdown()
        try require(result == .quiescent, "Keyed workers were not joined")
        passed(
            "KEYED-OPERATION",
            ["keys": "[1, 2]", "cancelledKey": String(first.key), "files": String(describing: files)]
        )
        let logged = lines.load().value
        try require(logged == ["download 1", "download 2", "downloaded 2"], "Event handler order changed: \(logged)")
        passed("EVENT-HANDLER", ["lines": String(describing: logged)])
    }
    /// Resets a MainActor owner while its driver runs, and delivers the driver's late result.
    private func resetHost() async throws {
        let download = KeyedControlledDriver<Int, String, String, GeneratedTransfers.TransferFailure>()
        var logged: [String] = []
        let owner = GeneratedTransfers.MainActorHost(downloadDriver: download.run, onLogged: { logged.append($0) })
        try owner.send(.download(7))
        let call = try await download.nextStarted()
        let before = owner.snapshot().revision
        let receipt = try owner.reset()
        try await call.waitForCancellation()
        call.succeed("late")
        await owner.shutdown()
        guard case .browsing(let browsing) = owner.snapshot(), browsing.value.files.isEmpty else {
            throw SmokeFailure(message: "A result of work from before the reset changed the model")
        }
        try require(receipt.revision == before + 1 && logged == ["download 7"], "Reset did not advance the revision")
        passed(
            "RESET",
            [
                "resetRevision": String(receipt.revision), "driverCancelled": String(call.isCancelled),
                "files": String(describing: browsing.value.files),
            ]
        )
    }
    /// Renders a graph's Mermaid and Graphviz text and round-trips its description through JSON.
    private func graphExport() throws {
        let graph = GeneratedTransfers.graph
        let mermaid = graph.mermaid()
        let expected =
            [
                "stateDiagram-v2", "    state \"browsing\" as p0", "    state \"offline\" as p1", "    [*] --> p0",
                "    p0 --> p0 : download", "    p0 --> p0 : cancel", "    p0 --> p1 : goOffline",
                "    p1 --> p0 : goOnline", "    p0 --> p0 : downloaded", "    p0 --> p0 : failed",
            ]
            .joined(separator: "\n") + "\n"
        try require(mermaid == expected, "The Mermaid rendering changed: \(mermaid)")
        let decoded = try JSONDecoder().decode(StateMachineGraph.self, from: JSONEncoder().encode(graph))
        try require(decoded == graph, "The graph description did not survive encoding")
        try require(graph.dot().hasPrefix("digraph \"GeneratedTransfers\" {"), "The Graphviz rendering changed")
        passed(
            "GRAPH-MERMAID",
            ["lines": String(mermaid.split(separator: "\n").count), "edges": String(graph.edges.count)]
        )
    }
    /// Loads a profile on a host confined to an actor the app chose.
    private func isolatedHost() async throws {
        let request = try ProfileRequest(userID: UserID("isolated-user"))
        let loaded = try await SmokeDesk().load(request)
        try require(loaded.name == "Isolated value" && loaded.joined, "The isolated host did not load and join")
        passed("ISOLATED-HOST", ["revision": String(loaded.revision), "name": loaded.name])
    }
    /// Tracks a MainActor host's snapshot and subscriber count separately with Observation.
    private func mainActorObservation() async throws {
        guard #available(iOS 17.0, *) else {
            passed("OBSERVATION-MAINACTOR-HOST", ["observable": "false", "reason": "Observation requires iOS 17"])
            return
        }
        let owner = GeneratedTransfers.MainActorHost(downloadDriver: { _, _ in .failure(.unavailable) }, onLogged: { _ in })
        let snapshotReads = AtomicRecordStorage<[Bool]>([])
        let countReads = AtomicRecordStorage<[Bool]>([])
        withObservationTracking { _ = owner.currentSnapshot } onChange: { append(true, to: snapshotReads) }
        withObservationTracking { _ = owner.subscriberCount } onChange: { append(true, to: countReads) }
        let receipt = try owner.send(.goOffline)
        _ = await owner.flush(through: receipt)
        let snapshotChanges = snapshotReads.load().value.count
        let countChanges = countReads.load().value.count
        try require(
            snapshotChanges == 1 && countChanges == 0,
            "Observation did not report only the snapshot: \(snapshotChanges), \(countChanges)"
        )
        await owner.shutdown()
        passed(
            "OBSERVATION-MAINACTOR-HOST",
            ["observable": "true", "snapshotChanges": String(snapshotChanges), "countChanges": String(countChanges)]
        )
    }
    /// Receives a shared owner's snapshots through Combine until the publisher finishes.
    private func snapshotPublisher() async throws {
        let owner = GeneratedTransfers.Shared(downloadDriver: { _, _ in .failure(.unavailable) }, onLogged: { _ in })
        let publisher = try owner.snapshotPublisher()
        try require(owner.subscriberCount == 1, "The publisher did not take its slot at creation")
        let revisions = Trace<UInt64>()
        let finished = Trace<Bool>()
        let cancellable = publisher.sink(
            receiveCompletion: { _ in finished.record(true) },
            receiveValue: { revisions.record($0.revision) }
        )
        _ = await revisions.wait { _ in true }
        let edited = try owner.send(.goOffline)
        _ = await revisions.wait { $0 >= edited.revision }
        let closed = owner.close()
        _ = await finished.wait { $0 }
        cancellable.cancel()
        let values = revisions.values
        try require(
            values == values.sorted() && values.last == closed.revision && owner.subscriberCount == 0,
            "The publisher did not follow the owner to its closed snapshot: \(values)"
        )
        await owner.shutdown()
        passed("SNAPSHOT-PUBLISHER", ["revisions": String(describing: values), "finished": "true"])
    }
    /// Observes a projection that omits values equal to the one before it.
    private func distinctSnapshots() async throws {
        let download = KeyedControlledDriver<Int, String, String, GeneratedTransfers.TransferFailure>()
        let owner = GeneratedTransfers.Shared(downloadDriver: download.run, onLogged: { _ in })
        let counts = try owner.distinctSnapshots { snapshot -> Int in
            if case .browsing(let browsing) = snapshot { browsing.value.files.count } else { -1 }
        }
        var iterator = counts.makeAsyncIterator()
        var observed: [Int] = []
        if let first = await iterator.next() { observed.append(first) }
        try owner.send(.download(1))
        try await download.nextStarted().succeed("one")
        if let next = await iterator.next() { observed.append(next) }
        // Neither the next change nor the closed snapshot changes the count, so both are omitted.
        let unchanged = try owner.send(.cancel(9))
        _ = await owner.flush(through: unchanged)
        owner.close()
        while let more = await iterator.next() { observed.append(more) }
        try require(observed == [0, 1], "Equal projections were not omitted: \(observed)")
        await owner.shutdown()
        passed("DISTINCT-SNAPSHOTS", ["counts": String(describing: observed)])
    }
    /// Drives a Local through the testing product's harness and requires full graph coverage.
    private func testingProduct() throws {
        var test = ManualMachineTest(GeneratedTransfers.Local())
        try test.send(.download(1))
        try test.send(.download(2))
        let works = test.drainFlattenedCommands().compactMap { command -> GeneratedTransfers.DownloadWork? in
            if case .download(let work) = command { work } else { nil }
        }
        guard works.count == 2, case .committed = test.deliver(.download(works[0].succeeded("one"))),
            case .committed = test.deliver(.download(works[1].failed(.unavailable)))
        else { throw SmokeFailure(message: "The harness did not deliver issued work") }
        for work in works {
            try require(test.acknowledgeExecution(work.execution) == .recorded, "An execution was not acknowledged")
        }
        try test.send(.cancel(3))
        try test.send(.goOffline)
        try test.send(.goOnline)
        test.close()
        _ = test.drainFlattenedCommands()
        let quiescent = test.isQuiescent
        try require(quiescent, "The harness's owner did not settle")
        var coverage = GraphCoverage(for: GeneratedTransfers.Local.self)
        coverage.record(test)
        try coverage.requireCoverage()
        passed(
            "TESTING-MANUAL-COVERAGE",
            ["steps": String(test.history.count), "edges": String(coverage.exercisedEdgeIDs.count)]
        )
    }
    private func finishResource(_ releases: AtomicRecordStorage<[Int]>) throws -> Int {
        let owned = ResourceWorkflow.start(
            ResourceWorkflow.Resource(
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
