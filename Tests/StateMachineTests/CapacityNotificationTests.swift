import StateMachine
import Testing
import os

private typealias CapacityEngine = RuntimeState<Int, Int>
private typealias CapacityLedger = RuntimeDeliveryLedger<Int, Int, CapacityOutcome, Never>

private struct CapacityOutcome: Sendable {
    let ticket: RuntimeTicket
    let value: Int
}

private actor CapacityDrivers {
    private var released = false
    private var continuations: [(RuntimeTicket, CheckedContinuation<CapacityOutcome, Never>)] = []
    let starts: AsyncStream<RuntimeWork<Int>>
    private let started: AsyncStream<RuntimeWork<Int>>.Continuation

    init() {
        (starts, started) = AsyncStream.makeStream()
    }
    func run(_ work: RuntimeWork<Int>) async -> CapacityOutcome {
        if released { return CapacityOutcome(ticket: work.ticket, value: -1) }
        return await withCheckedContinuation {
            continuations.append((work.ticket, $0))
            started.yield(work)
        }
    }
    func releaseAll() {
        released = true
        let prior = continuations
        continuations = []
        for (ticket, continuation) in prior {
            continuation.resume(returning: CapacityOutcome(ticket: ticket, value: -1))
        }
        started.finish()
    }
}

private struct CapacityScenario: Sendable {
    let scope = RuntimeScopeID(kind: 1)
    let preparations = OSAllocatedUnfairLock(initialState: 0)
    let notifications = OSAllocatedUnfairLock(initialState: [CapacityLedger.Pending]())
    let reenter = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)
    let events: AsyncStream<CapacityLedger.Pending>
    let event: AsyncStream<CapacityLedger.Pending>.Continuation

    init() {
        (events, event) = AsyncStream.makeStream()
    }
    func watchdog(
        _ drivers: CapacityDrivers,
        close: @escaping @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            await close()
            await drivers.releaseAll()
            event.finish()
        }
    }
    func initial(_ snapshot: CapacityEngine.Snapshot) -> CapacityEngine.Candidate {
        try! CapacityEngine.prepare(
            on: snapshot,
            next: 1,
            plan: .init(starts: [
                .init(.init(kind: 1, scope: scope), descriptor: 1),
                .init(.init(kind: 2, scope: scope), descriptor: 2),
            ])
        )
    }
    func prepare(_ attempt: CapacityLedger.Attempt) -> CapacityLedger.Preparation {
        preparations.withLock { $0 += 1 }
        return .success(
            try! CapacityEngine.prepare(
                on: attempt.snapshot,
                next: 99,
                requiring: [attempt.outcome.ticket],
                plan: .init(
                    retire: [attempt.outcome.ticket],
                    starts: [
                        .init(.init(kind: 3, scope: scope), descriptor: 3),
                        .init(.init(kind: 4, scope: scope), descriptor: 4),
                    ],
                    finishingClaims: [attempt.claim]
                )
            )
        )
    }
    func notify(_ pending: CapacityLedger.Pending) {
        notifications.withLock { $0.append(pending) }
        let callback = reenter.withLock { $0 }
        callback?()
        event.yield(pending)
    }
    func check(_ pending: CapacityLedger.Pending?, ticket: RuntimeTicket) {
        #expect(pending?.outcome.ticket == ticket)
        #expect(pending?.outcome.value == 42)
        #expect(pending?.status == .reconciliationRequired)
        #expect(pending?.attempts == 1)
        if case .admission(.conflict) = pending?.lastRejection {
        } else {
            Issue.record("Capacity retry must report its root conflict")
        }
        #expect(preparations.withLock { $0 } == 1)
        #expect(notifications.withLock { $0.count } == 1)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct CapacityNotificationTests {
    @Test func sharedCapacityConflictNotifiesOnceWithoutPreparingAgain() async {
        let scenario = CapacityScenario()
        let drivers = CapacityDrivers()
        let owner = RuntimeSharedHost<Int, Int, CapacityOutcome, Never>(
            0,
            scopes: [scenario.scope],
            limits: try! .init(commits: 8, descriptors: 4, executions: 2),
            driver: { await drivers.run($0) },
            ticket: { $0.ticket },
            prepare: { scenario.prepare($0) },
            reconciliationRequired: { scenario.notify($0) }
        )
        let watchdog = scenario.watchdog(drivers, close: { _ = owner.close() })
        defer {
            watchdog.cancel()
            scenario.reenter.withLock { $0 = nil }
        }
        scenario.reenter.withLock {
            $0 = {
                _ = owner.snapshot()
                _ = owner.pendingCompletions()
            }
        }
        var starts = drivers.starts.makeAsyncIterator()
        var events = scenario.events.makeAsyncIterator()
        _ = owner.commit(scenario.initial(owner.snapshot()))
        guard let first = await starts.next(), await starts.next() != nil else {
            Issue.record("Both gated drivers must start before the capacity scenario")
            _ = owner.close()
            await drivers.releaseAll()
            await owner.shutdown(deadline: .now.advanced(by: .seconds(5)))
            watchdog.cancel()
            await watchdog.value
            return
        }
        let outcome = CapacityOutcome(ticket: first.ticket, value: 42)
        _ = owner.deliver(outcome)
        #expect(owner.pendingCompletions().first?.status == .waitingForCapacity)
        _ = owner.deliver(CapacityOutcome(ticket: first.ticket, value: 100))
        // Both drivers remain suspended: the root-only edit preserves their authority.
        _ = owner.commit(try! CapacityEngine.prepare(on: owner.snapshot(), next: 2))
        scenario.check(await events.next(), ticket: first.ticket)
        #expect(owner.snapshot().model == 2)
        #expect(owner.isActive(first.ticket))
        _ = owner.close()
        await drivers.releaseAll()
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(5))) == nil)
        #expect(scenario.notifications.withLock { $0.count } == 1)
        scenario.reenter.withLock { $0 = nil }
        scenario.event.finish()
        watchdog.cancel()
        await watchdog.value
    }

    @MainActor @Test func mainActorCapacityConflictNotifiesOnceAndAllowsReentry() async {
        let scenario = CapacityScenario()
        let drivers = CapacityDrivers()
        var reenter: (() -> Void)?
        let owner = RuntimeMainActorHost<Int, Int, CapacityOutcome, Never>(
            0,
            scopes: [scenario.scope],
            configuration: try! .init(commits: 8, descriptors: 4, executions: 2),
            driver: { await drivers.run($0) },
            ticket: { $0.ticket },
            prepare: { scenario.prepare($0) },
            reconciliationRequired: { pending in
                reenter?()
                scenario.notify(pending)
            }
        )
        let watchdog = scenario.watchdog(drivers, close: { _ = await owner.close() })
        defer {
            watchdog.cancel()
            reenter = nil
        }
        reenter = {
            _ = owner.snapshot()
            _ = owner.pendingCompletions()
        }
        var starts = drivers.starts.makeAsyncIterator()
        var events = scenario.events.makeAsyncIterator()
        _ = owner.commit(scenario.initial(owner.snapshot()))
        guard let first = await starts.next(), await starts.next() != nil else {
            Issue.record("Both gated drivers must start before the capacity scenario")
            _ = owner.close()
            await drivers.releaseAll()
            await owner.shutdown(deadline: .now.advanced(by: .seconds(5)))
            watchdog.cancel()
            await watchdog.value
            return
        }
        _ = owner.deliver(CapacityOutcome(ticket: first.ticket, value: 42))
        #expect(owner.pendingCompletions().first?.status == .waitingForCapacity)
        _ = owner.deliver(CapacityOutcome(ticket: first.ticket, value: 100))
        _ = owner.commit(try! CapacityEngine.prepare(on: owner.snapshot(), next: 2))
        scenario.check(await events.next(), ticket: first.ticket)
        #expect(owner.snapshot().model == 2 && owner.runningCount == 2)
        _ = owner.close()
        await drivers.releaseAll()
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(5))) == nil)
        #expect(owner.runningCount == 0)
        #expect(scenario.notifications.withLock { $0.count } == 1)
        reenter = nil
        scenario.event.finish()
        watchdog.cancel()
        await watchdog.value
    }

    @Test func actorCapacityConflictNotifiesOnceWithoutPreparingAgain() async {
        let scenario = CapacityScenario()
        let drivers = CapacityDrivers()
        let owner = RuntimeActorHost<Int, Int, CapacityOutcome, Never>(
            0,
            scopes: [scenario.scope],
            configuration: try! .init(commits: 8, descriptors: 4, executions: 2),
            driver: { await drivers.run($0) },
            ticket: { $0.ticket },
            prepare: { scenario.prepare($0) },
            reconciliationRequired: { scenario.notify($0) }
        )
        let watchdog = scenario.watchdog(drivers, close: { _ = await owner.close() })
        defer { watchdog.cancel() }
        var starts = drivers.starts.makeAsyncIterator()
        var events = scenario.events.makeAsyncIterator()
        _ = await owner.commit(scenario.initial(owner.snapshot()))
        guard let first = await starts.next(), await starts.next() != nil else {
            Issue.record("Both gated drivers must start before the capacity scenario")
            _ = await owner.close()
            await drivers.releaseAll()
            await owner.shutdown(deadline: .now.advanced(by: .seconds(5)))
            watchdog.cancel()
            await watchdog.value
            return
        }
        _ = await owner.deliver(CapacityOutcome(ticket: first.ticket, value: 42))
        #expect(await owner.pendingCompletions().first?.status == .waitingForCapacity)
        _ = await owner.deliver(CapacityOutcome(ticket: first.ticket, value: 100))
        _ = await owner.commit(try! CapacityEngine.prepare(on: owner.snapshot(), next: 2))
        scenario.check(await events.next(), ticket: first.ticket)
        #expect(await owner.snapshot().model == 2)
        #expect(await owner.runningCount == 2)
        _ = await owner.close()
        await drivers.releaseAll()
        #expect(await owner.shutdown(deadline: .now.advanced(by: .seconds(5))) == nil)
        #expect(await owner.runningCount == 0)
        #expect(scenario.notifications.withLock { $0.count } == 1)
        scenario.event.finish()
        watchdog.cancel()
        await watchdog.value
    }
}
