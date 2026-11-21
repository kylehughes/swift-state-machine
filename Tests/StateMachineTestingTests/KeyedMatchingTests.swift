import StateMachineTesting
import Testing
import os

/// Runs an action once, the first time a key that carries it is compared.
private final class CompareHook: Sendable {
    private let action: OSAllocatedUnfairLock<(@Sendable () -> Void)?>
    init(_ action: @escaping @Sendable () -> Void) { self.action = OSAllocatedUnfairLock(initialState: action) }
    func fire() {
        let action = action.withLock { action in
            defer { action = nil }
            return action
        }
        action?()
    }
}

/// A key whose equality runs test code, as a key type of the app's own may.
private struct ProbeKey: Hashable, Sendable, CustomStringConvertible {
    let value: Int
    let hook: CompareHook?

    init(_ value: Int, onCompare hook: CompareHook? = nil) {
        self.value = value
        self.hook = hook
    }

    var description: String { String(value) }
    static func == (lhs: ProbeKey, rhs: ProbeKey) -> Bool {
        lhs.hook?.fire()
        rhs.hook?.fire()
        return lhs.value == rhs.value
    }
    func hash(into hasher: inout Hasher) { hasher.combine(value) }
}

/// A task that a comparison cancels, stored before any comparison can run.
private final class CancellableWait: Sendable {
    private let task = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    func store(_ task: Task<Void, Never>) { self.task.withLock { $0 = task } }
    func cancel() { task.withLock { $0 }?.cancel() }
}

/// The call an inner wait received, kept on the main actor.
@MainActor private final class Received<Call> {
    var call: Call?
    var failed = false
    var task: Task<Void, Never>?
}

private typealias IsolatedOpen = KeyedIsolatedControlledDriver<MainActor, ProbeKey, String, String, Never>

