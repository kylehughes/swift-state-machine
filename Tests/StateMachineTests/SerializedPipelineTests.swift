import StateMachine
import StateMachineExamples
import StateMachineTestSupport
import Testing
import os

// Deterministic, sleep-free tests for the serialized latest-pending Local pattern:
// 1. Blocked off-main-actor render A, select B then C (weak Item release, skippedBeforeStart once,
//    exact exit -> terminated -> stale -> C.detect order, maximumActiveCount == 1).
// 2. Clear while A is blocked suppresses C and releases C's Item immediately.
// 3. Pre-start Task.isCancelled vs physically running termination, close() -> quiescence,
//    live drivers, and deinit without retain cycles.
// 4. Deterministic synchronous reentrancy regressions on the production SerializedPipelineSession
//    from onAcknowledge (cancelling pending B during select(C)), onDeliver (committed delivery
//    chaining into Render), onEvent (event emitted before operation start), and nested onChange.
// 5. Out-of-band receipt + named Scope invalidation exercising the exact same SerialExecutionLane.

/// A one-shot signal awaited deterministically instead of sleeping or polling.
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

/// Thread-safe event log and concurrent-activity tracker.
private final class Trace: Sendable {
    private struct State: Sendable {
        var events: [String] = []
        var activeCount = 0
        var maximumActiveCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var events: [String] { state.withLock(\.events) }
    var maximumActiveCount: Int { state.withLock(\.maximumActiveCount) }

    func record(_ event: String) {
        state.withLock { $0.events.append(event) }
    }

    func enterDriver(_ name: String) {
        state.withLock { state in
            state.activeCount += 1
            if state.activeCount > state.maximumActiveCount {
                state.maximumActiveCount = state.activeCount
            }
            state.events.append("\(name).start")
        }
    }

