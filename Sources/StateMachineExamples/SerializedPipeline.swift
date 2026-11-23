import Dispatch
import StateMachine

/// A two-stage isolated pipeline driven through `Local` with a serialized latest-pending lane.
///
/// Leaving `Detecting` or `Rendering` revokes that stage's operation authority immediately, while
/// ``SerializedPipelineSession`` waits for an active off-main-actor render to physically return
/// before launching the newest queued stage. Transitions emit ``Notice`` ahead of any operation
/// started in the same batch so callers can observe stage milestones in commit order.
@StateMachine(mode: .isolated, owners: [.local])
nonisolated public enum SerializedPipeline {
    /// Non-`Sendable` reference-counted input carried into `Detect` on the owning actor's isolation domain.
    public final class Item {
        /// Stable identifier for the selected item.
        public let id: String

        /// Creates an item with an identifier.
        public init(id: String) {
            self.id = id
        }
    }

    /// Immutable `Sendable` input handed to an off-main-actor render call.
    public struct RenderJob: Sendable, Equatable {
        /// Identifier of the item being rendered.
        public let itemID: String
        /// Regions produced by detection.
        public let regions: [String]

        /// Creates a render request for one detected item.
        public init(itemID: String, regions: [String]) {
            self.itemID = itemID
            self.regions = regions
        }
    }

    /// One-shot milestone emitted by a transition ahead of any operation started in the same batch.
    public enum Milestone: Sendable, Equatable {
        /// Detection was requested for an item.
        case selected(itemID: String)
        /// Detection produced regions for an item before rendering starts.
        case detected(itemID: String, regions: [String])
        /// Rendering finished for an item.
        case rendered(itemID: String)
        /// The active selection was cleared.
        case cleared
    }

    /// No item is selected.
    public struct Idle: Equatable {
        /// Creates an idle phase payload.
        public init() {}
    }

    /// Detection is active for the selected item.
    public struct Detecting: Equatable {
        /// Identifier of the selected item.
        public let itemID: String

        /// Creates a detecting phase payload.
        public init(itemID: String) { self.itemID = itemID }
    }

    /// Rendering is active for the detected regions.
    public struct Rendering: Equatable {
        /// Identifier of the item being rendered.
        public let itemID: String
        /// Regions handed to the renderer.
        public let regions: [String]

        /// Creates a rendering phase payload.
        public init(itemID: String, regions: [String]) {
            self.itemID = itemID
            self.regions = regions
        }
    }

    /// Rendering completed for the current item.
    public struct Ready: Equatable {
        /// Identifier of the rendered item.
        public let itemID: String
        /// Final rendered output.
        public let output: String

        /// Creates a ready phase payload.
        public init(itemID: String, output: String) {
            self.itemID = itemID
            self.output = output
        }
    }

    @Initial case idle(Idle = Idle())
    case detecting(Detecting)
    case rendering(Rendering)
    case ready(Ready)

    /// Dynamic inputs accepted by the pipeline.
    public enum Input {
        /// Replaces any active stage with detection for a new item.
        case select(Item)
        /// Cancels any active stage and returns to `Idle`.
        case clear
    }

    /// Stage milestone emitted ahead of any operation started in the same command batch.
    @Event public enum Notice {
        /// The milestone payload.
        public typealias Payload = Milestone
    }

    /// First pipeline stage, active only while `Detecting`.
    @Operation(activeIn: [Detecting.self])
    public enum Detect {
        /// The selected non-`Sendable` item.
        public typealias Input = Item
        /// The detected region labels.
        public typealias Output = [String]
    }

    /// Second pipeline stage, active only while `Rendering`.
    @Operation(activeIn: [Rendering.self])
    public enum Render {
        /// The immutable `Sendable` request passed off `@MainActor`.
        public typealias Input = RenderJob
        /// The rendered result.
        public typealias Output = String
    }

    @Transition(
        from: [Idle.self, Detecting.self, Rendering.self, Ready.self],
        on: Input.select,
        starts: [Detect.self],
        emits: [Notice.self]
    )
    fileprivate static func select(_ item: Item) -> Change<Detecting, Effect.Select> {
        Change(Detecting(itemID: item.id), effects: [.notice(.selected(itemID: item.id)), .detect(item)])
    }

    @Transition(
        from: [Idle.self, Detecting.self, Rendering.self, Ready.self],
        on: Input.clear,
        emits: [Notice.self]
    )
    fileprivate static func clear() -> Change<Idle, Effect.Clear> {
        Change(Idle(), effects: [.notice(.cleared)])
    }

    @Transition(onSuccess: Detect.self, starts: [Render.self], emits: [Notice.self])
    fileprivate static func detected(
        _ source: Detecting,
        _ regions: Detect.Output
    ) -> Change<Rendering, Effect.Detected> {
        let request = RenderJob(itemID: source.itemID, regions: regions)
        return Change(
            Rendering(itemID: source.itemID, regions: regions),
            effects: [.notice(.detected(itemID: source.itemID, regions: regions)), .render(request)]
        )
    }

    @Transition(onSuccess: Render.self, emits: [Notice.self])
    fileprivate static func rendered(_ source: Rendering, _ output: Render.Output) -> Change<Ready, Effect.Rendered> {
        Change(Ready(itemID: source.itemID, output: output), effects: [.notice(.rendered(itemID: source.itemID))])
    }
}

