import StateMachine
import StateMachineExamples
import StateMachineTesting
import Testing
import os

/// Collects the lines a transfer host logs, in the order its event handler receives them.
private final class LogLines: Sendable {
    private let state = OSAllocatedUnfairLock<[String]>(initialState: [])
    var lines: [String] { state.withLock { $0 } }
    func record(_ line: String) { state.withLock { $0.append(line) } }
}

/// A key whose equality runs a probe, which may read the driver that compares it.
private struct ProbingKey: Hashable, Sendable {
    static let probe = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    let id: Int
    static func == (lhs: ProbingKey, rhs: ProbingKey) -> Bool {
        let probe = Self.probe.withLock { $0 }
        probe?()
        return lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A key whose equality compares only `id`, and runs a probe that sees which two calls it compares.
private struct OrderedKey: Hashable, Sendable {
    static let probe = OSAllocatedUnfairLock<(@Sendable (OrderedKey, OrderedKey) -> Void)?>(initialState: nil)
    let id: Int
    let tag: String
    static func == (lhs: OrderedKey, rhs: OrderedKey) -> Bool {
        let probe = Self.probe.withLock { $0 }
        probe?(lhs, rhs)
        return lhs.id == rhs.id
    }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Records what a probe observes once, however many threads reach it.
private final class Observed: Sendable {
    private let state = OSAllocatedUnfairLock<Int?>(initialState: nil)
    var value: Int? { state.withLock { $0 } }
    func record(_ value: Int) { state.withLock { $0 = $0 ?? value } }
}

/// Runs a body once, however many threads reach it.
private final class Once: Sendable {
    private let done = OSAllocatedUnfairLock(initialState: false)
    func run(_ body: () -> Void) {
        guard
            done.withLock({ done in
                defer { done = true }
                return !done
            })
        else { return }
        body()
    }
}

/// An actor that owns a confined note host whose values are not `Sendable`, and its controlled driver.
private actor NoteDesk {
    let save = IsolatedControlledDriver<NoteDesk, GeneratedNote.Draft, GeneratedNote.Saved, Never>()
    private(set) var host: GeneratedNote.IsolatedHost<NoteDesk>!

    init() async {
        host = GeneratedNote.IsolatedHost(
            GeneratedNote.Draft(text: "kept"),
            isolation: self,
            saveDriver: { desk, draft in await desk.save.run(desk, draft) }
        )
    }

    /// Saves, finishes the call with the draft's text, and returns the text the owner then holds.
    func saveAndFinish() async throws -> String {
        var snapshots = try host.snapshots()
        try host.send(.save)
        let call = try await save.nextStarted()
        // The call's methods take the owning actor by default, which an autoclosure such as
        // `#expect`'s does not pass, so the test reads them first.
        let text = call.input().text
        #expect(text == "kept")
        let succeeded = call.succeed(GeneratedNote.Saved(text: text + " saved"))
        let again = call.succeed(GeneratedNote.Saved(text: "twice"))
        #expect(succeeded && !again)
        #expect(call.isFinished)
        while let snapshot = await snapshots.next() {
            guard case .saved(let saved) = snapshot else { continue }
            return saved.value.text
        }
        return ""
    }

    /// Waits for a save before the host starts one, then finishes it.
    func waitThenSave() async throws -> (started: Int, text: String) {
        let waiting = Task {
            let call = try await save.nextStarted(isolation: self)
            let text = call.input(isolation: self).text
            call.succeed(GeneratedNote.Saved(text: text), isolation: self)
            return text
        }
        try host.send(.edit("waited"))
        try host.send(.save)
        let text = try await waiting.value
        return (save.startedCount, text)
    }

    /// Starts a save, abandons it by editing, and finishes the cancelled call late.
    func abandonSave() async throws -> (cancelled: Bool, text: String, running: Int) {
        try host.send(.save)
        let call = try await save.nextStarted(isolation: self)
        let receipt = try host.send(.edit("abandoned"))
        try await call.waitForCancellation(isolation: self)
        let cancelled = call.isCancelled
        call.succeed(GeneratedNote.Saved(text: "late"))
        _ = await host.shutdown()
        guard case .draft(let draft) = host.snapshot() else { return (cancelled, "", host.runningCount()) }
        #expect(host.snapshot().revision >= receipt.revision)
        return (cancelled, draft.value.text, host.runningCount())
    }

    /// Waits for a call that never starts, in a task cancelled before it can.
    func cancelledWait() async -> String? {
        let waiting = Task {
            _ = try await save.nextStarted(isolation: self)
            return save.startedCount
        }
        waiting.cancel()
        guard case .failure(let error) = await waiting.result, let failure = error as? StateMachineTestFailure
        else { return nil }
        return failure.message
    }

    var startedSaves: Int { save.startedCount }
}

/// Counts what a probe observes.
private final class ProbeReadings: Sendable {
    private let state = OSAllocatedUnfairLock<[Int]>(initialState: [])
    var readings: [Int] { state.withLock { $0 } }
    func record(_ reading: Int) { state.withLock { $0.append(reading) } }
}

/// An actor that owns a confined transfer host whose keyed driver receives it.
private actor TransferDesk {
    private(set) var host: GeneratedTransfers.IsolatedHost<TransferDesk>!

    init(download: KeyedControlledDriver<Int, String, String, GeneratedTransfers.TransferFailure>) async {
        host = GeneratedTransfers.IsolatedHost(isolation: self, downloadDriver: download.run, onLogged: { _, _ in })
    }

    func send(_ input: GeneratedTransfers.Input) throws -> UInt64 { try host.send(input).revision }

    /// Returns the files once the owner holds the download of `id`.
    func files(holding id: Int) async throws -> [Int: String] {
        for await snapshot in try host.snapshots() {
            guard case .browsing(let browsing) = snapshot, browsing.value.files[id] != nil else { continue }
            return browsing.value.files
        }
        return [:]
    }

    func shutdown() async -> Bool { await host.shutdown() == .quiescent }
}

@Suite(.timeLimit(.minutes(1))) struct ControlledDriverTests {
    private static func request(_ user: String) throws -> ProfileRequest {
        try ProfileRequest(userID: UserID(user))
    }

    @Test func aFallibleDriverReturnsTheResultTheTestChooses() async throws {
        let fetch = ControlledDriver<ProfileRequest, Profile, ProfileFailure>()
        let audit = ControlledDriver<String, Profile, ProfileFailure>()
        let user = try UserID("driver")
        let host = GeneratedProfile.ActorHost(
            GeneratedProfile.Idle(userID: user),
            fetchDriver: fetch.run,
            auditDriver: audit.run
        )
        let snapshots = try await host.snapshots()
        try await host.send(.load(Self.request("driver")))
        let first = try await fetch.nextStarted()
        #expect(first.input == (try Self.request("driver")))
        #expect(!first.isFinished)
        #expect(first.fail(.unavailable))
        #expect(!first.succeed(Profile(userID: user, name: "Too late")))
        var names: [String] = []
        for await snapshot in snapshots {
            switch snapshot {
            case .failed:
                try await host.send(.retry)
                try await fetch.nextStarted().succeed(Profile(userID: user, name: "Driven"))
            case .loaded(let loaded):
                names.append(loaded.value.profile.name)
            case .idle, .loading: continue
            }
            if !names.isEmpty { break }
        }
        #expect(names == ["Driven"])
        #expect(fetch.startedCount == 2)
        #expect(audit.startedCount == 0)
        #expect(await host.shutdown() == .quiescent)
    }

    @Test func aCallHeldPastCancellationDeliversALateResultThatTheHostDiscards() async throws {
        let fetch = ControlledDriver<ProfileRequest, Profile, ProfileFailure>()
        let user = try UserID("late")
        let host = GeneratedProfile.Shared(
            GeneratedProfile.Idle(userID: user),
            fetchDriver: fetch.run,
            auditDriver: { _ in .failure(.unavailable) }
        )
        try host.send(.load(Self.request("late")))
        let call = try await fetch.nextStarted()
        #expect(!call.isCancelled)
        let cancelled = try host.send(.cancel)
        try await call.waitForCancellation()
        #expect(call.isCancelled)
        // The driver ignores cancellation and keeps running until the test finishes it.
        #expect(host.runningCount == 1)
        #expect(call.succeed(Profile(userID: user, name: "Late")))
        #expect(await host.shutdown() == .quiescent)
        guard case .idle = host.snapshot() else {
            Issue.record("the late result moved the owner out of idle")
            return
        }
        #expect(host.snapshot().revision == cancelled.revision + 1)
    }

    @Test func anInfallibleDriverWithoutInputReturnsItsOutputDirectly() async throws {
        let measure = ControlledDriver<Void, Int, Never>()
        let host = GeneratedScreen.Shared(measureDriver: measure.run, completionPolicy: .manual)
        let readings = try host.snapshots { snapshot -> [Int] in
            if case .ready(let ready) = snapshot { ready.value.readings } else { [] }
        }
        try host.send(.measure)
        let call = try await measure.nextStarted()
        call.succeed(7)
        for await values in readings where values == [7] { break }
        #expect(await host.shutdown() == .quiescent)
    }

    @Test func aKeyedDriverReportsEachKeyAndTheEventHandlerRunsInOrder() async throws {
        let download = KeyedControlledDriver<Int, String, String, GeneratedTransfers.TransferFailure>()
        let log = LogLines()
        let host = GeneratedTransfers.Shared(downloadDriver: download.run, onLogged: log.record)
        let snapshots = try host.snapshots()
        try host.send(.download(1))
        try host.send(.download(2))
        // Each execution runs in its own task, so the test takes each key's call by its key.
        let second = try await download.nextStarted(for: 2)
        let first = try await download.nextStarted(for: 1)
        #expect([first.key, second.key] == [1, 2])
        #expect([first.input, second.input] == ["file-1", "file-2"])
        try host.send(.cancel(1))
        try await first.waitForCancellation()
        #expect(!second.isCancelled)
        second.succeed("two")
        first.succeed("stale")
        for await snapshot in snapshots {
            guard case .browsing(let browsing) = snapshot, !browsing.value.files.isEmpty else { continue }
            #expect(browsing.value.files == [2: "two"])
            break
        }
        #expect(await host.shutdown() == .quiescent)
        #expect(log.lines == ["download 1", "download 2", "downloaded 2"])
    }

    @Test func waitingForOneKeyLeavesOtherKeysCallsQueuedInStartOrder() async throws {
        let download = KeyedControlledDriver<Int, String, String, GeneratedTransfers.TransferFailure>()
        let host = GeneratedTransfers.Shared(downloadDriver: download.run, onLogged: { _ in })
        // A wait for key 3 registered before any call starts receives only key 3's call.
        let waiting = Task { try await download.nextStarted(for: 3) }
        try host.send(.download(1))
        let first = try await download.nextStarted(for: 1)
        #expect(first.key == 1)
        try host.send(.download(2))
        try host.send(.download(3))
        let third = try await waiting.value
        #expect(third.key == 3)
        #expect(third.input == "file-3")
        // The call for key 2 stayed queued for the next wait of any key.
        let second = try await download.nextStarted()
        #expect(second.key == 2)
        #expect(download.startedCount == 3)
        for call in [first, second, third] { call.succeed("done") }
        #expect(await host.shutdown() == .quiescent)
    }

    @Test func waitingForAKeyThatNeverStartsFailsWhenTheWaitIsCancelled() async throws {
        let download = KeyedControlledDriver<Int, String, String, GeneratedTransfers.TransferFailure>()
        let waiting = Task { _ = try await download.nextStarted(for: 9) }
        waiting.cancel()
        guard case .failure(let error) = await waiting.result, let failure = error as? StateMachineTestFailure else {
            Issue.record("the wait returned a call that never started")
            return
        }
        #expect(failure.message.contains("a call for 9"))
    }

    @Test func keyEqualityRunsOutsideTheDriversBookkeeping() async throws {
        let driver = KeyedControlledDriver<ProbingKey, Void, Void, Never>()
        let readings = ProbeReadings()
        ProbingKey.probe.withLock { $0 = { readings.record(driver.startedCount) } }
        defer { ProbingKey.probe.withLock { $0 = nil } }
        // Each wait compares keys both when it looks for a queued call and when a call starts.
        let waiting = Task { try await driver.nextStarted(for: ProbingKey(id: 2)) }
        let one = Task { await driver.run(ProbingKey(id: 1)) }
        let first = try await driver.nextStarted(for: ProbingKey(id: 1))
        let two = Task { await driver.run(ProbingKey(id: 2)) }
        let second = try await waiting.value
        #expect(first.key.id == 1)
        #expect(second.key.id == 2)
        #expect(first.succeed())
        #expect(second.succeed())
        await one.value
        await two.value
        #expect(!readings.readings.isEmpty)
        #expect(driver.startedCount == 2)
    }

    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    @Test func aKeyedWaitReceivesMatchingCallsInStartOrderWhileItsEqualityRuns() async throws {
        let driver = KeyedControlledDriver<OrderedKey, Void, Void, Never>()
        let once = Once()
        let startedDuringEquality = Observed()
        // While the first call's key is being compared, a second call for the same key starts on the
        // comparing thread itself: an immediate task runs the driver until it suspends, which offers
        // the call before the comparison returns. Whichever of the wait and the first call arrived
        // later runs the comparison; either way the second call must not overtake the first.
        OrderedKey.probe.withLock {
            $0 = { lhs, rhs in
                guard [lhs.tag, rhs.tag].contains("first") else { return }
                once.run {
                    Task.immediate { await driver.run(OrderedKey(id: 1, tag: "second")) }
                    startedDuringEquality.record(driver.startedCount)
                }
            }
        }
        defer { OrderedKey.probe.withLock { $0 = nil } }
        let waiting = Task { try await driver.nextStarted(for: OrderedKey(id: 1, tag: "wait")) }
        let first = Task { await driver.run(OrderedKey(id: 1, tag: "first")) }
        let earlier = try await waiting.value
        let later = try await driver.nextStarted(for: OrderedKey(id: 1, tag: "wait"))
        #expect(startedDuringEquality.value == 2)
        #expect(earlier.key.tag == "first")
        #expect(later.key.tag == "second")
        #expect(earlier.succeed())
        #expect(later.succeed())
        await first.value
        #expect(driver.startedCount == 2)
    }

    @Test func aWaitWhoseTaskIsAlreadyCancelledFailsEvenWhenTheCallWasCancelledEarlier() async throws {
        let fetch = ControlledDriver<Int, Int, Never>()
        let running = Task { await fetch.run(1) }
        let call = try await fetch.nextStarted()
        running.cancel()
        #expect(call.isCancelled)
        // A cancelled waiting task ends its wait at once, as a wait for a call does.
        let waiting = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await call.waitForCancellation()
                return true
            } catch {
                return false
            }
        }
        #expect(await waiting.value == false)
        // A wait in a live task still sees the cancellation that already happened.
        try await call.waitForCancellation()
        #expect(call.succeed(2))
        #expect(await running.value == 2)
    }

    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    @Test(arguments: [true, false])
    func aCancellationWaitReportsWhicheverCancellationCameFirst(waitingTaskFirst: Bool) async throws {
        let fetch = ControlledDriver<Int, Int, Never>()
        let running = Task { await fetch.run(1) }
        let call = try await fetch.nextStarted()
        // An immediate task runs until the wait suspends, so both cancellations reach an installed wait.
        let waiting = Task.immediate { () -> Bool in
            do {
                try await call.waitForCancellation()
                return true
            } catch {
                return false
            }
        }
        if waitingTaskFirst {
            waiting.cancel()
            running.cancel()
        } else {
            running.cancel()
            waiting.cancel()
        }
        #expect(await waiting.value == !waitingTaskFirst)
        #expect(call.succeed(2))
        #expect(await running.value == 2)
    }

    @Test func anIsolatedDriverKeepsNonSendableValuesOnItsActor() async throws {
        let desk = await NoteDesk()
        #expect(try await desk.saveAndFinish() == "kept saved")
        #expect(await desk.startedSaves == 1)
    }

    @Test func anIsolatedWaitThatBeginsBeforeTheStartReceivesIt() async throws {
        let desk = await NoteDesk()
        let result = try await desk.waitThenSave()
        #expect(result.started == 1)
        #expect(result.text == "waited")
    }

    @Test func anIsolatedCallHeldPastCancellationDeliversALateResultThatTheHostDiscards() async throws {
        let desk = await NoteDesk()
        let result = try await desk.abandonSave()
        #expect(result.cancelled)
        #expect(result.text == "abandoned")
        #expect(result.running == 0)
    }

    @Test func anIsolatedWaitForACallThatNeverStartsFailsWhenTheWaitIsCancelled() async {
        let desk = await NoteDesk()
        let message = await desk.cancelledWait()
        #expect(message?.contains("cancelled") == true)
    }

    @Test func aKeyedDriverReceivesTheActorThatConfinesAnIsolatedHost() async throws {
        let download = KeyedControlledDriver<Int, String, String, GeneratedTransfers.TransferFailure>()
        let desk = await TransferDesk(download: download)
        _ = try await desk.send(.download(3))
        let call = try await download.nextStarted()
        #expect(call.key == 3)
        call.fail(.unavailable)
        _ = try await desk.send(.download(4))
        try await download.nextStarted().succeed("four")
        #expect(try await desk.files(holding: 4) == [4: "four"])
        #expect(await desk.shutdown())
    }

    @MainActor @Test func aMainActorDriverKeepsNonSendableValuesOnTheMainActor() async throws {
        let save = MainActorControlledDriver<GeneratedNote.Draft, GeneratedNote.Saved, Never>()
        let host = GeneratedNote.MainActorHost(GeneratedNote.Draft(text: "kept"), saveDriver: save.run)
        var snapshots = try host.snapshots()
        try host.send(.save)
        let call = try await save.nextStarted()
        #expect(call.input.text == "kept")
        #expect(call.succeed(GeneratedNote.Saved(text: call.input.text + " saved")))
        #expect(!call.succeed(GeneratedNote.Saved(text: "twice")))
        while let snapshot = await snapshots.next() {
            guard case .saved(let saved) = snapshot else { continue }
            #expect(saved.value.text == "kept saved")
            break
        }
        await host.shutdown()
        #expect(host.runningCount == 0)
    }

    // The example in the driver's documentation.
    @MainActor @Test func aKeyedMainActorDriverIsTheDriverOfAMainActorHost() async throws {
        let download = KeyedMainActorControlledDriver<Int, String, String, GeneratedTransfers.TransferFailure>()
        let host = GeneratedTransfers.MainActorHost(downloadDriver: download.run, onLogged: { _ in })
        let snapshots = try host.snapshots()
        try host.send(.download(1))
        try host.send(.download(2))
        let second = try await download.nextStarted(for: 2)
        second.succeed("contents of \(second.input)")
        let first = try await download.nextStarted(for: 1)
        #expect(first.input == "file-1")
        first.fail(.unavailable)
        for await snapshot in snapshots {
            guard case .browsing(let browsing) = snapshot, !browsing.value.files.isEmpty,
                !browsing.value.failures.isEmpty
            else { continue }
            #expect(browsing.value.files == [2: "contents of file-2"])
            #expect(browsing.value.failures == [1])
            break
        }
        await host.shutdown()
    }

    @Test func waitingForACallThatNeverStartsFailsWhenTheWaitIsCancelled() async throws {
        let fetch = ControlledDriver<ProfileRequest, Profile, ProfileFailure>()
        let waiting = Task { _ = try await fetch.nextStarted() }
        waiting.cancel()
        let result = await waiting.result
        guard case .failure(let error) = result, let failure = error as? StateMachineTestFailure else {
            Issue.record("the wait returned a call that never started")
            return
        }
        #expect(failure.fileID.hasSuffix("ControlledDriverTests.swift"))
        #expect(failure.message.contains("cancelled"))
        #expect(fetch.startedCount == 0)
    }
}

/// Pauses one task at a point the test chooses, ignoring that task's cancellation, until the test
/// releases it.
private final class Pause: Sendable {
    private struct State: Sendable {
        var reached = false
        var released = false
        var observer: CheckedContinuation<Void, Never>?
        var paused: CheckedContinuation<Void, Never>?
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Called by the paused task: reports arrival and waits for the release.
    func pause() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let (observer, released) = state.withLock { state in
                state.reached = true
                let observer = state.observer
                state.observer = nil
                if !state.released { state.paused = continuation }
                return (observer, state.released)
            }
            observer?.resume()
            if released { continuation.resume() }
        }
    }
    /// Returns once the paused task has arrived.
    func arrival() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let reached = state.withLock { state in
                if !state.reached { state.observer = continuation }
                return state.reached
            }
            if reached { continuation.resume() }
        }
    }
    func release() {
        let paused = state.withLock { state in
            state.released = true
            let paused = state.paused
            state.paused = nil
            return paused
        }
        paused?.resume()
    }
}