    func leaveDriver(_ name: String) {
        state.withLock { state in
            state.activeCount -= 1
            state.events.append("\(name).exit")
        }
    }
}

/// Weak wrapper returned across helper scope boundaries so debug ARC locals cannot keep the Item alive.
private final class WeakItem {
    weak var value: SerializedPipeline.Item?
    init(_ value: SerializedPipeline.Item) { self.value = value }
}

@MainActor private func selectWithWeakRef(
    on session: SerializedPipelineSession,
    id: String
) throws -> WeakItem {
    let item = SerializedPipeline.Item(id: id)
    let weakItem = WeakItem(item)
    try session.select(item)
    return weakItem
}

private func stageLabel(_ stage: SerializedPipelineSession.Stage) -> String {
    switch stage {
    case .detect(let itemID): "\(itemID).detect"
    case .render(let itemID): "\(itemID).render"
    }
}

private func dispositionLabel(_ disposition: ExecutionDisposition) -> String {
    switch disposition {
    case .terminated: "terminated"
    case .skippedBeforeStart: "skippedBeforeStart"
    }
}

private func ackLabel(_ result: AcknowledgmentResult) -> String {
    switch result {
    case .recorded: "recorded"
    case .duplicate: "duplicate"
    case .foreignOwner: "foreignOwner"
    }
}

private func completionLabel(_ completion: SerializedPipeline.Completion) -> String {
    switch completion {
    case .detect(let completed): "\(completed.request.input.id).detect"
    case .render(let completed): "\(completed.request.input.itemID).render"
    }
}

private func deliveryLabel(_ result: SerializedPipeline.DeliveryResult) -> String {
    switch result {
    case .committed: "committed"
    case .pending: "pending"
    case .refused: "refused"
    case .stale: "stale"
    case .foreignOwner: "foreignOwner"
    }
}

private func milestoneLabel(_ milestone: SerializedPipeline.Milestone) -> String {
    switch milestone {
    case .selected(let itemID): "selected:\(itemID)"
    case .detected(let itemID, _): "detected:\(itemID)"
    case .rendered(let itemID): "rendered:\(itemID)"
    case .cleared: "cleared"
    }
}

private func snapshotLabel(_ snapshot: SerializedPipeline.Snapshot) -> String {
    switch snapshot.model {
    case .idle: "idle"
    case .detecting(let state): "detecting(\(state.itemID))"
    case .rendering(let state): "rendering(\(state.itemID))"
    case .ready(let state): "ready(\(state.itemID))"
    }
}

// MARK: - Core SerializedPipelineSession Tests

@MainActor @Suite(.timeLimit(.minutes(1))) struct SerializedPipelineTests {
    @Test func blockedRenderASelectBThenCSkipsBAndStartsCAfterAPhysicalExit() async throws {
        let trace = Trace()
        let renderAEntered = Signal()
        let renderAGate = ThreadGate()
        defer { renderAGate.open() }

        let session = SerializedPipelineSession(
            drivers: .init(
                detect: { item in
                    trace.enterDriver("\(item.id).detect")
                    defer { trace.leaveDriver("\(item.id).detect") }
                    return ["r-\(item.id)"]
                },
                render: { request in
                    if request.itemID == "A" {
                        return await withCheckedContinuation { continuation in
                            runOnOwnThread {
                                trace.enterDriver("A.render")
                                renderAEntered.raise()
                                renderAGate.wait()
                                trace.leaveDriver("A.render")
                                continuation.resume(returning: "img-A")
                            }
                        }
                    }
                    return await withCheckedContinuation { continuation in
                        runOnOwnThread {
                            trace.enterDriver("\(request.itemID).render")
                            trace.leaveDriver("\(request.itemID).render")
                            continuation.resume(returning: "img-\(request.itemID)")
                        }
                    }
                }
            )
        )

        var ackRecords:
            [(
                stage: SerializedPipelineSession.Stage, handle: SerializedPipeline.ExecutionHandle,
                disposition: ExecutionDisposition, result: AcknowledgmentResult
            )] = []
        session.onAcknowledge = { stage, handle, disposition, result in
            ackRecords.append((stage, handle, disposition, result))
            trace.record("ack:\(stageLabel(stage)):\(dispositionLabel(disposition)):\(ackLabel(result))")
        }
        session.onDeliver = { completion, result in
            trace.record("deliver:\(completionLabel(completion)):\(deliveryLabel(result))")
        }

        try session.select(.init(id: "A"))
        await renderAEntered.wait()

        // Select B with a weak Item reference isolated from test locals, retained batches, and Local's snapshot.
        let itemB = try selectWithWeakRef(on: session, id: "B")
        #expect(itemB.value != nil)
        #expect(session.hasRunningWork)
        #expect(session.hasPendingWork)

        // Select C while A is still blocked in Render on its own thread.
        try session.select(.init(id: "C"))

        // Snapshot immediately reflects C, B never starts, B's Item is released, and B acknowledged skippedBeforeStart once.
        guard case .detecting(let detecting) = session.snapshot().model else {
            Issue.record("Expected detecting(C), got \(session.snapshot().model)")
            return
        }
        #expect(detecting == .init(itemID: "C"))
        #expect(itemB.value == nil)
        #expect(!trace.events.contains("B.detect.start"))

        let bAcks = ackRecords.filter { $0.stage == .detect(itemID: "B") }
        #expect(bAcks.count == 1)
        #expect(bAcks.first?.disposition == .skippedBeforeStart)
        #expect(bAcks.first?.result == .recorded)

        // Release A's blocked off-main-actor render and wait for C to finish.
        renderAGate.open()
        await session.awaitIdle()

        guard case .ready(let ready) = session.snapshot().model else {
            Issue.record("Expected ready(C), got \(session.snapshot().model)")
            return
        }
        #expect(ready == .init(itemID: "C", output: "img-C"))
        #expect(trace.maximumActiveCount == 1)
        #expect(!trace.events.contains("B.detect.start"))

        let aRenderAcks = ackRecords.filter { $0.stage == .render(itemID: "A") }
        #expect(aRenderAcks.count == 1)
        #expect(aRenderAcks.first?.disposition == .terminated)
        #expect(aRenderAcks.first?.result == .recorded)

        // Every distinct handle was acknowledged with `.recorded` exactly once.
        #expect(ackRecords.allSatisfy { $0.result == .recorded })
        #expect(ackRecords.count == 5)
        for index in ackRecords.indices {
            let duplicateCount = ackRecords.filter { $0.handle == ackRecords[index].handle }.count
            #expect(duplicateCount == 1)
        }

        // Verify the exact ordered transition log across A's physical exit and C's start/completion.
        #expect(
            trace.events == [
                "A.detect.start",
                "A.detect.exit",
                "ack:A.detect:terminated:recorded",
                "deliver:A.detect:committed",
                "A.render.start",
                "ack:B.detect:skippedBeforeStart:recorded",
                "A.render.exit",
                "ack:A.render:terminated:recorded",
                "deliver:A.render:stale",
                "C.detect.start",
                "C.detect.exit",
                "ack:C.detect:terminated:recorded",
                "deliver:C.detect:committed",
                "C.render.start",
                "C.render.exit",
                "ack:C.render:terminated:recorded",
                "deliver:C.render:committed",
            ]
        )
    }

