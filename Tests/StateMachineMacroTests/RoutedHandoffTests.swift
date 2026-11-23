import StateMachine
import Testing
import os

// MARK: - Sorting-style non-Sendable isolated schema with input + completion routed handoffs

/// External mutable instrumentation box for `.isolated` sorting-style routed transitions.
///
/// Intentionally non-Sendable to exercise `.isolated` confinement with closures and mutable counters.
nonisolated private final class SortingProbe {
    var readyRouteCalls = 0
    var presentFirstCalls = 0
    var finishFromReadyCalls = 0
    var chooseRouteCalls = 0
    var advanceComparisonCalls = 0
    var finishComparingCalls = 0
    var stayComparingCalls = 0
    var closureInvocations = 0
    var observedStepOutputs: [String] = []
    var observedRequestInputs: [Int] = []
    var emittedEvents: [String] = []

    /// Scripted steps returned by `nextStep()` in order.
    var scriptedSteps: [ScriptedStep]

    enum ScriptedStep {
        case comparison(left: Int, right: Int, delta: Int)
        case finished(winner: Int, label: String)
        case noChange
    }

    init(scriptedSteps: [ScriptedStep]) {
        self.scriptedSteps = scriptedSteps
    }

    func nextStep() -> ScriptedStep {
        guard !scriptedSteps.isEmpty else { return .noChange }
        return scriptedSteps.removeFirst()
    }
}

