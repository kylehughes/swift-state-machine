import StateMachine
import Testing

/// A file browser whose downloads, uploads, and syncs are each keyed by file identifier.
@StateMachine(mode: .shared)
nonisolated private enum Files: Sendable {
    struct Browsing: Sendable {
        var contents: [Int: String] = [:]
        var uploaded: [Int] = []
        var synced: [Int] = []
    }
    @Initial case browsing(Browsing = Browsing())
    enum Input: Sendable {
        case download(Int)
        case downloadTwice(Int)
        case downloadPair(Int)
        case remove(Int)
        case removeAll
        case upload(Int)
        case reupload(Int)
        case sync(Int)
        case touch
    }
    /// Replaces a key's earlier download.
    @Operation(activeIn: [Browsing.self], admission: .latest)
    enum Download {
        typealias Key = Int
        typealias Input = String
        typealias Output = String
    }
    /// Refuses a second upload of one file while the first is active.
    @Operation(activeIn: [Browsing.self], admission: .rejectWhenActive)
    enum Upload {
        typealias Key = Int
    }
    /// Admits two syncs of one file at a time.
    @Operation(activeIn: [Browsing.self], admission: .parallel(limit: 2))
    enum Sync {
        typealias Key = Int
        typealias Input = String
    }
    @Transition(on: Input.download, starts: [Download.self])
    static func download(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Download> {
        Change(source, effects: [.download(key: id, input: "file-\(id)")])
    }
    @Transition(on: Input.downloadTwice, starts: [Download.self])
    static func downloadTwice(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.DownloadTwice> {
        Change(source, effects: [.download(key: id, input: "first"), .download(key: id, input: "second")])
    }
    @Transition(on: Input.downloadPair, starts: [Download.self])
    static func downloadPair(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.DownloadPair> {
        Change(
            source,
            effects: [.download(key: id, input: "file-\(id)"), .download(key: id + 1, input: "file-\(id + 1)")]
        )
    }
    @Transition(on: Input.remove, cancels: [Download.self])
    static func remove(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Remove> {
        var next = source
        next.contents[id] = nil
        return Change(next, effects: [.cancelDownload(key: id)])
    }
    @Transition(on: Input.removeAll, cancels: [Download.self])
    static func removeAll(_ source: Browsing) -> Change<Browsing, Effect.RemoveAll> {
        Change(Browsing(), effects: [.cancelAllDownload])
    }
    @Transition(on: Input.upload, starts: [Upload.self])
    static func upload(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Upload> {
        Change(source, effects: [.upload(key: id)])
    }
    /// Cancels a file's upload and starts it again in one change.
    @Transition(on: Input.reupload, starts: [Upload.self], cancels: [Upload.self])
    static func reupload(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Reupload> {
        Change(source, effects: [.cancelUpload(key: id), .upload(key: id)])
    }
    @Transition(on: Input.sync, starts: [Sync.self])
    static func sync(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Sync> {
        Change(source, effects: [.sync(key: id, input: "sync-\(id)")])
    }
    @Transition(on: Input.touch)
    static func touch(_ source: Browsing) -> Browsing { source }
    /// Files the content under the key its download was started for, and syncs that file.
    @Transition(onSuccess: Download.self, starts: [Sync.self])
    static func downloaded(
        _ source: Browsing,
        _ content: Download.Output,
        request: DownloadRequest
    ) -> Change<Browsing, Effect.Downloaded> {
        var next = source
        next.contents[request.key] = content + " from " + request.input
        return Change(next, effects: [.sync(key: request.key, input: "sync-\(request.key)")])
    }
    @Transition(onSuccess: Upload.self)
    static func uploaded(_ source: Browsing, request: UploadRequest) -> Browsing {
        var next = source
        next.uploaded.append(request.key)
        return next
    }
    @Transition(onSuccess: Sync.self)
    static func synced(_ source: Browsing, request: SyncRequest) -> Browsing {
        var next = source
        next.synced.append(request.key)
        return next
    }
}

@Suite(.timeLimit(.minutes(1))) struct KeyedOperationTests {
    private struct Unexpected: Error {}

    /// Every command of the batches `drainCommands` returns, in order.
    private func commands(_ local: inout Files.Local) -> [Files.Command] {
        local.drainCommands().flatMap(\.commands)
    }

    private func downloads(_ commands: [Files.Command]) -> [Files.DownloadWork] {
        commands.compactMap { if case .download(let work) = $0 { work } else { nil } }
    }

    private func cancellations(_ commands: [Files.Command]) -> [Files.ExecutionHandle] {
        commands.compactMap { if case .cancel(let handle) = $0 { handle } else { nil } }
    }

    private func contents(_ local: borrowing Files.Local) -> [Int: String] {
        guard case .browsing(let browsing) = local.snapshot() else { return [:] }
        return browsing.value.contents
    }

    @Test func latestReplacesOnlyTheSameKeysWorkAndItsLateResultIsStale() throws {
        var local = Files.Local()
        try local.send(.download(1))
        try local.send(.download(2))
        let first = downloads(commands(&local))
        #expect(first.map(\.key) == [1, 2])
        #expect(first.map(\.input) == ["file-1", "file-2"])
        try local.send(.download(1))
        let replacement = commands(&local)
        // Only key 1's earlier work is revoked; key 2's keeps its authority.
        #expect(cancellations(replacement) == [first[0].execution])
        let again = try #require(downloads(replacement).first)
        guard case .stale = local.deliver(first[0].succeeded("old")) else { throw Unexpected() }
        guard case .committed = local.deliver(first[1].succeeded("two")) else { throw Unexpected() }
        guard case .committed = local.deliver(again.succeeded("new")) else { throw Unexpected() }
        #expect(contents(local) == [1: "new from file-1", 2: "two from file-2"])
    }

    @Test func rejectWhenActiveAppliesToEachKey() throws {
        var local = Files.Local()
        try local.send(.upload(1))
        try local.send(.upload(2))
        #expect(throws: Files.SendRejection.self) { try local.send(.upload(1)) }
        do {
            try local.send(.upload(1))
        } catch {
            guard case .commit(.operationPolicy(.alreadyActive)) = error else { throw Unexpected() }
        }
        let works = commands(&local)
            .compactMap { command -> Files.UploadWork? in
                if case .upload(let work) = command { work } else { nil }
            }
        #expect(works.map(\.key) == [1, 2])
        guard case .committed = local.deliver(works[0].succeeded()) else { throw Unexpected() }
        // Once key 1's upload has finished, it can upload again.
        try local.send(.upload(1))
    }

    @Test func parallelLimitAppliesToEachKey() throws {
        var local = Files.Local()
        try local.send(.sync(1))
        try local.send(.sync(1))
        do {
            try local.send(.sync(1))
            Issue.record("A third sync of one key was admitted")
        } catch {
            guard case .commit(.operationPolicy(.parallelLimit)) = error else { throw Unexpected() }
        }
        try local.send(.sync(2))
        try local.send(.sync(2))
        let syncs = commands(&local)
            .compactMap { command -> Files.SyncWork? in
                if case .sync(let work) = command { work } else { nil }
            }
        #expect(syncs.map(\.key) == [1, 1, 2, 2])
    }

    @Test func twoExclusiveStartsForOneKeyInOneChangeAreAPlanDefect() throws {
        var local = Files.Local()
        do {
            try local.send(.downloadTwice(1))
            Issue.record("Two starts for one key were admitted")
        } catch {
            guard case .commit(.plan(.invalidPlan)) = error else { throw Unexpected() }
        }
        // Starts for different keys in one change are legal and keep their authored order.
        try local.send(.downloadPair(4))
        #expect(downloads(commands(&local)).map(\.key) == [4, 5])
    }

    @Test func theOwnerWideExecutionLimitCountsEveryKey() throws {
        var local = Files.Local(configuration: try .init(executions: 2))
        try local.send(.download(1))
        try local.send(.download(2))
        do {
            try local.send(.download(3))
            Issue.record("A third execution exceeded the owner-wide limit")
        } catch {
            guard case .commit(.capacityExceeded(.executionReservations)) = error else { throw Unexpected() }
        }
    }

    @Test func cancellingOneKeyRevokesOnlyItsWorkAndCancellingAllRevokesTheRest() throws {
        var local = Files.Local()
        try local.send(.download(1))
        try local.send(.download(2))
        try local.send(.download(3))
        let works = downloads(commands(&local))
        try local.send(.remove(2))
        #expect(cancellations(commands(&local)) == [works[1].execution])
        // A key without work cancels nothing, so the acceptance carries no command.
        try local.send(.remove(9))
        #expect(local.drainCommands().isEmpty)
        try local.send(.removeAll)
        #expect(cancellations(commands(&local)) == [works[0].execution, works[2].execution])
        for work in works {
            guard case .stale = local.deliver(work.succeeded("late")) else { throw Unexpected() }
        }
        #expect(contents(local).isEmpty)
    }

    @Test func reinsertingACancelledKeyMintsAFreshIdentity() throws {
        var local = Files.Local()
        try local.send(.download(1))
        let first = try #require(downloads(commands(&local)).first)
        try local.send(.remove(1))
        _ = commands(&local)
        try local.send(.download(1))
        let second = try #require(downloads(commands(&local)).first)
        #expect(second.key == first.key)
        // Cancelling key 1 now revokes only the reinserted work.
        try local.send(.remove(1))
        #expect(cancellations(commands(&local)) == [second.execution])
        guard case .stale = local.deliver(first.succeeded("first")) else { throw Unexpected() }
        guard case .stale = local.deliver(second.succeeded("second")) else { throw Unexpected() }
    }

    @Test func aChangeCanCancelAndRestartOneKey() throws {
        var local = Files.Local()
        try local.send(.upload(7))
        let first = commands(&local)
            .compactMap { command -> Files.UploadWork? in
                if case .upload(let work) = command { work } else { nil }
            }
        // `rejectWhenActive` admits the restart, because the change cancels the key's work first.
        try local.send(.reupload(7))
        let restart = commands(&local)
        #expect(cancellations(restart) == first.map(\.execution))
        let second = try #require(
            restart.compactMap { command -> Files.UploadWork? in
                if case .upload(let work) = command { work } else { nil }
            }
            .first
        )
        guard case .stale = local.deliver(first[0].succeeded()) else { throw Unexpected() }
        guard case .committed = local.deliver(second.succeeded()) else { throw Unexpected() }
    }

    @Test func theRequestReachesWorkCompletionPendingAndTheCompletionEdge() throws {
        var local = Files.Local(configuration: try .init(commits: 1))
        try local.send(.download(3))
        let work = try #require(downloads(commands(&local)).first)
        #expect(work.request.key == 3)
        #expect(work.request.input == "file-3")
        let completion = work.succeeded("bytes")
        #expect(completion.request.key == 3)
        #expect(completion.request.input == "file-3")
        // The completion starts a sync, so a full commit queue retains the outcome, with its request, for an
        // explicit retry.
        try local.send(.sync(3))
        guard case .pending(let id, .waitingForCapacity) = local.deliver(completion) else { throw Unexpected() }
        let pending = try #require(local.pendingCompletions().first)
        guard case .download("bytes", let request) = pending.outcome else { throw Unexpected() }
        #expect(request.key == 3)
        #expect(request.input == "file-3")
        _ = local.drainCommands()
        guard case .committed = local.retryAdmission(id: id) else { throw Unexpected() }
        #expect(contents(local) == [3: "bytes from file-3"])
    }

    @Test func aManagedOwnerPassesEachKeyAndInputToItsDriver() async throws {
        let (calls, call) = AsyncStream<(Int, String)>.makeStream()
        let owner = Files.Shared(
            downloadDriver: { key, input in
                call.yield((key, input))
                return "content-\(key)"
            },
            uploadDriver: { _ in },
            syncDriver: { _, _ in },
            // A download's completion starts a sync, which admission can refuse, so the policy is explicit.
            completionPolicy: .retry
        )
        let snapshots = try owner.snapshots()
        try owner.send(.download(5))
        var iterator = calls.makeAsyncIterator()
        let first = try #require(await iterator.next())
        #expect(first.0 == 5)
        #expect(first.1 == "file-5")
        for await snapshot in snapshots {
            guard case .browsing(let browsing) = snapshot, !browsing.value.contents.isEmpty else { continue }
            #expect(browsing.value.contents == [5: "content-5 from file-5"])
            break
        }
        #expect(await owner.shutdown() == .quiescent)
        call.finish()
    }

    @Test func theGraphDescribesKeysAndCancellations() throws {
        let graph = Files.graph
        let download = try #require(graph.operations.first { $0.id == "Download" })
        #expect(download.key == "Int")
        #expect(download.isKeyed)
        let remove = try #require(graph.edges.first { $0.id == "browsing.remove" })
        #expect(remove.cancels == ["Download"])
        #expect(remove.starts.isEmpty)
        let reupload = try #require(graph.edges.first { $0.id == "browsing.reupload" })
        #expect(reupload.starts == ["Upload"])
        #expect(reupload.cancels == ["Upload"])
    }
}