/// Keeps a confined driver on the main actor, so a comparison hook can reach it there.
@MainActor private final class DriverBox {
    let open = IsolatedOpen()
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct IsolatedKeyedMatchingTests {
    // Calls for keys 1 and 2 are queued. While the wait for key 1 compares the first call's key, that
    // comparison starts an unfiltered wait on the same actor. The wait for key 1 still receives key
    // 1's call, and the unfiltered wait, which arrived during the comparison, receives key 2's.
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    @Test func aWaitStartedDuringAComparisonDoesNotTakeTheComparedCall() async throws {
        let box = DriverBox()
        let open = box.open
        let one = Task.immediate { @MainActor in await open.run(MainActor.shared, ProbeKey(1), "one") }
        let two = Task.immediate { @MainActor in await open.run(MainActor.shared, ProbeKey(2), "two") }
        let inner = Received<IsolatedOpen.Call>()
        let hook = CompareHook {
            MainActor.assumeIsolated {
                inner.task = Task.immediate { @MainActor in inner.call = try? await box.open.nextStarted() }
            }
        }
        let call = try await open.nextStarted(for: ProbeKey(1, onCompare: hook))
        let input = call.input()
        #expect(input == "one")
        await inner.task?.value
        let other = try #require(inner.call)
        let otherInput = other.input()
        #expect(otherInput == "two")
        call.succeed("first")
        other.succeed("second")
        #expect(await one.value == "first")
        #expect(await two.value == "second")
    }

    // The only queued call is key 1's, and the comparison starts an unfiltered wait. That wait finds
    // nothing left, so it waits for the next call.
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    @Test func aWaitStartedDuringTheOnlyCallsComparisonWaitsForTheNextCall() async throws {
        let box = DriverBox()
        let open = box.open
        let one = Task.immediate { @MainActor in await open.run(MainActor.shared, ProbeKey(1), "one") }
        let inner = Received<IsolatedOpen.Call>()
        let hook = CompareHook {
            MainActor.assumeIsolated {
                inner.task = Task.immediate { @MainActor in inner.call = try? await box.open.nextStarted() }
            }
        }
        let call = try await open.nextStarted(for: ProbeKey(1, onCompare: hook))
        let input = call.input()
        #expect(input == "one")
        #expect(inner.call == nil)
        let three = Task.immediate { @MainActor in await open.run(MainActor.shared, ProbeKey(3), "three") }
        await inner.task?.value
        let later = try #require(inner.call)
        let laterInput = later.input()
        #expect(laterInput == "three")
        call.succeed("first")
        later.succeed("third")
        #expect(await one.value == "first")
        #expect(await three.value == "third")
    }

    // A wait for key 1 is installed. Comparing the first call for key 1 starts a second call for key 1
    // on the same actor. The wait receives the first call, and the second stays queued.
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    @Test func aCallStartedDuringAComparisonDoesNotOvertakeTheComparedCall() async throws {
        let box = DriverBox()
        let open = box.open
        let waiting = Received<IsolatedOpen.Call>()
        waiting.task = Task.immediate { @MainActor in waiting.call = try? await open.nextStarted(for: ProbeKey(1)) }
        let second = Received<String>()
        let hook = CompareHook {
            MainActor.assumeIsolated {
                second.task = Task.immediate { @MainActor in
                    second.call = await box.open.run(MainActor.shared, ProbeKey(1), "second")
                }
            }
        }
        let first = Task.immediate { @MainActor in
            await open.run(MainActor.shared, ProbeKey(1, onCompare: hook), "first")
        }
        await waiting.task?.value
        let call = try #require(waiting.call)
        let input = call.input()
        #expect(input == "first")
        let next = try await open.nextStarted(for: ProbeKey(1))
        let nextInput = next.input()
        #expect(nextInput == "second")
        call.succeed("one")
        next.succeed("two")
        #expect(await first.value == "one")
        await second.task?.value
        #expect(second.call == "two")
    }

    // The call is queued before the wait, and the waiting task is cancelled while the wait compares
    // that call's key. The wait takes nothing, and the call stays queued for the next wait.
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    @Test func aWaitCancelledWhileComparingAQueuedCallLeavesIt() async throws {
        let open = IsolatedOpen()
        let running = Task.immediate { @MainActor in await open.run(MainActor.shared, ProbeKey(1), "one") }
        let waiting = Task { @MainActor () -> Bool in
            let key = ProbeKey(1, onCompare: CompareHook { withUnsafeCurrentTask { $0?.cancel() } })
            return (try? await open.nextStarted(for: key)) == nil
        }
        #expect(await waiting.value)
        let call = try await open.nextStarted()
        let input = call.input()
        #expect(input == "one")
        call.succeed("done")
        #expect(await running.value == "done")
    }

    // The waiting task is cancelled while its key is compared. It takes nothing, and the call it
    // compared stays queued for the next wait.
    @Test func aWaitCancelledDuringItsComparisonLeavesTheCall() async throws {
        let open = IsolatedOpen()
        let cancellable = CancellableWait()
        let waiting = Received<IsolatedOpen.Call>()
        let task = Task { @MainActor in
            do {
                let key = ProbeKey(1, onCompare: CompareHook { cancellable.cancel() })
                waiting.call = try await open.nextStarted(for: key)
            } catch {
                waiting.failed = true
            }
        }
        cancellable.store(task)
        let running = Task { @MainActor in await open.run(MainActor.shared, ProbeKey(1), "one") }
        await task.value
        #expect(waiting.failed)
        #expect(waiting.call == nil)
        let call = try await open.nextStarted()
        let input = call.input()
        #expect(input == "one")
        call.succeed("done")
        #expect(await running.value == "done")
    }
}

@Suite(.timeLimit(.minutes(1))) struct KeyedMatchingTests {
    // As for the confined driver: whichever of the wait and the call arrives first, the comparison
    // runs once both exist, cancels the waiting task, and the wait takes nothing.
    @Test func aWaitCancelledDuringItsComparisonLeavesTheCall() async throws {
        let open = KeyedControlledDriver<ProbeKey, String, String, Never>()
        let cancellable = CancellableWait()
        let failed = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            do {
                _ = try await open.nextStarted(for: ProbeKey(1, onCompare: CompareHook { cancellable.cancel() }))
            } catch {
                failed.withLock { $0 = true }
            }
        }
        cancellable.store(task)
        let running = Task { await open.run(ProbeKey(1), "one") }
        await task.value
        #expect(failed.withLock { $0 })
        let call = try await open.nextStarted()
        #expect(call.input == "one")
        call.succeed("done")
        #expect(await running.value == "done")
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct KeyedMainActorMatchingTests {
    // The main-actor driver matches as the confined driver does, with the main actor as its owner.
    @Test func aWaitCancelledDuringItsComparisonLeavesTheCall() async throws {
        let open = KeyedMainActorControlledDriver<ProbeKey, String, String, Never>()
        let cancellable = CancellableWait()
        let waiting = Received<KeyedMainActorControlledDriver<ProbeKey, String, String, Never>.Call>()
        let task = Task { @MainActor in
            do {
                let key = ProbeKey(1, onCompare: CompareHook { cancellable.cancel() })
                waiting.call = try await open.nextStarted(for: key)
            } catch {
                waiting.failed = true
            }
        }
        cancellable.store(task)
        let running = Task { @MainActor in await open.run(ProbeKey(1), "one") }
        await task.value
        #expect(waiting.failed)
        let call = try await open.nextStarted()
        #expect(call.input == "one")
        call.succeed("done")
        #expect(await running.value == "done")
    }
}