/// Single-running, latest-pending execution lane shared by ``SerializedPipelineSession`` and package tests.
///
/// Keeps at most one task physically in flight (`running`) and one newest replacement (`pending`),
/// matching cancellations by exact handle and distinguishing pre-start `Task.isCancelled` from
/// physical driver return.
@MainActor package final class SerialExecutionLane<Handle: Equatable & Sendable, Completion> {
    package enum CompletionOutcome {
        case skippedBeforeStart
        case finished(Completion)
    }

    private struct Running: Sendable {
        let handle: Handle
        let task: Task<Void, Never>
    }

    private struct Pending {
        let handle: Handle
        let work: @MainActor () async -> Completion
    }

    private var running: Running?
    private var pending: Pending?

    package init() {}

    deinit { running?.task.cancel() }

    package var hasRunningWork: Bool { running != nil }
    package var hasPendingWork: Bool { pending != nil }

    /// Cancels a matching pending or running handle without disturbing unrelated handles.
    ///
    /// Returns `true` when `handle` matched the queued `pending` entry (which is cleared immediately
    /// so the caller can acknowledge `.skippedBeforeStart`). When `handle` matches `running`, signals
    /// `task.cancel()` without clearing `running` and returns `false`.
    @discardableResult package func cancel(handle: Handle) -> Bool {
        if pending?.handle == handle {
            pending = nil
            return true
        }
        if running?.handle == handle {
            running?.task.cancel()
        }
        return false
    }

    /// Requests cancellation on any running task without clearing `running`.
    package func cancelRunning() {
        running?.task.cancel()
    }

    /// Installs `work` in the single pending slot, trapping if an uncancelled handle already occupies it.
    package func schedule(handle: Handle, work: @escaping @MainActor () async -> Completion) {
        precondition(
            pending == nil,
            "SerialExecutionLane cannot overwrite an uncancelled pending execution handle."
        )
        pending = Pending(handle: handle, work: work)
    }

    /// Launches the pending closure if no task is currently running.
    package func startIfIdle(
        onComplete: @escaping @MainActor (Handle, CompletionOutcome) -> Void
    ) {
        guard running == nil, let entry = pending else { return }
        pending = nil
        let task = Task { [weak self] in
            if Task.isCancelled {
                guard let self else { return }
                running = nil
                onComplete(entry.handle, .skippedBeforeStart)
                return
            }

            let completion = await entry.work()
            guard let self else { return }
            running = nil
            onComplete(entry.handle, .finished(completion))
        }
        running = Running(handle: entry.handle, task: task)
    }

    /// Waits until the currently running task and any successor chained after it have finished.
    package func awaitIdle() async {
        while let task = running?.task {
            await task.value
        }
    }
}

/// Drives a caller-owned ``SerializedPipeline/Local`` with at most one running task and one pending closure.
///
/// When a selection supersedes an active off-main-actor render that ignores cancellation, this runner
/// commits the new selection synchronously, requests cancellation on the running task without
/// acknowledging early, holds only the newest replacement in `pending`, and waits for the active
/// call to physically return before acknowledging `.terminated` and starting the pending successor.
///
/// All outward callbacks (`onEvent`, `onChange`, and package test hooks) are queued while draining
/// commands and pumped in FIFO order only after internal scheduling state has settled.
///
/// This pattern bounds concurrency to one heavy call in flight and one pending closure queued. It
/// does not interrupt synchronous C or Core Graphics work, nor does it bound total process memory or
/// completion latency.
@MainActor public final class SerializedPipelineSession {
    /// Driver closures supplied by the caller for each pipeline operation.
    public struct Drivers {
        /// Runs detection for one selected item.
        public var detect: @MainActor (SerializedPipeline.Item) async -> [String]
        /// Runs rendering for one immutable request.
        public var render: @MainActor (SerializedPipeline.RenderJob) async -> String

