import StateMachine
import Testing

/// A one-shot event a test awaits instead of inferring progress from scheduling.
private struct Signal: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
    func raise() { continuation.yield(()) }
    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

/// An isolated-mode notebook whose payloads are not `Sendable`, so they never leave their owner's actor.
@StateMachine(mode: .isolated)
nonisolated private enum Notebook {
    struct Editing: ~Sendable {
        var text = ""
        var saves = 0
    }
    struct Saving: ~Sendable {
        let text: String
        let saves: Int
    }
    @Initial case editing(Editing = Editing())
    case saving(Saving)
    enum Input {
        case edit(String)
        case save
    }
    @Event
    enum Edited { typealias Payload = String }
    @Operation(activeIn: [Saving.self])
    enum Save {
        typealias Input = String
        typealias Output = Int
    }
    @Transition(on: Input.edit, emits: [Edited.self])
    fileprivate static func edit(_ source: Editing, _ text: String) -> Change<Editing, Effect.Edit> {
        Change(Editing(text: text, saves: source.saves), effects: [.edited(text)])
    }
    @Transition(on: Input.save, starts: [Save.self])
    fileprivate static func save(_ source: Editing) -> Change<Saving, Effect.Save> {
        Change(Saving(text: source.text, saves: source.saves), effects: [.save(source.text)])
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Saving, _ count: Save.Output) -> Editing {
        Editing(text: source.text, saves: count)
    }
}

/// The actor that owns its notebook. Drivers, event handlers, and callbacks run here and change its state.
private actor Editor {
    private(set) var host: Notebook.IsolatedHost<Editor>!
    private(set) var events: [String] = []
    private(set) var saved: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var releasedEarly = false
    let started = Signal()

    init() async {
        host = Notebook.IsolatedHost(
            isolation: self,
            saveDriver: { editor, text in await editor.save(text) },
            onEdited: { editor, text in editor.events.append(text) }
        )
    }

    // The driver receives this actor isolated, so it appends without awaiting, and stays held until released.
    private func save(_ text: String) async -> Int {
        if #available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) { preconditionIsolated() }
        saved.append(text)
        started.raise()
        if !releasedEarly { await withCheckedContinuation { held.append($0) } }
        return saved.count
    }

    func release() {
        releasedEarly = true
        let prior = held
        held = []
        for continuation in prior { continuation.resume() }
    }

    var text: String {
        guard case .editing(let editing) = host.snapshot() else { return "" }
        return editing.value.text
    }

    var phase: String {
        switch host.snapshot() {
        case .editing(let editing): "editing \(editing.value.text) \(editing.value.saves)"
        case .saving(let saving): "saving \(saving.value.text)"
        }
    }

    func edit(_ texts: [String]) async throws -> [String] {
        var last: Notebook.Receipt?
        for text in texts { last = try host.send(.edit(text)) }
        if let last { #expect(await host.flush(through: last) == .processed) }
        return events
    }

    /// Starts a save and returns its revision once its driver runs on this actor.
    @discardableResult func beginSave() async throws -> UInt64 {
        let receipt = try host.send(.save)
        await started.wait()
        return receipt.revision
    }

    /// Releases the held save and returns the phase its completion commits.
    func completeSave() async throws -> String {
        var snapshots = try host.snapshots()
        release()
        while let snapshot = await snapshots.next() {
            if case .editing(let editing) = snapshot { return "editing \(editing.value.text) \(editing.value.saves)" }
        }
        return "ended"
    }

    func reset() throws -> UInt64 { try host.reset().revision }

    func pendingCount() -> Int { host.pendingCompletions().count }

    func runningCount() -> Int { host.runningCount() }

    func shutdown(deadline: ContinuousClock.Instant? = nil) async -> Notebook.ShutdownResult {
        await host.shutdown(deadline: deadline)
    }
}

@Suite struct IsolatedHostTests {
    @Test func eventHandlersRunOnTheOwningActorInCommitOrder() async throws {
        let editor = await Editor()
        #expect(try await editor.edit(["a", "b", "c"]) == ["a", "b", "c"])
        #expect(await editor.text == "c")
        #expect(await editor.shutdown() == .quiescent)
    }

    @Test func driversRunOnTheOwningActorAndTheirCompletionsCommit() async throws {
        let editor = await Editor()
        _ = try await editor.edit(["draft"])
        try await editor.beginSave()
        #expect(await editor.saved == ["draft"])
        #expect(await editor.runningCount() == 1)
        #expect(await editor.phase == "saving draft")
        #expect(try await editor.completeSave() == "editing draft 1")
        #expect(await editor.shutdown() == .quiescent)
        #expect(await editor.runningCount() == 0)
    }

    @Test func resetRevokesHeldWorkAndKeepsTheOwner() async throws {
        let editor = await Editor()
        _ = try await editor.edit(["draft"])
        let started = try await editor.beginSave()
        let revision = try await editor.reset()
        #expect(revision > started)
        #expect(await editor.phase == "editing  0")
        #expect(await editor.pendingCount() == 0)
        // The revoked driver keeps its reservation until it terminates; its late result is stale.
        #expect(await editor.runningCount() == 1)
        await editor.release()
        #expect(await editor.shutdown() == .quiescent)
        #expect(await editor.phase == "editing  0")
    }

    @Test func shutdownReportsHeldWorkAtItsDeadlineAndJoinsItAfterward() async throws {
        let editor = await Editor()
        try await editor.beginSave()
        guard case .timedOut(let diagnostics) = await editor.shutdown(deadline: .now) else {
            Issue.record("A held driver must keep shutdown from settling by its deadline.")
            return
        }
        #expect(diagnostics.outstandingExecutions.count == 1)
        await editor.release()
        #expect(await editor.shutdown() == .quiescent)
        #expect(await editor.runningCount() == 0)
    }
}