    @Test func clearWhileAIsRunningSuppressesCAndReleasesItemImmediately() async throws {
        let trace = Trace()
        let renderAEntered = Signal()
        let renderAGate = ThreadGate()
        defer { renderAGate.open() }

        let session = SerializedPipelineSession(
            drivers: .init(
                detect: { item in
                    trace.enterDriver("\(item.id).detect")
                    defer { trace.leaveDriver("\(item.id).detect") }
                    return ["r-\(item.id)"]
                },
                render: { request in
                    await withCheckedContinuation { continuation in
                        runOnOwnThread {
                            trace.enterDriver("\(request.itemID).render")
                            if request.itemID == "A" {
                                renderAEntered.raise()
                                renderAGate.wait()
                            }
                            trace.leaveDriver("\(request.itemID).render")
                            continuation.resume(returning: "img-\(request.itemID)")
                        }
                    }
                }
            )
        )

        var ackRecords:
            [(stage: SerializedPipelineSession.Stage, disposition: ExecutionDisposition, result: AcknowledgmentResult)] =
                []
        session.onAcknowledge = { stage, _, disposition, result in
            ackRecords.append((stage, disposition, result))
            trace.record("ack:\(stageLabel(stage)):\(dispositionLabel(disposition)):\(ackLabel(result))")
        }
        session.onDeliver = { completion, result in
            trace.record("deliver:\(completionLabel(completion)):\(deliveryLabel(result))")
        }

        try session.select(.init(id: "A"))
        await renderAEntered.wait()

        let itemC = try selectWithWeakRef(on: session, id: "C")
        #expect(itemC.value != nil)
        #expect(session.hasPendingWork)

        // Clear while A is still blocked.
        try session.clear()

        guard case .idle = session.snapshot().model else {
            Issue.record("Expected idle, got \(session.snapshot().model)")
            return
        }
        #expect(!session.hasPendingWork)
        #expect(session.hasRunningWork)
        #expect(itemC.value == nil)

        let cAcks = ackRecords.filter { $0.stage == .detect(itemID: "C") }
        #expect(cAcks.count == 1)
        #expect(cAcks.first?.disposition == .skippedBeforeStart)
        #expect(cAcks.first?.result == .recorded)

        renderAGate.open()
        await session.awaitIdle()

        guard case .idle = session.snapshot().model else {
            Issue.record("Expected settled idle, got \(session.snapshot().model)")
            return
        }
        #expect(!session.hasRunningWork)
        #expect(!session.hasPendingWork)
        #expect(!trace.events.contains("C.detect.start"))
        #expect(!trace.events.contains("C.render.start"))
        #expect(trace.maximumActiveCount == 1)
        #expect(
            trace.events == [
                "A.detect.start",
                "A.detect.exit",
                "ack:A.detect:terminated:recorded",
                "deliver:A.detect:committed",
                "A.render.start",
                "ack:C.detect:skippedBeforeStart:recorded",
                "A.render.exit",
                "ack:A.render:terminated:recorded",
                "deliver:A.render:stale",
            ]
        )
    }

    @Test func preStartCancellationAcknowledgesSkippedBeforeStartWithoutCallingDriver() async throws {
        let trace = Trace()
        let session = SerializedPipelineSession(
            drivers: .init(
                detect: { item in
                    trace.enterDriver("\(item.id).detect")
                    defer { trace.leaveDriver("\(item.id).detect") }
                    return ["r-\(item.id)"]
                },
                render: { request in
                    trace.enterDriver("\(request.itemID).render")
                    defer { trace.leaveDriver("\(request.itemID).render") }
                    return "img-\(request.itemID)"
                }
            )
        )

        var ackRecords:
            [(stage: SerializedPipelineSession.Stage, disposition: ExecutionDisposition, result: AcknowledgmentResult)] =
                []
        session.onAcknowledge = { stage, _, disposition, result in
            ackRecords.append((stage, disposition, result))
            trace.record("ack:\(stageLabel(stage)):\(dispositionLabel(disposition)):\(ackLabel(result))")
        }

        // Select A and immediately replace with B in the same @MainActor turn before A's Task starts.
        try session.select(.init(id: "A"))
        try session.select(.init(id: "B"))

        await session.awaitIdle()

        guard case .ready(let ready) = session.snapshot().model else {
            Issue.record("Expected ready(B), got \(session.snapshot().model)")
            return
        }
        #expect(ready == .init(itemID: "B", output: "img-B"))
        #expect(!trace.events.contains("A.detect.start"))
        #expect(trace.maximumActiveCount == 1)

        let aAcks = ackRecords.filter { $0.stage == .detect(itemID: "A") }
        #expect(aAcks.count == 1)
        #expect(aAcks.first?.disposition == .skippedBeforeStart)
        #expect(aAcks.first?.result == .recorded)

        let bDetectAcks = ackRecords.filter { $0.stage == .detect(itemID: "B") }
        #expect(bDetectAcks.count == 1)
        #expect(bDetectAcks.first?.disposition == .terminated)
        #expect(bDetectAcks.first?.result == .recorded)
    }

    @Test func closeWaitsForPhysicalExitBeforeQuiescenceAndRejectsFurtherSends() async throws {
        let trace = Trace()
        let renderAEntered = Signal()
        let renderAGate = ThreadGate()
        defer { renderAGate.open() }

        let session = SerializedPipelineSession(
            drivers: .init(
                detect: { item in
                    trace.enterDriver("\(item.id).detect")
                    defer { trace.leaveDriver("\(item.id).detect") }
                    return ["r-\(item.id)"]
                },
                render: { request in
                    await withCheckedContinuation { continuation in
                        runOnOwnThread {
                            trace.enterDriver("\(request.itemID).render")
                            if request.itemID == "A" {
                                renderAEntered.raise()
                                renderAGate.wait()
                            }
                            trace.leaveDriver("\(request.itemID).render")
                            continuation.resume(returning: "img-\(request.itemID)")
                        }
                    }
                }
            )
        )

        var ackRecords:
            [(stage: SerializedPipelineSession.Stage, disposition: ExecutionDisposition, result: AcknowledgmentResult)] =
                []
        session.onAcknowledge = { stage, _, disposition, result in
            ackRecords.append((stage, disposition, result))
        }

        try session.select(.init(id: "A"))
        await renderAEntered.wait()

        let itemC = try selectWithWeakRef(on: session, id: "C")
        #expect(itemC.value != nil)

        let closeReceipt = session.close()
        #expect(closeReceipt.snapshot.isClosed)
        #expect(session.snapshot().isClosed)
        #expect(!session.hasPendingWork)
        #expect(itemC.value == nil)
        #expect(!session.isQuiescent)

        let cAcks = ackRecords.filter { $0.stage == .detect(itemID: "C") }
        #expect(cAcks.count == 1)
        #expect(cAcks.first?.disposition == .skippedBeforeStart)
        #expect(cAcks.first?.result == .recorded)

        do {
            try session.select(.init(id: "D"))
            Issue.record("Expected closed rejection after close()")
        } catch {
            // Closed owner rejects further sends.
        }

        renderAGate.open()
        await session.awaitIdle()

        #expect(session.isQuiescent)
        #expect(!trace.events.contains("C.detect.start"))
        let aRenderAcks = ackRecords.filter { $0.stage == .render(itemID: "A") }
        #expect(aRenderAcks.count == 1)
        #expect(aRenderAcks.first?.disposition == .terminated)
        #expect(aRenderAcks.first?.result == .recorded)
    }

    @Test func liveDriversCompleteOffMainActorPipelineToReady() async throws {
        let session = SerializedPipelineSession(drivers: .live)
        try session.select(.init(id: "live"))
        await session.awaitIdle()

        guard case .ready(let ready) = session.snapshot().model else {
            Issue.record("Expected ready(live), got \(session.snapshot().model)")
            return
        }
        #expect(ready == .init(itemID: "live", output: "live:region-live"))
        #expect(!session.hasRunningWork)
        #expect(!session.hasPendingWork)
    }

    @Test func deinitCancelsRunningTaskWithoutRetainCyclesWhileRenderIsBlocked() async throws {
        let renderEntered = Signal()
        let taskCancelled = Signal()
        let workerExited = Signal()
        let renderGate = ThreadGate()
        defer { renderGate.open() }

        let weakSession = try await startBlockedSessionForDeinitTest(
            renderEntered: renderEntered,
            taskCancelled: taskCancelled,
            workerExited: workerExited,
            renderGate: renderGate
        )

        // Session deallocates immediately while A's worker thread is still blocked, cancelling running.task.
        #expect(weakSession.value == nil)
        await taskCancelled.wait()

        renderGate.open()
        await workerExited.wait()
    }

    @Test func reentrantSendFromOnAcknowledgeDuringPendingCancelPreservesFIFOAndNeverTraps() async throws {
        let trace = Trace()
        let renderAEntered = Signal()
        let renderAGate = ThreadGate()
        defer { renderAGate.open() }

        let session = SerializedPipelineSession(
            drivers: .init(
                detect: { item in
                    trace.enterDriver("\(item.id).detect")
                    defer { trace.leaveDriver("\(item.id).detect") }
                    return ["r-\(item.id)"]
                },
                render: { request in
                    await withCheckedContinuation { continuation in
                        runOnOwnThread {
                            trace.enterDriver("\(request.itemID).render")
                            if request.itemID == "A" {
                                renderAEntered.raise()
                                renderAGate.wait()
                            }
                            trace.leaveDriver("\(request.itemID).render")
                            continuation.resume(returning: "img-\(request.itemID)")
                        }
                    }
                }
            )
        )

        var outwardLog: [String] = []
        var weakD: WeakItem?
        var didReenterOnBAck = false

        session.onAcknowledge = { [weak session] stage, _, disposition, result in
            outwardLog.append("ack:\(stageLabel(stage)):\(dispositionLabel(disposition)):\(ackLabel(result))")
            // Regression: cancelling pending B during select(C) must finish installing C's start
            // before invoking outward hooks, so a synchronous select(D) here replaces C cleanly
            // without reordering commands or trapping at pending != nil.
            if stage == .detect(itemID: "B"), disposition == .skippedBeforeStart, !didReenterOnBAck {
                didReenterOnBAck = true
                if let session {
                    weakD = try? selectWithWeakRef(on: session, id: "D")
                }
            }
        }
        session.onDeliver = { completion, result in
            outwardLog.append("deliver:\(completionLabel(completion)):\(deliveryLabel(result))")
        }
        session.onEvent = { milestone in
            outwardLog.append("event:\(milestoneLabel(milestone))")
        }
        session.onChange = { snapshot in
            outwardLog.append("change:\(snapshotLabel(snapshot))")
        }

        try session.select(.init(id: "A"))
        await renderAEntered.wait()

        let weakB = try selectWithWeakRef(on: session, id: "B")
        #expect(weakB.value != nil)

        // Selecting C cancels pending B; B's queued onAcknowledge reenters select(D) after C is installed.
        let weakC = try selectWithWeakRef(on: session, id: "C")

        #expect(didReenterOnBAck)
        #expect(weakB.value == nil)
        #expect(weakC.value == nil)
        #expect(weakD?.value != nil)
        guard case .detecting(let detecting) = session.snapshot().model else {
            Issue.record("Expected detecting(D), got \(session.snapshot().model)")
            return
        }
        #expect(detecting == .init(itemID: "D"))

        renderAGate.open()
        await session.awaitIdle()

        guard case .ready(let ready) = session.snapshot().model else {
            Issue.record("Expected ready(D), got \(session.snapshot().model)")
            return
        }
        #expect(ready == .init(itemID: "D", output: "img-D"))
        #expect(trace.maximumActiveCount == 1)
        #expect(!trace.events.contains("B.detect.start"))
        #expect(!trace.events.contains("C.detect.start"))
        #expect(
            outwardLog == [
                "event:selected:A",
                "change:detecting(A)",
                "ack:A.detect:terminated:recorded",
                "deliver:A.detect:committed",
                "event:detected:A",
                "change:rendering(A)",
                "event:selected:B",
                "change:detecting(B)",
                "ack:B.detect:skippedBeforeStart:recorded",
                "event:selected:C",
                "change:detecting(C)",
                "ack:C.detect:skippedBeforeStart:recorded",
                "event:selected:D",
                "change:detecting(D)",
                "ack:A.render:terminated:recorded",
                "deliver:A.render:stale",
                "ack:D.detect:terminated:recorded",
                "deliver:D.detect:committed",
                "event:detected:D",
                "change:rendering(D)",
                "ack:D.render:terminated:recorded",
                "deliver:D.render:committed",
                "event:rendered:D",
                "change:ready(D)",
            ]
        )
    }

    @Test func reentrantCallbacksFromEventBeforeStartOnDeliverAndOnChangePreserveFIFOAndNeverDoubleStart()
        async throws
    {
        let trace = Trace()
        let session = SerializedPipelineSession(
            drivers: .init(
                detect: { item in
                    trace.enterDriver("\(item.id).detect")
                    defer { trace.leaveDriver("\(item.id).detect") }
                    return ["r-\(item.id)"]
                },
                render: { request in
                    await withCheckedContinuation { continuation in
                        runOnOwnThread {
                            trace.enterDriver("\(request.itemID).render")
                            trace.leaveDriver("\(request.itemID).render")
                            continuation.resume(returning: "img-\(request.itemID)")
                        }
                    }
                }
            )
        )

        var outwardLog: [String] = []
        var didReenterOnSelectA = false
        var didReenterOnDeliverBDetect = false
        var didReenterOnChangeC = false

        session.onAcknowledge = { stage, _, disposition, result in
            outwardLog.append("ack:\(stageLabel(stage)):\(dispositionLabel(disposition)):\(ackLabel(result))")
        }

        session.onDeliver = { [weak session] completion, result in
            outwardLog.append("deliver:\(completionLabel(completion)):\(deliveryLabel(result))")
            // Regression: committed delivery of B.detect must drain and install B.render and enqueue
            // Rendering(B) BEFORE onDeliver fires, so reentering select(C) here cancels B.render
            // cleanly and keeps Rendering(B) ahead of Detecting(C) in FIFO order.
            if completionLabel(completion) == "B.detect", case .committed = result, !didReenterOnDeliverBDetect {
                didReenterOnDeliverBDetect = true
                _ = try? session?.select(.init(id: "C"))
            }
        }

        session.onEvent = { [weak session] milestone in
            outwardLog.append("event:\(milestoneLabel(milestone))")
            // select(A) emits .selected("A") BEFORE .detect(A) in the same CommandBatch.
            // Because internal starts are installed before outward callbacks pump, reentering here
            // cancels A's already-installed task and queues B cleanly.
            if milestone == .selected(itemID: "A"), !didReenterOnSelectA {
                didReenterOnSelectA = true
                _ = try? session?.select(.init(id: "B"))
            }
        }

        session.onChange = { [weak session] snapshot in
            outwardLog.append("change:\(snapshotLabel(snapshot))")
            // Nested reentrant send from onChange replaces pending C with D behind cancelled B.render.
            if case .detecting(let state) = snapshot.model, state.itemID == "C", !didReenterOnChangeC {
                didReenterOnChangeC = true
                _ = try? session?.select(.init(id: "D"))
            }
        }

        try session.select(.init(id: "A"))
        await session.awaitIdle()

        guard case .ready(let ready) = session.snapshot().model else {
            Issue.record("Expected ready(D), got \(session.snapshot().model)")
            return
        }
        #expect(ready == .init(itemID: "D", output: "img-D"))
        #expect(trace.maximumActiveCount == 1)

        // A.detect, B.render, and C.detect were all skipped before start without invoking their drivers.
        #expect(!trace.events.contains("A.detect.start"))
        #expect(!trace.events.contains("B.render.start"))
        #expect(!trace.events.contains("C.detect.start"))
        #expect(
            outwardLog == [
                "event:selected:A",
                "change:detecting(A)",
                "event:selected:B",
                "change:detecting(B)",
                "ack:A.detect:skippedBeforeStart:recorded",
                "ack:B.detect:terminated:recorded",
                "deliver:B.detect:committed",
                "event:detected:B",
                "change:rendering(B)",
                "event:selected:C",
                "change:detecting(C)",
                "ack:C.detect:skippedBeforeStart:recorded",
                "event:selected:D",
                "change:detecting(D)",
                "ack:B.render:skippedBeforeStart:recorded",
                "ack:D.detect:terminated:recorded",
                "deliver:D.detect:committed",
                "event:detected:D",
                "change:rendering(D)",
                "ack:D.render:terminated:recorded",
                "deliver:D.render:committed",
                "event:rendered:D",
                "change:ready(D)",
            ]
        )
    }

    @Test func reentrantClearFromOnDeliverPreservesDetectingRenderingIdleOrder() async throws {
        let trace = Trace()
        let session = SerializedPipelineSession(
            drivers: .init(
                detect: { item in
                    trace.enterDriver("\(item.id).detect")
                    defer { trace.leaveDriver("\(item.id).detect") }
                    return ["r-\(item.id)"]
                },
                render: { request in
                    trace.enterDriver("\(request.itemID).render")
                    defer { trace.leaveDriver("\(request.itemID).render") }
                    return "img-\(request.itemID)"
                }
            )
        )

        var seenPhases: [String] = []
        var ackLog: [String] = []
        var cleared = false

        session.onChange = { snapshot in
            seenPhases.append(snapshotLabel(snapshot))
        }
        session.onAcknowledge = { stage, _, disposition, result in
            ackLog.append("\(stageLabel(stage)):\(dispositionLabel(disposition)):\(ackLabel(result))")
        }
        session.onDeliver = { [weak session] _, result in
            // Regression for reproduced callback-probe bug: calling clear() from onDeliver after
            // Detect commits must preserve FIFO observer order (detecting -> rendering -> idle)
            // while cancelling A.render before it invokes its driver.
            if !cleared, case .committed = result {
                cleared = true
                _ = try? session?.clear()
            }
        }

        try session.select(.init(id: "A"))
        await session.awaitIdle()

        guard case .idle = session.snapshot().model else {
            Issue.record("Expected final idle phase, got \(session.snapshot().model)")
            return
        }
        #expect(seenPhases == ["detecting(A)", "rendering(A)", "idle"])
        #expect(!trace.events.contains("A.render.start"))
        #expect(
            ackLog == [
                "A.detect:terminated:recorded",
                "A.render:skippedBeforeStart:recorded",
            ]
        )
    }
}