        /// Creates a pair of stage drivers.
        public init(
            detect: @escaping @MainActor (SerializedPipeline.Item) async -> [String],
            render: @escaping @MainActor (SerializedPipeline.RenderJob) async -> String
        ) {
            self.detect = detect
            self.render = render
        }

        /// Default drivers that detect synchronously and execute rendering off `@MainActor`.
        public static var live: Drivers {
            Drivers(
                detect: { item in ["region-\(item.id)"] },
                render: { request in await SerializedPipelineSession.renderOffMainActor(request) }
            )
        }
    }

    package enum Stage: Equatable, Sendable {
        case detect(itemID: String)
        case render(itemID: String)
    }

    private enum OutwardNotification {
        case event(SerializedPipeline.Milestone)
        case change(SerializedPipeline.Snapshot)
        case acknowledge(Stage, SerializedPipeline.ExecutionHandle, ExecutionDisposition, AcknowledgmentResult)
        case deliver(SerializedPipeline.Completion, SerializedPipeline.DeliveryResult)
    }

    /// Outward milestone observer invoked in FIFO commit order after all internal commands are installed.
    public var onEvent: (@MainActor (SerializedPipeline.Milestone) -> Void)?
    /// Outward snapshot observer invoked in FIFO commit order after all internal commands are installed.
    public var onChange: (@MainActor (SerializedPipeline.Snapshot) -> Void)?

    package var onAcknowledge:
        (
            @MainActor (Stage, SerializedPipeline.ExecutionHandle, ExecutionDisposition, AcknowledgmentResult) -> Void
        )?
    package var onDeliver: (@MainActor (SerializedPipeline.Completion, SerializedPipeline.DeliveryResult) -> Void)?

    private let drivers: Drivers
    private var machine: SerializedPipeline.Local
    private let lane = SerialExecutionLane<SerializedPipeline.ExecutionHandle, SerializedPipeline.Completion>()
    private var activeStages: [(handle: SerializedPipeline.ExecutionHandle, stage: Stage)] = []
    private var pendingNotifications: [OutwardNotification?] = []
    private var notificationHead = 0
    private var isPumpingNotifications = false

    /// Creates a session owning a fresh ``SerializedPipeline/Local`` in `Idle`.
    public init(
        drivers: Drivers = .live,
        configuration: SerializedPipeline.LocalConfiguration = .default
    ) {
        self.drivers = drivers
        machine = SerializedPipeline.Local(configuration: configuration)
    }