@Suite(.timeLimit(.minutes(1))) struct CancellationArbitrationTests {
    // The waiting task is cancelled, and then the driver call, both while the wait has begun but not
    // yet armed its cancellation handler. The waiting task's cancellation happened first, so the wait
    // reports it.
    @Test func aWaitingTaskCancelledBeforeItsHandlerIsArmedReportsItsOwnCancellationFirst() async {
        let pause = Pause()
        let signal = CancellationSignal(beforeArming: { await pause.pause() })
        let waiting = Task { await signal.wait() }
        await pause.arrival()
        waiting.cancel()
        signal.cancel()
        pause.release()
        #expect(await waiting.value == false)
    }

    // Both cancellations happen before the wait begins, the driver call's first. A wait that begins in
    // a cancelled task reports that task's cancellation, whatever came before it.
    @Test func aWaitThatBeginsAfterBothCancellationsReportsItsOwnTask() async {
        let pause = Pause()
        let signal = CancellationSignal(beforeArming: { await pause.pause() })
        let waiting = Task { await signal.wait() }
        await pause.arrival()
        signal.cancel()
        waiting.cancel()
        pause.release()
        #expect(await waiting.value == false)
    }

    // Only the driver call is cancelled before the wait begins, so the wait returns at once.
    @Test func aWaitThatBeginsAfterTheDriverCallsCancellationReportsIt() async {
        let pause = Pause()
        let signal = CancellationSignal(beforeArming: { await pause.pause() })
        let waiting = Task { await signal.wait() }
        await pause.arrival()
        signal.cancel()
        pause.release()
        #expect(await waiting.value == true)
    }

    // The wait has begun when the driver call is cancelled, which answers it at once; the waiting
    // task's cancellation afterward finds it answered.
    @Test func aWaitAnsweredByTheDriverCallKeepsThatAnswerWhenItsTaskIsCancelled() async {
        let pause = Pause()
        let signal = CancellationSignal(afterBeginning: { await pause.pause() })
        let waiting = Task { await signal.wait() }
        await pause.arrival()
        signal.cancel()
        #expect(signal.isCancelled)
        waiting.cancel()
        pause.release()
        #expect(await waiting.value == true)
    }

    // The driver call was cancelled before the wait began, so beginning answers it; the waiting
    // task's cancellation right after that cannot replace the answer.
    @Test func aWaitThatBeganAfterTheDriverCallsCancellationKeepsItWhenItsTaskIsCancelled() async {
        let pause = Pause()
        let signal = CancellationSignal(afterBeginning: { await pause.pause() })
        signal.cancel()
        let waiting = Task { await signal.wait() }
        await pause.arrival()
        waiting.cancel()
        pause.release()
        #expect(await waiting.value == true)
    }

    // The waiting task is cancelled after the wait began and before the driver call is; its own
    // cancellation came first.
    @Test func aBegunWaitWhoseTaskIsCancelledFirstReportsItsTask() async {
        let pause = Pause()
        let signal = CancellationSignal(afterBeginning: { await pause.pause() })
        let waiting = Task { await signal.wait() }
        await pause.arrival()
        waiting.cancel()
        signal.cancel()
        pause.release()
        #expect(await waiting.value == false)
    }

    // A task that is already cancelled when it begins to wait reports its own cancellation, even after
    // the driver call's.
    @Test func aWaitThatBeginsInACancelledTaskReportsItsOwnCancellation() async {
        let signal = CancellationSignal()
        signal.cancel()
        let waiting = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await signal.wait()
        }
        #expect(await waiting.value == false)
    }
}