private final class WeakSession {
    weak var value: SerializedPipelineSession?
    init(_ value: SerializedPipelineSession) { self.value = value }
}

@MainActor private func startBlockedSessionForDeinitTest(
    renderEntered: Signal,
    taskCancelled: Signal,
    workerExited: Signal,
    renderGate: ThreadGate
) async throws -> WeakSession {
    let session = SerializedPipelineSession(
        drivers: .init(
            detect: { _ in ["r-A"] },
            render: { _ in
                await withTaskCancellationHandler {
                    await withCheckedContinuation { continuation in
                        runOnOwnThread {
                            renderEntered.raise()
                            renderGate.wait()
                            workerExited.raise()
                            continuation.resume(returning: "img-A")
                        }
                    }
                } onCancel: {
                    taskCancelled.raise()
                }
            }
        )
    )
    let weakSession = WeakSession(session)
    try session.select(.init(id: "A"))
    await renderEntered.wait()
    return weakSession
}

// MARK: - Boundary Test: Out-of-Band Operation + Named Scope Invalidation on SerialExecutionLane

/// Test-only schema pairing an out-of-band receipt operation with a lane-serialized render operation
/// under separate named scopes, driven through the exact same `SerialExecutionLane` used by
/// `SerializedPipelineSession`.
@StateMachine(mode: .isolated, owners: [.local])
private enum OutOfBandScopeGraph {
    struct Active: Equatable {
        let receiptResult: String?
        let rendered: String?
        init(receiptResult: String? = nil, rendered: String? = nil) {
            self.receiptResult = receiptResult
            self.rendered = rendered
        }
    }