    /// Runs a synchronous render transform off `@MainActor` without observing Swift task cancellation.
    nonisolated public static func renderOffMainActor(
        _ request: SerializedPipeline.RenderJob,
        transform: @escaping @Sendable (SerializedPipeline.RenderJob) -> String = {
            "\($0.itemID):\($0.regions.joined(separator: ","))"
        }
    ) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated)
                .async {
                    continuation.resume(returning: transform(request))
                }
        }
    }

    /// Returns the owner's current historical snapshot.
    public func snapshot() -> SerializedPipeline.Snapshot { machine.snapshot() }

    /// Whether closure, batch draining, and every physical execution obligation have settled.
    public var isQuiescent: Bool { machine.isQuiescent }

    package var hasPendingWork: Bool { lane.hasPendingWork }
    package var hasRunningWork: Bool { lane.hasRunningWork }

    /// Selects an item synchronously, draining cancellations and starts before notifying observers.
    @discardableResult public func select(
        _ item: SerializedPipeline.Item
    ) throws(SerializedPipeline.SendRejection) -> SerializedPipeline.Receipt {
        try send(.select(item))
    }

    /// Clears the selection synchronously, suppressing any queued replacement and returning to `Idle`.
    @discardableResult public func clear() throws(SerializedPipeline.SendRejection) -> SerializedPipeline.Receipt {
        try send(.clear)
    }

    /// Closes admission, acknowledges any skipped pending work, and cancels the running task without early acknowledgment.
    @discardableResult public func close() -> SerializedPipeline.Receipt {
        let wasClosed = machine.snapshot().isClosed
        let receipt = machine.close()
        drainCommands()
        lane.cancelRunning()
        if !wasClosed {
            enqueue(.change(receipt.snapshot))
        }
        pumpNotifications()
        return receipt
    }

    /// Waits until the currently running task and any successor chained after it have finished.
    public func awaitIdle() async {
        await lane.awaitIdle()
    }

    private func send(
        _ input: SerializedPipeline.Input
    ) throws(SerializedPipeline.SendRejection) -> SerializedPipeline.Receipt {
        let receipt = try machine.send(input)
        drainCommands()
        enqueue(.change(receipt.snapshot))
        pumpNotifications()
        return receipt
    }

    private func deliver(_ completion: SerializedPipeline.Completion) {
        let result = machine.deliver(completion)
        enqueue(.deliver(completion, result))
        guard case .committed(let receipt) = result else { return }
        drainCommands()
        enqueue(.change(receipt.snapshot))
    }

    private func drainCommands() {
        for batch in machine.drainCommands() {
            for command in batch.commands {
                switch command {
                case .cancel(let handle):
                    if lane.cancel(handle: handle) {
                        acknowledge(handle, disposition: .skippedBeforeStart)
                    }
                case .notice(let milestone):
                    enqueue(.event(milestone))
                case .detect(let work):
                    let detect = drivers.detect
                    schedule(stage: .detect(itemID: work.input.id), handle: work.execution) {
                        .detect(work.succeeded(await detect(work.input)))
                    }
                case .render(let work):
                    let render = drivers.render
                    schedule(stage: .render(itemID: work.input.itemID), handle: work.execution) {
                        .render(work.succeeded(await render(work.input)))
                    }
                }
            }
        }
        startPendingWork()
    }

    private func schedule(
        stage: Stage,
        handle: SerializedPipeline.ExecutionHandle,
        work: @escaping @MainActor () async -> SerializedPipeline.Completion
    ) {
        lane.schedule(handle: handle, work: work)
        activeStages.append((handle: handle, stage: stage))
    }

    private func startPendingWork() {
        lane.startIfIdle { [weak self] handle, outcome in
            self?.handleLaneCompletion(handle: handle, outcome: outcome)
        }
    }

    private func handleLaneCompletion(
        handle: SerializedPipeline.ExecutionHandle,
        outcome: SerialExecutionLane<SerializedPipeline.ExecutionHandle, SerializedPipeline.Completion>
            .CompletionOutcome
    ) {
        switch outcome {
        case .skippedBeforeStart:
            acknowledge(handle, disposition: .skippedBeforeStart)
            startPendingWork()
            pumpNotifications()
        case .finished(let completion):
            acknowledge(handle, disposition: .terminated)
            deliver(completion)
            startPendingWork()
            pumpNotifications()
        }
    }

    private func acknowledge(
        _ handle: SerializedPipeline.ExecutionHandle,
        disposition: ExecutionDisposition
    ) {
        let result = machine.acknowledgeExecution(handle, disposition: disposition)
        if let stage = takeStage(for: handle) {
            enqueue(.acknowledge(stage, handle, disposition, result))
        }
    }

    private func takeStage(for handle: SerializedPipeline.ExecutionHandle) -> Stage? {
        guard let index = activeStages.firstIndex(where: { $0.handle == handle }) else { return nil }
        return activeStages.remove(at: index).stage
    }

    private func enqueue(_ notification: OutwardNotification) {
        pendingNotifications.append(notification)
    }

    private func pumpNotifications() {
        guard !isPumpingNotifications else { return }
        isPumpingNotifications = true
        defer {
            isPumpingNotifications = false
            if notificationHead == pendingNotifications.count {
                pendingNotifications.removeAll(keepingCapacity: false)
                notificationHead = 0
            }
        }

        while notificationHead < pendingNotifications.count {
            let notification = pendingNotifications[notificationHead]
            pendingNotifications[notificationHead] = nil
            notificationHead += 1
            switch notification {
            case .event(let milestone):
                onEvent?(milestone)
            case .change(let snapshot):
                onChange?(snapshot)
            case .acknowledge(let stage, let handle, let disposition, let result):
                onAcknowledge?(stage, handle, disposition, result)
            case .deliver(let completion, let result):
                onDeliver?(completion, result)
            case nil:
                break
            }
        }
    }
}