@StateMachine(mode: .isolated, owners: [.owned, .local, .mainActorHost])
nonisolated private enum SortingRoutedDemo {
    /// Non-Sendable computed payload passed from `@Route` to the chosen candidate via `routed:`.
    fileprivate struct ComparisonStep {
        let left: Int
        let right: Int
        let resolve: (Bool) -> Int
    }

    struct Ready {
        let probe: SortingProbe
        let baseScore: Int
    }

    struct Comparing {
        let probe: SortingProbe
        let left: Int
        let right: Int
        let resolve: (Bool) -> Int
        let lastOutput: String
        let lastRequestInput: Int
        let rounds: Int
    }

    struct Finished {
        let probe: SortingProbe
        let winner: Int
        let label: String
    }

    @Initial case ready(Ready)
    case comparing(Comparing)
    case finished(Finished)

    enum Input {
        case start(Int)
        case ping
        case choose(Bool)
    }

    @Operation(activeIn: [Ready.self, Comparing.self])
    enum StepDelay {
        typealias Input = Int
        typealias Output = String
    }

    @Operation(activeIn: [Finished.self])
    enum ReshuffleDelay {
        typealias Input = Int
        typealias Output = Void
    }

    @Event enum ComparisonPresented { typealias Payload = Int }
    @Event enum SortCompleted { typealias Payload = String }

    @Transition(on: Input.start, starts: [StepDelay.self])
    fileprivate static func start(_ source: Ready, _ delayMs: Int) -> Change<Ready, Effect.Start> {
        Change(source, effects: [.stepDelay(delayMs)])
    }

    @Transition(on: Input.ping, emits: [ComparisonPresented.self])
    fileprivate static func ping(_ source: Ready) -> Change<Ready, Effect.Ping> {
        Change(source, effects: [.comparisonPresented(0)])
    }

    // Completion router on Ready with distinct per-branch starts/emits + original output & request:.
    @Transition(onSuccess: StepDelay.self, starts: [StepDelay.self], emits: [ComparisonPresented.self])
    fileprivate static func presentFirst(
        _ source: Ready,
        _ output: String,
        request: StepDelayRequest,
        routed step: ComparisonStep
    ) -> Change<Comparing, Effect.PresentFirst> {
        source.probe.presentFirstCalls += 1
        source.probe.observedStepOutputs.append(output)
        source.probe.observedRequestInputs.append(request.input)
        return Change(
            Comparing(
                probe: source.probe,
                left: step.left,
                right: step.right,
                resolve: step.resolve,
                lastOutput: output,
                lastRequestInput: request.input,
                rounds: 1
            ),
            effects: [.stepDelay(request.input + 1), .comparisonPresented(step.left + step.right)]
        )
    }

    @Transition(onSuccess: StepDelay.self, starts: [ReshuffleDelay.self], emits: [SortCompleted.self])
    fileprivate static func finishFromReady(
        _ source: Ready,
        _ output: String,
        request: StepDelayRequest
    ) -> Change<Finished, Effect.FinishFromReady> {
        source.probe.finishFromReadyCalls += 1
        source.probe.observedStepOutputs.append(output)
        source.probe.observedRequestInputs.append(request.input)
        return Change(
            Finished(probe: source.probe, winner: source.baseScore, label: "ready:\(output)"),
            effects: [.reshuffleDelay(request.input), .sortCompleted("ready:\(output)")]
        )
    }

    @Route(onSuccess: StepDelay.self)
    fileprivate static func routeReadyStep(
        _ source: Ready,
        _ output: String,
        request: StepDelayRequest
    ) -> Route.RouteReadyStep {
        source.probe.readyRouteCalls += 1
        let probe = source.probe
        switch probe.nextStep() {
        case .comparison(let left, let right, let delta):
            let step = ComparisonStep(
                left: left,
                right: right,
                resolve: { pickLeft in
                    probe.closureInvocations += 1
                    return (pickLeft ? left : right) + delta
                }
            )
            return .presentFirst(step)
        case .finished, .noChange:
            return .finishFromReady
        }
    }

    // Input router on Comparing mixing closure struct, tuple payload, and payloadless branch.
    @Transition(on: Input.choose, emits: [ComparisonPresented.self])
    fileprivate static func advanceComparison(
        _ source: Comparing,
        _ pickLeft: Bool,
        routed step: ComparisonStep
    ) -> Change<Comparing, Effect.AdvanceComparison> {
        source.probe.advanceComparisonCalls += 1
        return Change(
            Comparing(
                probe: source.probe,
                left: step.left,
                right: step.right,
                resolve: step.resolve,
                lastOutput: source.lastOutput,
                lastRequestInput: source.lastRequestInput,
                rounds: source.rounds + 1
            ),
            effects: [.comparisonPresented(step.left + step.right)]
        )
    }

    @Transition(on: Input.choose, starts: [ReshuffleDelay.self], emits: [SortCompleted.self])
    fileprivate static func finishComparing(
        _ source: Comparing,
        _ pickLeft: Bool,
        routed summary: (winner: Int, label: String)
    ) -> Change<Finished, Effect.FinishComparing> {
        source.probe.finishComparingCalls += 1
        return Change(
            Finished(probe: source.probe, winner: summary.winner, label: summary.label),
            effects: [.reshuffleDelay(summary.winner), .sortCompleted(summary.label)]
        )
    }

    @Transition(on: Input.choose)
    fileprivate static func stayComparing(_ source: Comparing, _ pickLeft: Bool) -> Comparing {
        source.probe.stayComparingCalls += 1
        return source
    }

    @Route(on: Input.choose)
    fileprivate static func routeChoice(_ source: Comparing, _ pickLeft: Bool) -> Route.RouteChoice {
        source.probe.chooseRouteCalls += 1
        let score = source.resolve(pickLeft)
        let probe = source.probe
        switch probe.nextStep() {
        case .comparison(let left, let right, let delta):
            return .advanceComparison(
                ComparisonStep(
                    left: left,
                    right: right,
                    resolve: { nextLeft in
                        probe.closureInvocations += 1
                        return (nextLeft ? left : right) + delta + score
                    }
                )
            )
        case .finished(let winner, let label):
            return .finishComparing((winner: winner + score, label: label))
        case .noChange:
            return .stayComparing
        }
    }

    @Transition(onSuccess: StepDelay.self)
    fileprivate static func ignoreComparingDelay(
        _ source: Comparing,
        _ output: String
    ) -> Comparing {
        source
    }

    @Transition(onSuccess: ReshuffleDelay.self)
    fileprivate static func reshuffled(_ source: Finished) -> Ready {
        Ready(probe: source.probe, baseScore: source.winner)
    }
}

// MARK: - Throwing input & completion routed handoffs in .shared mode