    @Initial case active(Active = Active())

    enum Scope {
        case receipt
        case lane
    }

    enum Input {
        case startReceipt(String)
        case startLane(String)
        case invalidateLane
        case invalidateReceipt
    }

    @Operation(scope: Scope.receipt)
    enum Receive {
        typealias Input = String
        typealias Output = String
    }

    @Operation(scope: Scope.lane)
    enum Render {
        typealias Input = String
        typealias Output = String
    }

    @Transition(on: Input.startReceipt, starts: [Receive.self])
    fileprivate static func startReceipt(_ source: Active, _ id: String) -> Change<Active, Effect.StartReceipt> {
        Change(source, effects: [.receive(id)])
    }

    @Transition(on: Input.startLane, starts: [Render.self])
    fileprivate static func startLane(_ source: Active, _ id: String) -> Change<Active, Effect.StartLane> {
        Change(source, effects: [.render(id)])
    }

    @Transition(on: Input.invalidateLane, invalidates: [Scope.lane])
    fileprivate static func invalidateLane(_ source: Active) -> Active { source }

    @Transition(on: Input.invalidateReceipt, invalidates: [Scope.receipt])
    fileprivate static func invalidateReceipt(_ source: Active) -> Active { source }

    @Transition(onSuccess: Receive.self)
    fileprivate static func received(_ source: Active, _ value: Receive.Output) -> Active {
        Active(receiptResult: value, rendered: source.rendered)
    }

    @Transition(onSuccess: Render.self)
    fileprivate static func rendered(_ source: Active, _ value: Render.Output) -> Active {
        Active(receiptResult: source.receiptResult, rendered: value)
    }
}

/// Thin adapter driving `OutOfBandScopeGraph.Local` with the production `SerialExecutionLane`.
@MainActor private final class OutOfBandScopeHost {
    private var machine = OutOfBandScopeGraph.Local()
    private let lane = SerialExecutionLane<OutOfBandScopeGraph.ExecutionHandle, OutOfBandScopeGraph.Completion>()
    private let renderDriver: @MainActor (String) async -> String
    private var receipt: OutOfBandScopeGraph.ReceiveWork?

    var receiptAcknowledgements: [(ExecutionDisposition, AcknowledgmentResult)] = []
    var laneAcknowledgements: [(ExecutionDisposition, AcknowledgmentResult)] = []
    var laneDeliveries: [OutOfBandScopeGraph.DeliveryResult] = []
    var receiptDeliveries: [OutOfBandScopeGraph.DeliveryResult] = []

    init(renderDriver: @escaping @MainActor (String) async -> String) {
        self.renderDriver = renderDriver
    }

    var hasLiveReceipt: Bool { receipt != nil }
    var hasRunningLane: Bool { lane.hasRunningWork }
    var hasPendingLane: Bool { lane.hasPendingWork }
    func snapshot() -> OutOfBandScopeGraph.Snapshot { machine.snapshot() }
    func awaitLaneIdle() async { await lane.awaitIdle() }