nonisolated private final class SharedCounters: Sendable {
    struct State: Sendable {
        var inputRouteCalls = 0
        var toBrowsingCalls = 0
        var toSheetCalls = 0
        var completionRouteCalls = 0
        var acceptResultCalls = 0
        var fallbackResultCalls = 0
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    var snapshot: State { state.withLock { $0 } }
}

@StateMachine(mode: .shared, owners: [.owned, .local, .shared])
nonisolated private enum ThrowingRoutedFlow: Sendable {
    enum Destination: Sendable, Equatable {
        case list(Int)
        case sheet(Int, String)
        case forbidden
    }

    enum PendingFailure: Error, Equatable, Sendable {
        case unavailable(Int)
        case forbiddenDestination
        case emptySheet
        case notReadyToAccept
        case rejectedOutput(Int)
    }

    struct Pending: Sendable, Equatable {
        let destination: Destination
        let allowCompletion: Bool
        let counters: SharedCounters
        static func == (lhs: Pending, rhs: Pending) -> Bool {
            lhs.destination == rhs.destination && lhs.allowCompletion == rhs.allowCompletion
        }
    }

    struct Browsing: Sendable, Equatable {
        let selectedID: Int?
        let note: String
    }

    struct PresentingSheet: Sendable, Equatable {
        let selectedID: Int?
        let sheet: String
    }

    @Initial case pending(Pending)
    case browsing(Browsing)
    @Terminal case presentingSheet(PresentingSheet)

    enum Input: Sendable {
        case process(Set<Int>)
        case beginFetch(Int)
        case allowCompletion
    }

    @Operation(activeIn: [Pending.self])
    enum Fetch {
        typealias Input = Int
        typealias Output = Int
    }

    @Transition(on: Input.beginFetch, starts: [Fetch.self])
    fileprivate static func beginFetch(_ source: Pending, _ token: Int) -> Change<Pending, Effect.BeginFetch> {
        Change(source, effects: [.fetch(token)])
    }

    @Transition(on: Input.allowCompletion)
    fileprivate static func allowCompletion(_ source: Pending) -> Pending {
        Pending(destination: source.destination, allowCompletion: true, counters: source.counters)
    }

    @Transition(on: Input.process)
    fileprivate static func resolveToBrowsing(
        _ source: Pending,
        _ available: Set<Int>,
        routed selectedID: Int?
    ) -> Browsing {
        source.counters.state.withLock { $0.toBrowsingCalls += 1 }
        return Browsing(selectedID: selectedID, note: "browsing")
    }

    @Transition(on: Input.process)
    fileprivate static func resolveToSheet(
        _ source: Pending,
        _ available: Set<Int>,
        routed target: (selectedID: Int?, sheet: String)
    ) throws(PendingFailure) -> PresentingSheet {
        source.counters.state.withLock { $0.toSheetCalls += 1 }
        guard !target.sheet.isEmpty else { throw .emptySheet }
        return PresentingSheet(selectedID: target.selectedID, sheet: target.sheet)
    }

    @Route(on: Input.process)
    fileprivate static func resolvePending(
        _ source: Pending,
        _ available: Set<Int>
    ) throws(PendingFailure) -> Route.ResolvePending {
        source.counters.state.withLock { $0.inputRouteCalls += 1 }
        switch source.destination {
        case .list(let id):
            guard available.contains(id) else { throw .unavailable(id) }
            return .resolveToBrowsing(id)
        case .sheet(let id, let sheet):
            guard available.contains(id) else { throw .unavailable(id) }
            return .resolveToSheet((selectedID: id, sheet: sheet))
        case .forbidden:
            throw .forbiddenDestination
        }
    }

    @Transition(onSuccess: Fetch.self)
    fileprivate static func acceptResult(
        _ source: Pending,
        _ output: Int,
        request: FetchRequest,
        routed computed: String
    ) throws(PendingFailure) -> Browsing {
        source.counters.state.withLock { $0.acceptResultCalls += 1 }
        guard output >= 0 else { throw .rejectedOutput(output) }
        return Browsing(selectedID: request.input, note: computed)
    }

    @Transition(onSuccess: Fetch.self)
    fileprivate static func fallbackResult(
        _ source: Pending,
        _ output: Int,
        request: FetchRequest
    ) -> PresentingSheet {
        source.counters.state.withLock { $0.fallbackResultCalls += 1 }
        return PresentingSheet(selectedID: request.input, sheet: "fallback:\(output)")
    }

    @Route(onSuccess: Fetch.self)
    fileprivate static func routeFetch(
        _ source: Pending,
        _ output: Int,
        request: FetchRequest
    ) throws(PendingFailure) -> Route.RouteFetch {
        source.counters.state.withLock { $0.completionRouteCalls += 1 }
        guard source.allowCompletion else { throw .notReadyToAccept }
        if output == 999 {
            return .fallbackResult
        }
        return .acceptResult("req=\(request.input),out=\(output)")
    }

    @Transition(on: Input.allowCompletion)
    fileprivate static func noopBrowsing(_ source: Browsing) -> Browsing { source }
}

// MARK: - Move-only (~Copyable) routed value in .isolated with consuming & borrowing

nonisolated private final class HandleTracker {
    var deinitedIDs: [Int] = []
    var routeCalls = 0
    var takeCalls = 0
    var inspectCalls = 0
    var skipCalls = 0
}

@StateMachine(mode: .isolated, owners: [.owned, .local])
nonisolated private enum MoveOnlyRoutedFlow {
    fileprivate struct Handle: ~Copyable {
        let id: Int
        let tracker: HandleTracker
        deinit { tracker.deinitedIDs.append(id) }
    }

    enum Action {
        case take(Int)
        case inspect(Int)
        case skip
    }

    struct Open { let tracker: HandleTracker }
    struct Taken { let fd: Int }
    struct Inspected { let fd: Int }
    struct Skipped {}

    @Initial case open(Open)
    @Terminal case taken(Taken)
    @Terminal case inspected(Inspected)
    @Terminal case skipped(Skipped)

    enum Input { case run(Action) }

    @Transition(on: Input.run)
    fileprivate static func take(_ source: Open, _ action: Action, routed handle: consuming Handle) -> Taken {
        source.tracker.takeCalls += 1
        return Taken(fd: handle.id)
    }

    @Transition(on: Input.run)
    fileprivate static func inspect(_ source: Open, _ action: Action, routed handle: borrowing Handle) -> Inspected {
        source.tracker.inspectCalls += 1
        return Inspected(fd: handle.id)
    }

    @Transition(on: Input.run)
    fileprivate static func skip(_ source: Open, _ action: Action) -> Skipped {
        source.tracker.skipCalls += 1
        return Skipped()
    }

    @Route(on: Input.run)
    fileprivate static func routeOpen(_ source: Open, _ action: Action) -> Route.RouteOpen {
        source.tracker.routeCalls += 1
        switch action {
        case .take(let id):
            return .take(Handle(id: id, tracker: source.tracker))
        case .inspect(let id):
            return .inspect(Handle(id: id, tracker: source.tracker))
        case .skip:
            return .skip
        }
    }
}

// MARK: - Same router name across different phases with different vs matching choice shapes

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated private enum SplitChoiceFlow: Sendable {
    struct Alpha: Sendable { let seed: Int }
    struct Beta: Sendable { let prefix: String }
    struct Done: Sendable, Equatable { let summary: String }

    @Initial case alpha(Alpha)
    case beta(Beta)
    @Terminal case done(Done)

    enum Input: Sendable { case step(Bool) }

    @Transition(on: Input.step)
    fileprivate static func advance(_ source: Alpha, _ move: Bool, routed amount: Int) -> Beta {
        Beta(prefix: "a:\(source.seed + amount)")
    }

    @Transition(on: Input.step)
    fileprivate static func stay(_ source: Alpha, _ move: Bool) -> Alpha { source }

    @Route(on: Input.step)
    fileprivate static func choose(_ source: Alpha, _ move: Bool) -> Route.Alpha.Choose {
        move ? .advance(source.seed * 10) : .stay
    }

    @Transition(on: Input.step)
    fileprivate static func advance(_ source: Beta, _ move: Bool, routed suffix: String) -> Done {
        Done(summary: "\(source.prefix)->\(suffix)")
    }

    @Transition(on: Input.step)
    fileprivate static func stay(_ source: Beta, _ move: Bool) -> Beta { source }

    @Route(on: Input.step)
    fileprivate static func choose(_ source: Beta, _ move: Bool) -> Route.Beta.Choose {
        move ? .advance("finished") : .stay
    }
}

@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated private enum SharedChoiceAliasFlow: Sendable {
    typealias Count = Int
    struct Alpha: Sendable { let base: Int }
    struct Beta: Sendable { let base: Int }
    struct Done: Sendable, Equatable { let total: Int }

    @Initial case alpha(Alpha)
    case beta(Beta)
    @Terminal case done(Done)

    enum Input: Sendable { case step(Bool) }

    @Transition(on: Input.step)
    fileprivate static func next(_ source: Alpha, _ go: Bool, routed delta: Int) -> Beta {
        Beta(base: source.base + delta)
    }
    @Transition(on: Input.step)
    fileprivate static func stay(_ source: Alpha, _ go: Bool) -> Alpha { source }
    @Route(on: Input.step)
    fileprivate static func choose(_ source: Alpha, _ go: Bool) -> Route.Choose {
        go ? .next(5) : .stay
    }

    @Transition(on: Input.step)
    fileprivate static func next(_ source: Beta, _ go: Bool, routed delta: Count) -> Done {
        Done(total: source.base + delta)
    }
    @Transition(on: Input.step)
    fileprivate static func stay(_ source: Beta, _ go: Bool) -> Beta { source }
    @Route(on: Input.step)
    fileprivate static func choose(_ source: Beta, _ go: Bool) -> Route.Choose {
        go ? .next(7) : .stay
    }
}

// MARK: - Tests

@Suite struct RoutedHandoffTests {
    private struct Unexpected: Error {}

    @Test func sortingStyleNonSendableRoutedComputesOncePerPrepareAcrossLocalOwnedAndObserved() throws {
        // 1. Local completion & input routing with distinct starts/emits and non-Sendable closure.
        let probe = SortingProbe(scriptedSteps: [
            .comparison(left: 2, right: 5, delta: 10),
            .comparison(left: 1, right: 9, delta: 3),
            .noChange,
            .finished(winner: 100, label: "sorted"),
        ])
        var local = SortingRoutedDemo.Local(.init(probe: probe, baseScore: 7))
        try local.send(.start(25))
        let startCommands = local.drainCommands(limit: 4).flatMap(\.commands)
        guard case .stepDelay(let work)? = startCommands.first else { throw Unexpected() }

        let delivered = local.deliver(work.succeeded("tick-1"))
        guard case .committed(let firstReceipt) = delivered else { throw Unexpected() }
        #expect(firstReceipt.edgeID == "ready.presentFirst")
        #expect(probe.readyRouteCalls == 1)
        #expect(probe.presentFirstCalls == 1)
        #expect(probe.finishFromReadyCalls == 0)
        #expect(probe.observedStepOutputs == ["tick-1"])
        #expect(probe.observedRequestInputs == [25])

        let firstEffects = local.drainCommands(limit: 4).flatMap(\.commands)
        #expect(firstEffects.count == 2)
        guard case .stepDelay(let nextDelay) = firstEffects[0],
            case .comparisonPresented(7) = firstEffects[1]
        else { throw Unexpected() }
        #expect(nextDelay.input == 26)

        // Input routing through Observed + commit: router computes once, nonchosen branches stay at 0.
        guard case .comparing(let observedComparing) = local.snapshot() else { throw Unexpected() }
        let prepared = observedComparing.routeChoice(true)
        #expect(probe.chooseRouteCalls == 1)
        #expect(probe.closureInvocations == 1)
        #expect(probe.advanceComparisonCalls == 1)
        #expect(probe.finishComparingCalls == 0)
        #expect(probe.stayComparingCalls == 0)
        guard case .committed(let secondReceipt) = local.commit(prepared) else { throw Unexpected() }
        #expect(secondReceipt.edgeID == "comparing.advanceComparison")
        let advEffects = local.drainCommands(limit: 4).flatMap(\.commands)
        guard case .comparisonPresented(10)? = advEffects.first else { throw Unexpected() }

        // Payloadless candidate branch (.stayComparing) runs without constructing routed payload.
        let stayReceipt = try local.send(.choose(false))
        #expect(stayReceipt.edgeID == "comparing.stayComparing")
        #expect(probe.chooseRouteCalls == 2)
        #expect(probe.closureInvocations == 2)
        #expect(probe.stayComparingCalls == 1)
        #expect(probe.advanceComparisonCalls == 1)
        #expect(probe.finishComparingCalls == 0)

        // Tuple-payload branch (.finishComparing) starts ReshuffleDelay and emits SortCompleted.
        let finishReceipt = try local.send(.choose(true))
        #expect(finishReceipt.edgeID == "comparing.finishComparing")
        #expect(probe.chooseRouteCalls == 3)
        #expect(probe.closureInvocations == 3)
        #expect(probe.finishComparingCalls == 1)
        guard case .finished(let finishedSnap) = local.snapshot() else { throw Unexpected() }
        #expect(finishedSnap.value.label == "sorted")
        // Score math: first resolve(true) -> 2 + 10 = 12; second closure delta=3+12 -> resolve(true) = 1+15 = 16;
        // winner = 100 + 16 = 116.
        #expect(finishedSnap.value.winner == 116)
        let finishEffects = local.drainCommands(limit: 4).flatMap(\.commands)
        #expect(finishEffects.count == 3)
        guard case .cancel = finishEffects[0],
            case .reshuffleDelay(let reshuffle) = finishEffects[1],
            case .sortCompleted("sorted") = finishEffects[2]
        else { throw Unexpected() }
        #expect(reshuffle.input == 116)

        // 2. Typed Owned API (completion + input) computes once and respects per-branch effects.
        let ownedProbe = SortingProbe(scriptedSteps: [.finished(winner: 0, label: "unused")])
        let ownedReady = SortingRoutedDemo.owned(.init(probe: ownedProbe, baseScore: 42))
        let request = SortingRoutedDemo.StepDelayRequest(input: 9)
        switch ownedReady.routeReadyStep("fast-finish", request: request) {
        case .finishFromReady(let change):
            #expect(ownedProbe.readyRouteCalls == 1)
            #expect(ownedProbe.finishFromReadyCalls == 1)
            #expect(ownedProbe.presentFirstCalls == 0)
            #expect(change.next.withValue { $0.winner } == 42)
            #expect(change.next.withValue { $0.label } == "ready:fast-finish")
            #expect(change.effects.count == 2)
        case .presentFirst:
            Issue.record("Expected finishFromReady branch")
        }
    }

    @Test func capacityRetryReusesPreparedRoutedCompletionWithoutRecomputingRouter() throws {
        let probe = SortingProbe(scriptedSteps: [.comparison(left: 4, right: 6, delta: 1)])
        var local = SortingRoutedDemo.Local(
            .init(probe: probe, baseScore: 0),
            configuration: try .init(commits: 1)
        )
        // Enqueue one command batch so the buffer (capacity 1) is full.
        try local.send(.start(10))
        guard case .stepDelay(let work)? = local.drainCommands(limit: 1).first?.commands.first else {
            throw Unexpected()
        }
        // Refill buffer to capacity 1 with an event-emitting self-loop so `work` stays active.
        try local.send(.ping)

        // Delivering now prepares once (router runs once, chosen branch runs once), then hits waitingForCapacity.
        let pending = local.deliver(work.succeeded("buffered"))
        guard case .pending(let pendingID, .waitingForCapacity) = pending else { throw Unexpected() }
        #expect(probe.readyRouteCalls == 1)
        #expect(probe.presentFirstCalls == 1)
        #expect(probe.finishFromReadyCalls == 0)

        // Drain the buffered batch and retry admission: must NOT re-run router or branch!
        _ = local.drainCommands(limit: 1)
        let retried = local.retryAdmission(id: pendingID)
        guard case .committed(let receipt) = retried else { throw Unexpected() }
        #expect(receipt.edgeID == "ready.presentFirst")
        #expect(probe.readyRouteCalls == 1)
        #expect(probe.presentFirstCalls == 1)
        #expect(probe.finishFromReadyCalls == 0)
    }

    @MainActor
    @Test func isolatedMainActorHostExecutesRoutedCompletionAndDistinctBranchEvents() async throws {
        let probe = SortingProbe(scriptedSteps: [
            .comparison(left: 3, right: 8, delta: 2),
            .finished(winner: 50, label: "host-done"),
        ])
        let host = SortingRoutedDemo.MainActorHost(
            .init(probe: probe, baseScore: 1),
            stepDelayDriver: { input in "delay-\(input)" },
            reshuffleDelayDriver: { _ in },
            onComparisonPresented: { value in probe.emittedEvents.append("presented:\(value)") },
            onSortCompleted: { label in probe.emittedEvents.append("completed:\(label)") }
        )
        let startReceipt = try host.send(.start(5))
        #expect(await host.flush(through: startReceipt) == .processed)

        // Wait deterministically via distinctSnapshots for Comparing (driven by StepDelay completion router).
        let reachedComparing = try host.distinctSnapshots { snapshot -> Bool in
            if case .comparing = snapshot { true } else { false }
        }
        for await isComparing in reachedComparing where isComparing {
            break
        }
        reachedComparing.cancel()
        #expect(probe.readyRouteCalls == 1)
        #expect(probe.presentFirstCalls == 1)
        #expect(probe.finishFromReadyCalls == 0)

        let finishReceipt = try host.send(.choose(false))
        #expect(await host.flush(through: finishReceipt) == .processed)
        #expect(probe.chooseRouteCalls == 1)
        #expect(probe.finishComparingCalls == 1)
        #expect(probe.advanceComparisonCalls == 0)
        #expect(probe.emittedEvents.contains("presented:11"))
        #expect(probe.emittedEvents.contains("completed:host-done"))
        await host.shutdown()
    }

    @Test func throwingRoutedInputAndCompletionPreserveStateAndSupportReconciliation() async throws {
        let counters = SharedCounters()

        // 1. Throwing input router on Owned preserves state and never runs any candidate.
        let ownedForbidden = ThrowingRoutedFlow.owned(
            .init(destination: .forbidden, allowCompletion: false, counters: counters)
        )
        switch ownedForbidden.resolvePending([1, 2]) {
        case .rejected(.forbiddenDestination, let unchanged):
            #expect(unchanged.withValue { $0.destination } == .forbidden)
            let snap = counters.snapshot
            #expect(snap.inputRouteCalls == 1)
            #expect(snap.toBrowsingCalls == 0)
            #expect(snap.toSheetCalls == 0)
        default:
            Issue.record("Expected router rejection preserving Owned state")
        }

        // 2. Router selects candidate that throws: router runs once, chosen branch runs once, other branch 0.
        let ownedEmptySheet = ThrowingRoutedFlow.owned(
            .init(destination: .sheet(1, ""), allowCompletion: false, counters: counters)
        )
        switch ownedEmptySheet.resolvePending([1]) {
        case .resolveToSheet(.rejected(.emptySheet, let unchanged)):
            #expect(unchanged.withValue { $0.destination } == .sheet(1, ""))
            let snap = counters.snapshot
            #expect(snap.inputRouteCalls == 2)
            #expect(snap.toSheetCalls == 1)
            #expect(snap.toBrowsingCalls == 0)
        default:
            Issue.record("Expected candidate rejection preserving Owned state")
        }

        // 3. Local & Shared send preserve state on router throw and candidate throw.
        let localCounters = SharedCounters()
        var local = ThrowingRoutedFlow.Local(
            .init(destination: .sheet(5, ""), allowCompletion: false, counters: localCounters)
        )
        do {
            try local.send(.process([]))
            Issue.record("Expected router throw")
        } catch {
            guard case .preparation(.resolvePending(.unavailable(5))) = error else { throw Unexpected() }
        }
        guard case .pending = local.snapshot() else { throw Unexpected() }
        #expect(localCounters.snapshot.inputRouteCalls == 1)
        #expect(localCounters.snapshot.toSheetCalls == 0)
        #expect(localCounters.snapshot.toBrowsingCalls == 0)

        do {
            try local.send(.process([5]))
            Issue.record("Expected candidate throw")
        } catch {
            guard case .preparation(.resolveToSheet(.emptySheet)) = error else { throw Unexpected() }
        }
        guard case .pending = local.snapshot() else { throw Unexpected() }
        #expect(localCounters.snapshot.inputRouteCalls == 2)
        #expect(localCounters.snapshot.toSheetCalls == 1)
        #expect(localCounters.snapshot.toBrowsingCalls == 0)

        // 4. Completion router throw retains outcome; duplicate deliver does not re-run; reconcile runs fresh prepare.
        try local.send(.beginFetch(42))
        guard case .fetch(let work)? = local.drainCommands(limit: 1).first?.commands.first else {
            throw Unexpected()
        }
        let refused = local.deliver(work.succeeded(7))
        guard case .refused(let pendingID, .routeFetch(.notReadyToAccept), routeID: "pending.routeFetch") = refused
        else { throw Unexpected() }
        #expect(localCounters.snapshot.completionRouteCalls == 1)
        #expect(localCounters.snapshot.acceptResultCalls == 0)
        #expect(localCounters.snapshot.fallbackResultCalls == 0)

        // Duplicate delivery and retryAdmission do not re-run the router.
        guard case .pending(pendingID, .reconciliationRequired) = local.deliver(work.succeeded(7)) else {
            throw Unexpected()
        }
        guard case .pending(pendingID, .reconciliationRequired) = local.retryAdmission(id: pendingID) else {
            throw Unexpected()
        }
        #expect(localCounters.snapshot.completionRouteCalls == 1)

        // Enable completion and reconcile: runs fresh prepare once and commits with routed string + request.
        try local.send(.allowCompletion)
        let reconciled = local.reconcile(id: pendingID)
        guard case .committed(let receipt) = reconciled else { throw Unexpected() }
        #expect(receipt.edgeID == "pending.acceptResult")
        #expect(localCounters.snapshot.completionRouteCalls == 2)
        #expect(localCounters.snapshot.acceptResultCalls == 1)
        #expect(localCounters.snapshot.fallbackResultCalls == 0)
        guard case .browsing(let browsing) = local.snapshot() else { throw Unexpected() }
        #expect(browsing.value == .init(selectedID: 42, note: "req=42,out=7"))

        // 5. Shared managed owner preserves state on throwing routed input and commits valid routed input.
        let sharedCounters = SharedCounters()
        let shared = ThrowingRoutedFlow.Shared(
            .init(destination: .list(9), allowCompletion: true, counters: sharedCounters),
            fetchDriver: { $0 * 2 },
            completionPolicy: .manual(onReconciliationRequired: { _ in })
        )
        do {
            try shared.send(.process([1]))
            Issue.record("Expected Shared send to throw unavailable")
        } catch {
            guard case .preparation(.resolvePending(.unavailable(9))) = error else { throw Unexpected() }
        }
        guard case .pending = shared.snapshot() else { throw Unexpected() }
        let committed = try shared.send(.process([9]))
        #expect(committed.edgeID == "pending.resolveToBrowsing")
        guard case .browsing(let sharedBrowsing) = shared.snapshot() else { throw Unexpected() }
        #expect(sharedBrowsing.value == .init(selectedID: 9, note: "browsing"))
        #expect(sharedCounters.snapshot.inputRouteCalls == 2)
        #expect(sharedCounters.snapshot.toBrowsingCalls == 1)
        #expect(sharedCounters.snapshot.toSheetCalls == 0)
        await shared.shutdown()
    }

    @Test func moveOnlyRoutedHandleRespectsConsumingBorrowingAndSingleDeinit() throws {
        // Owned: consuming, borrowing, and payloadless skip.
        let ownedTracker = HandleTracker()
        switch MoveOnlyRoutedFlow.owned(.init(tracker: ownedTracker)).routeOpen(.take(11)) {
        case .take(let taken): #expect(taken.withValue { $0.fd } == 11)
        default: Issue.record("Expected .take")
        }
        switch MoveOnlyRoutedFlow.owned(.init(tracker: ownedTracker)).routeOpen(.inspect(22)) {
        case .inspect(let inspected): #expect(inspected.withValue { $0.fd } == 22)
        default: Issue.record("Expected .inspect")
        }
        switch MoveOnlyRoutedFlow.owned(.init(tracker: ownedTracker)).routeOpen(.skip) {
        case .skip: break
        default: Issue.record("Expected .skip")
        }
        #expect(ownedTracker.routeCalls == 3)
        #expect(ownedTracker.takeCalls == 1)
        #expect(ownedTracker.inspectCalls == 1)
        #expect(ownedTracker.skipCalls == 1)
        #expect(ownedTracker.deinitedIDs == [11, 22])

        // Observed + Local.commit and Local.send.
        let localTracker = HandleTracker()
        var takeLocal = MoveOnlyRoutedFlow.Local(.init(tracker: localTracker))
        guard case .open(let observedOpen) = takeLocal.snapshot() else { throw Unexpected() }
        let prepared = observedOpen.routeOpen(.take(33))
        guard case .committed(let takeReceipt) = takeLocal.commit(prepared),
            case .taken(let takenSnap) = takeLocal.snapshot()
        else { throw Unexpected() }
        #expect(takeReceipt.edgeID == "open.take")
        #expect(takenSnap.value.fd == 33)

        var inspectLocal = MoveOnlyRoutedFlow.Local(.init(tracker: localTracker))
        let inspectReceipt = try inspectLocal.send(.run(.inspect(44)))
        guard case .inspected(let inspectedSnap) = inspectLocal.snapshot() else { throw Unexpected() }
        #expect(inspectReceipt.edgeID == "open.inspect")
        #expect(inspectedSnap.value.fd == 44)
        #expect(localTracker.deinitedIDs == [33, 44])
    }

    @Test func sameRouterNameAcrossPhasesSupportsDistinctAndSharedRoutedShapes() throws {
        // Distinct shapes: Alpha routes Int, Beta routes String.
        var split = SplitChoiceFlow.Local(.init(seed: 3))
        let r1 = try split.send(.step(true))
        #expect(r1.edgeID == "alpha.advance")
        let r2 = try split.send(.step(true))
        #expect(r2.edgeID == "beta.advance")
        guard case .done(let splitDone) = split.snapshot() else { throw Unexpected() }
        #expect(splitDone.value == .init(summary: "a:33->finished"))

        // Owned on SplitChoiceFlow.
        switch SplitChoiceFlow.owned(.init(seed: 4)).choose(true) {
        case .advance(let beta):
            switch beta.choose(true) {
            case .advance(let done): #expect(done.withValue { $0 } == .init(summary: "a:44->finished"))
            case .stay: Issue.record("Expected beta.advance")
            }
        case .stay: Issue.record("Expected alpha.advance")
        }

        // Compatible shapes via alias: Alpha and Beta share Route.Choose.
        var shared = SharedChoiceAliasFlow.Local(.init(base: 10))
        try shared.send(.step(true))
        try shared.send(.step(true))
        guard case .done(let sharedDone) = shared.snapshot() else { throw Unexpected() }
        #expect(sharedDone.value == .init(total: 22))
    }
}