    func send(_ input: OutOfBandScopeGraph.Input) throws {
        try machine.send(input)
        drainCommands()
    }

    func finishReceipt(with value: String) {
        guard let current = receipt else { return }
        receipt = nil
        receiptAcknowledgements.append(
            (.terminated, machine.acknowledgeExecution(current.execution, disposition: .terminated))
        )
        let delivery = machine.deliver(.receive(current.succeeded(value)))
        receiptDeliveries.append(delivery)
        if case .committed = delivery {
            drainCommands()
        }
    }

    private func drainCommands() {
        for batch in machine.drainCommands() {
            for command in batch.commands {
                switch command {
                case .cancel(let handle):
                    if receipt?.execution == handle {
                        receipt = nil
                        receiptAcknowledgements.append(
                            (.terminated, machine.acknowledgeExecution(handle, disposition: .terminated))
                        )
                    }
                    if lane.cancel(handle: handle) {
                        laneAcknowledgements.append(
                            (
                                .skippedBeforeStart,
                                machine.acknowledgeExecution(handle, disposition: .skippedBeforeStart)
                            )
                        )
                    }
                case .receive(let work):
                    precondition(receipt == nil)
                    receipt = work
                case .render(let work):
                    let driver = renderDriver
                    lane.schedule(handle: work.execution) {
                        .render(work.succeeded(await driver(work.input)))
                    }
                }
            }
        }
        startLane()
    }

    private func startLane() {
        lane.startIfIdle { [weak self] handle, outcome in
            guard let self else { return }
            switch outcome {
            case .skippedBeforeStart:
                laneAcknowledgements.append(
                    (.skippedBeforeStart, machine.acknowledgeExecution(handle, disposition: .skippedBeforeStart))
                )
            case .finished(let completion):
                laneAcknowledgements.append(
                    (.terminated, machine.acknowledgeExecution(handle, disposition: .terminated))
                )
                let delivery = machine.deliver(completion)
                laneDeliveries.append(delivery)
                if case .committed = delivery {
                    drainCommands()
                }
            }
            startLane()
        }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct SerializedPipelineBoundaryTests {
    @Test func outOfBandReceiptAndNamedScopeInvalidationRespectExactHandlesOnProductionLane() async throws {
        let render1Entered = Signal()
        let render1Gate = ThreadGate()
        defer { render1Gate.open() }

        let render2Entered = Signal()
        let render2Gate = ThreadGate()
        defer { render2Gate.open() }

        let host = OutOfBandScopeHost { id in
            if id == "render-1" {
                return await withCheckedContinuation { continuation in
                    runOnOwnThread {
                        render1Entered.raise()
                        render1Gate.wait()
                        continuation.resume(returning: "done-1")
                    }
                }
            }
            if id == "render-2" {
                return await withCheckedContinuation { continuation in
                    runOnOwnThread {
                        render2Entered.raise()
                        render2Gate.wait()
                        continuation.resume(returning: "done-2")
                    }
                }
            }
            return "done-\(id)"
        }

        // Start an out-of-band receipt alongside a blocked lane render.
        try host.send(.startReceipt("rcpt-1"))
        try host.send(.startLane("render-1"))
        await render1Entered.wait()

        // Invalidating Scope.lane cancels render-1 without disturbing the live out-of-band receipt.
        try host.send(.invalidateLane)
        #expect(host.hasLiveReceipt)
        #expect(host.hasRunningLane)
        #expect(host.receiptAcknowledgements.isEmpty)

        // Complete the unaffected receipt while render-1 is still blocked.
        host.finishReceipt(with: "payload-1")
        #expect(!host.hasLiveReceipt)
        #expect(host.receiptAcknowledgements.count == 1)
        #expect(host.receiptAcknowledgements[0] == (.terminated, .recorded))
        guard case .active(let afterReceipt) = host.snapshot().model else {
            Issue.record("Expected active phase")
            return
        }
        #expect(afterReceipt == .init(receiptResult: "payload-1", rendered: nil))

        // Unblock render-1; its completion is stale because Scope.lane was invalidated.
        render1Gate.open()
        await host.awaitLaneIdle()
        #expect(host.laneAcknowledgements.count == 1)
        #expect(host.laneAcknowledgements[0] == (.terminated, .recorded))
        guard case .stale = host.laneDeliveries.first else {
            Issue.record("Expected stale delivery for invalidated lane render")
            return
        }

        // Start a second receipt alongside BOTH a blocked running render-2 and a queued pending render-3,
        // then invalidate Scope.receipt only: neither running nor pending in SerialExecutionLane is disturbed.
        try host.send(.startReceipt("rcpt-2"))
        try host.send(.startLane("render-2"))
        await render2Entered.wait()
        try host.send(.startLane("render-3"))
        #expect(host.hasRunningLane)
        #expect(host.hasPendingLane)

        try host.send(.invalidateReceipt)
        #expect(!host.hasLiveReceipt)
        #expect(host.hasRunningLane)
        #expect(host.hasPendingLane)
        #expect(host.receiptAcknowledgements.count == 2)
        #expect(host.receiptAcknowledgements[1] == (.terminated, .recorded))
        #expect(host.laneAcknowledgements.count == 1)

        // Unblock render-2: render-2 finishes stale, then unaffected pending render-3 runs and commits cleanly.
        render2Gate.open()
        await host.awaitLaneIdle()
        guard case .active(let finalState) = host.snapshot().model else {
            Issue.record("Expected active phase")
            return
        }
        #expect(finalState == .init(receiptResult: "payload-1", rendered: "done-render-3"))
        #expect(host.laneAcknowledgements.count == 3)
        #expect(host.laneAcknowledgements[1] == (.terminated, .recorded))
        #expect(host.laneAcknowledgements[2] == (.terminated, .recorded))
        guard case .stale = host.laneDeliveries[1], case .committed = host.laneDeliveries[2] else {
            Issue.record("Expected stale delivery for render-2 followed by committed delivery for render-3")
            return
        }
    }
}
