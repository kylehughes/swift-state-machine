import StateMachine
import Darwin
import Dispatch
import Foundation
import os

func uncontendedLocal(bytes: Int, operations: Int, timing: Bool, probe: AllocatorProbe?) throws -> ResultRow {
    var owner = PerformanceFlow.Local(.init(bytes: Array(repeating: 0, count: bytes)))
    var participant = Participant(role: "writer")
    if timing {
        participant.snapshotNanoseconds.reserveCapacity(operations)
        participant.preparationNanoseconds.reserveCapacity(operations)
        participant.commitNanoseconds.reserveCapacity(operations)
        participant.operationNanoseconds.reserveCapacity(operations)
    }
    var row = ResultRow(
        workload: "pt001-local",
        payloadBytes: bytes,
        operationsPerParticipant: operations,
        writers: 1,
        readers: 0
    )
    let start = now()
    for i in 0 ..< operations {
        let t0 = timing ? now() : 0
        let snapshot = owner.snapshot()
        let t1 = timing ? now() : 0
        let candidate = try prepared(snapshot, salt: UInt64(i))
        let t2 = timing ? now() : 0
        let result = owner.commit(candidate)
        let t3 = timing ? now() : 0
        participant.attempts += 1
        switch result {
        case .committed: participant.accepted += 1
        case .rejected: participant.otherRejections += 1
        }
        // Local ownership has no scheduling: explicit draining is outside commit latency.
        _ = owner.drainCommands(limit: 1)
        if timing {
            participant.snapshotNanoseconds.append(t1 - t0)
            participant.preparationNanoseconds.append(t2 - t1)
            participant.commitNanoseconds.append(t3 - t2)
            participant.operationNanoseconds.append(t3 - t0)
        }
        // Keep the historical Array alive across preparation and admission.
        withExtendedLifetime(snapshot) {}
    }
    row.wallNanoseconds = now() - start
    let final = value(owner.snapshot())
    try require(final.changes == UInt64(operations), "Local accepted-change counter mismatch")
    var expected = Array(repeating: UInt8(0), count: bytes)
    for i in 0 ..< operations { expected[i % bytes] &+= 1 }
    try require(final.bytes == expected, "Local CoW mutations differ from accepted operations")
    try require(participant.accepted == operations, "Uncontended admission rejected")
    participant.checksum = checksum(final.bytes)
    if let probe { row.memory["heldOwner"] = probe.snapshot() }
    _ = owner.close()
    _ = owner.drainCommands(limit: 1)
    try require(owner.isQuiescent, "Local owner failed quiescence")
    row.participants = [participant]
    row.counts = ["quiescentOwners": 1, "physicalDrivers": 0, "registeredSubscribers": 0, "explicitRetries": 0]
    row.notes = [
        "Local generated facade; snapshot, preparation and public commit measured separately. Commit duration is not lock-hold duration. Drain cost included only in wall throughput."
    ]
    return row
}

func uncontended(bytes: Int, operations: Int, timing: Bool, probe: AllocatorProbe?) async throws -> ResultRow {
    let owner = PerformanceFlow.Shared(
        .init(bytes: Array(repeating: 0, count: bytes)),
        drivers: .init(work: { .success($0) })
    )
    var participant = Participant(role: "writer")
    if timing {
        participant.snapshotNanoseconds.reserveCapacity(operations)
        participant.preparationNanoseconds.reserveCapacity(operations)
        participant.commitNanoseconds.reserveCapacity(operations)
        participant.operationNanoseconds.reserveCapacity(operations)
        participant.settlementNanoseconds.reserveCapacity(operations)
    }
    let start = now()
    for i in 0 ..< operations {
        let t0 = timing ? now() : 0
        let snapshot = owner.snapshot()
        let t1 = timing ? now() : 0
        let candidate = try prepared(snapshot, salt: UInt64(i))
        let t2 = timing ? now() : 0
        let result = owner.commit(candidate)
        let t3 = timing ? now() : 0
        participant.attempts += 1
        guard case .committed(let receipt) = result else {
            throw Failure(description: "Uncontended shared admission rejected")
        }
        participant.accepted += 1
        // Fence the inert FIFO batch outside all synchronous phase samples. No observer/effect is registered.
        let flushed = await owner.flush(through: receipt)
        let t4 = timing ? now() : 0
        try require(flushed, "Uncontended FIFO fence failed")
        if timing {
            participant.snapshotNanoseconds.append(t1 - t0)
            participant.preparationNanoseconds.append(t2 - t1)
            participant.commitNanoseconds.append(t3 - t2)
            participant.operationNanoseconds.append(t3 - t0)
            participant.settlementNanoseconds.append(t4 - t3)
        }
        withExtendedLifetime(snapshot) {}
    }
    var row = ResultRow(
        workload: "pt001",
        payloadBytes: bytes,
        operationsPerParticipant: operations,
        writers: 1,
        readers: 0
    )
    row.wallNanoseconds = now() - start
    let final = value(owner.snapshot())
    var expected = Array(repeating: UInt8(0), count: bytes)
    for i in 0 ..< operations { expected[i % bytes] &+= 1 }
    try require(
        final.changes == UInt64(operations) && final.bytes == expected,
        "Shared CoW changes differ from accepted operations"
    )
    participant.checksum = checksum(final.bytes)
    if let probe { row.memory["heldOwner"] = probe.snapshot() }
    await owner.shutdown()
    try require(owner.isQuiescent, "Uncontended shared owner failed shutdown")
    row.participants = [participant]
    row.counts = [
        "accepted": operations, "attempts": operations, "quiescentOwners": 1, "physicalDrivers": 0,
        "registeredSubscribers": 0, "explicitRetries": 0,
    ]
    row.notes = [
        "Single-writer generated Shared facade, no subscribers/effects. Snapshot, preparation and synchronous public commit are separate samples. An awaited FIFO flush after each commit prevents queued-work capacity pressure; settlementNanoseconds and wall throughput include that scheduling fence. Public commit is not lock-hold duration; internal drainer activity can overlap it. The additional Local lane removes managed scheduling entirely."
    ]
    return row
}

func concurrent(
    bytes: Int,
    operations: Int,
    writers: Int,
    readers: Int,
    timing: Bool,
    probe: AllocatorProbe?
) async throws -> ResultRow {
    let owner = PerformanceFlow.Shared(
        .init(bytes: Array(repeating: 0, count: bytes)),
        drivers: .init(work: { .success($0) })
    )
    let results = OSAllocatedUnfairLock(initialState: [Participant]())
    let start = now()
    DispatchQueue.concurrentPerform(iterations: writers + readers) { index in
        var participant = Participant(role: index < writers ? "writer" : "reader")
        participant.observedThreadID = UInt64(pthread_mach_thread_np(pthread_self()))
        if timing {
            participant.snapshotNanoseconds.reserveCapacity(operations)
            participant.preparationNanoseconds.reserveCapacity(operations)
            participant.commitNanoseconds.reserveCapacity(operations)
            participant.operationNanoseconds.reserveCapacity(operations)
        }
        for i in 0 ..< operations {
            let t0 = timing ? now() : 0
            let snapshot = owner.snapshot()
            let t1 = timing ? now() : 0
            if index >= writers {
                let observed = value(snapshot)
                participant.checksum &+= observed.changes &+ UInt64(observed.bytes[i % bytes])
                participant.attempts += 1
                if timing {
                    participant.snapshotNanoseconds.append(t1 - t0)
                    participant.operationNanoseconds.append((timing ? now() : 0) - t0)
                }
            } else {
                do {
                    let candidate = try prepared(snapshot, salt: UInt64(index * operations + i))
                    let t2 = timing ? now() : 0
                    let result = owner.commit(candidate)
                    let t3 = timing ? now() : 0
                    participant.attempts += 1
                    switch result {
                    case .committed: participant.accepted += 1
                    case .rejected(.conflict, _): participant.conflicts += 1
                    case .rejected(.capacityExceeded, _): participant.capacityRejections += 1
                    case .rejected: participant.otherRejections += 1
                    }
                    if timing {
                        participant.snapshotNanoseconds.append(t1 - t0)
                        participant.preparationNanoseconds.append(t2 - t1)
                        participant.commitNanoseconds.append(t3 - t2)
                        participant.operationNanoseconds.append(t3 - t0)
                    }
                } catch { participant.otherRejections += 1 }
            }
            withExtendedLifetime(snapshot) {}
        }
        let completed = participant
        results.withLock { $0.append(completed) }
    }
    var row = ResultRow(
        workload: "pt002",
        payloadBytes: bytes,
        operationsPerParticipant: operations,
        writers: writers,
        readers: readers
    )
    row.wallNanoseconds = now() - start
    row.participants = results.withLock { $0 }
    let accepted = row.participants.reduce(0) { $0 + $1.accepted }
    try require(row.participants.allSatisfy { $0.attempts == operations }, "Participant failed fixed attempt budget")
    try require(row.participants.reduce(0) { $0 + $1.otherRejections } == 0, "Unexpected preparation/admission failure")
    try require(
        accepted > 0 && value(owner.snapshot()).changes == UInt64(accepted),
        "Concurrent accepted changes were lost"
    )
    if let probe { row.memory["heldOwner"] = probe.snapshot() }
    await owner.shutdown()
    try require(owner.isQuiescent, "Shared owner failed shutdown")
    row.counts = [
        "accepted": accepted, "attempts": writers * operations, "readerSnapshots": readers * operations,
        "explicitRetries": 0, "quiescentOwners": 1, "physicalDrivers": 0, "registeredSubscribers": 0,
        "participantClosures": writers + readers,
        "observedParticipantThreads": Set(row.participants.map(\.observedThreadID)).count,
        "fixtureSwiftTasksCreated": 0,
        "finalPayloadChecksum": Int(checksum(value(owner.snapshot()).bytes)),
    ]
    row.notes = [
        "One writer operation is one snapshot/prepare/commit attempt, with no retry. Accepted changes are reported separately. Managed FIFO scheduling can overlap the public commit; no observer/effect is registered. Thread roles are Dispatch concurrentPerform participants; scheduler concurrency is not a fairness guarantee."
    ]
    return row
}

final class SubscriberRecorder: Sendable {
    struct State {
        var revisions: [UInt64] = []
        var completed: UInt64 = 0
        var goal: UInt64 = .max
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    let complete = Event()
    func observe(_ snapshot: PerformanceFlow.Snapshot) {
        let done = state.withLock { s in
            s.revisions.append(snapshot.revision)
            s.completed = value(snapshot).completions
            return s.completed >= s.goal
        }
        if done { complete.signal() }
    }
    func target(_ count: UInt64) {
        let done = state.withLock { s in
            s.goal = count
            return s.completed >= count
        }
        if done { complete.signal() }
    }
}

func pressure(bytes: Int, operations: Int, timing: Bool, probe: AllocatorProbe?) async throws -> ResultRow {
    #if PERFORMANCE_RESOURCE_INSTRUMENTED
    RuntimeDeliveryProbe.reset()
    #endif
    let gate = DriverGate()
    let owner = PerformanceFlow.Shared(
        .init(bytes: Array(repeating: 0, count: bytes)),
        drivers: .init(work: { await gate.run($0) }),
        configuration: try .init(commits: 8, descriptors: 1, executions: 16, subscribers: 2),
        completionPolicy: .retryPure
    )
    let entered = Event()
    let releaseSlow = DispatchSemaphore(value: 0)
    let slow = SubscriberRecorder()
    let fast = SubscriberRecorder()
    let first = OSAllocatedUnfairLock(initialState: true)
    let token = try owner.subscribe { snapshot in
        let shouldBlock = first.withLock { s in
            let previous = s
            s = false
            return previous
        }
        if shouldBlock {
            entered.signal()
            precondition(releaseSlow.wait(timeout: .now() + 120) == .success, "Slow subscriber release timed out")
        }
        slow.observe(snapshot)
    }
    let monitor = try owner.subscribe { fast.observe($0) }
    await entered.wait()
    var participant = Participant(role: "effect-producer")
    if timing { participant.operationNanoseconds.reserveCapacity(operations) }
    var acceptedIDs: [Int] = []
    acceptedIDs.reserveCapacity(16)
    let start = now()
    for id in 0 ..< operations {
        let t = timing ? now() : 0
        guard case .ready(let observed) = owner.snapshot() else { throw Failure(description: "Wrong pressure phase") }
        let candidate = try observed.start(id)
        switch owner.commit(candidate) {
        case .committed:
            acceptedIDs.append(id)
            participant.accepted += 1
        case .rejected(.capacityExceeded, _), .rejected(.operationPolicy, _): participant.capacityRejections += 1
        case .rejected(.conflict, _): participant.conflicts += 1
        case .rejected: participant.otherRejections += 1
        }
        participant.attempts += 1
        if timing { participant.operationNanoseconds.append(now() - t) }
    }
    try require(!acceptedIDs.isEmpty && acceptedIDs.count <= 16, "Effect reservation bound violated")
    if operations > 16 { try require(participant.capacityRejections > 0, "Queue pressure did not reach its bound") }
    await gate.waitForStarts(acceptedIDs.count)
    fast.target(UInt64(acceptedIDs.count))
    slow.target(UInt64(acceptedIDs.count))
    let held = probe?.snapshot()
    #if PERFORMANCE_RESOURCE_INSTRUMENTED
    let pressureCounts = await owner.performanceResourceCounts()
    let pressureMarkers = owner.performanceWeakMarkers()
    #endif
    await gate.release()
    await fast.complete.wait()
    let beforeRelease = slow.state.withLock { $0.revisions.count }
    try require(beforeRelease == 0, "Blocked subscriber unexpectedly completed a callback")
    releaseSlow.signal()
    await slow.complete.wait()
    let finalRevision = owner.snapshot().revision
    let recorded = slow.state.withLock { $0.revisions }
    try require(
        recorded.count == 2 && recorded.last == finalRevision,
        "Latest mailbox did not coalesce held observations to final state"
    )
    let executed = await gate.counts()
    try require(
        executed.starts.sorted() == acceptedIDs && executed.finishes.sorted() == acceptedIDs,
        "Accepted effects were lost, duplicated, or substituted"
    )
    try require(
        value(owner.snapshot()).completions == UInt64(acceptedIDs.count),
        "Effect completions did not all publish"
    )
    var expectedPayload = Array(repeating: UInt8(0), count: bytes)
    for id in acceptedIDs { expectedPayload[id % bytes] &+= 1 }
    let finalModel = value(owner.snapshot())
    try require(
        finalModel.changes == UInt64(acceptedIDs.count) && finalModel.bytes == expectedPayload,
        "Pressure workload payload does not match accepted effect intents"
    )
    token.cancel()
    monitor.cancel()
    await owner.shutdown()
    try require(owner.isQuiescent, "Pressure owner failed shutdown")
    var row = ResultRow(
        workload: "pt003",
        payloadBytes: bytes,
        operationsPerParticipant: operations,
        writers: 1,
        readers: 1
    )
    row.wallNanoseconds = now() - start
    row.participants = [participant]
    if let held { row.memory["blockedSubscriberAndDrivers"] = held }
    row.counts = [
        "acceptedEffectIntents": acceptedIDs.count, "executedDistinctIDs": Set(executed.starts).count,
        "completedEffects": executed.finishes.count, "blockedCallbacks": 1, "slowCallbacks": recorded.count,
        "coalescedNonterminalObservations": Int(finalRevision + 1) - recorded.count,
        "configuredCommitCapacity": 8, "configuredExecutionCapacity": 16, "configuredSubscriberCapacity": 2,
        "quiescentOwners": 1, "registeredSubscribersAfterCancel": 0, "controlledDriversAfterShutdown": 0,
        "explicitRetries": 0,
    ]
    #if PERFORMANCE_RESOURCE_INSTRUMENTED
    await RuntimeCoordinatorTaskProbe.join()
    let pressureTeardown = await owner.performanceResourceCounts()
    for key in [
        "subscribers", "executionReservations", "pendingDeliveries", "preparationClaims", "coordinatorWorkers",
        "progressWaiters", "trackedTaskHandles", "pendingMailboxes", "scheduledMailboxes", "queuedOrdinaryBatches",
        "queuedTerminalBatches", "activeAuthority",
    ] {
        try require(pressureTeardown[key] == 0, "Private pressure resource did not settle: \(key)")
    }
    for (key, count) in pressureCounts { row.counts["sampledHeld_" + key] = count }
    for (key, count) in pressureTeardown { row.counts["afterJoinedShutdown_" + key] = count }
    row.counts["sampledWeakMarkersWhileOwnerHeld"] = pressureMarkers.filter(\.isAlive).count
    let preparationRounds = RuntimeDeliveryProbe.rounds
    row.counts["completionPreparationRounds"] = preparationRounds.count
    row.counts["completionPreparationAttempts"] = preparationRounds.reduce(0, +)
    row.counts["extraCompletionPreparations"] = preparationRounds.reduce(0, +) - acceptedIDs.count
    row.counts["maxCompletionPreparationsInTurn"] = preparationRounds.max() ?? 0
    try require(preparationRounds.allSatisfy { $0 <= 4 }, "Completion preparation turn budget exceeded")
    RuntimeDeliveryProbe.reset()
    #endif
    row.notes = [
        "One blocked initial callback spans the fixed producer attempt burst; a fast subscriber proves completion delivery. Distinct accepted effect IDs are compared exactly with physical driver starts/returns. Mailbox pending capacity one is a source contract; measured coalescing is initial plus final callback. The shipping facade does not expose private queue/task/reservation high-water counts; the separate resource-copy profile supplies checkpoint samples. Completion retryPure internal retry counts are unavailable through the facade."
    ]
    return row
}

func lifecycle(bytes: Int, operations: Int, timing: Bool, probe: AllocatorProbe?) async throws -> ResultRow {
    var retained: [PerformanceFlow.Snapshot] = []
    retained.reserveCapacity(min(64, operations))
    var participant = Participant(role: "lifecycle-controller")
    if timing { participant.operationNanoseconds.reserveCapacity(operations) }
    #if PERFORMANCE_RESOURCE_INSTRUMENTED
    var maxima: [String: Int] = [:]
    var resourcesSampled = 0
    var weakMarkerChecks = 0
    var completionPreparations = 0
    #endif
    var cancelled = 0
    var completed = 0
    var releasedOwners = 0
    let start = now()
    for cycle in 0 ..< operations {
        let t = timing ? now() : 0
        #if PERFORMANCE_RESOURCE_INSTRUMENTED
        RuntimeDeliveryProbe.reset()
        #endif
        let gate = DriverGate()
        var owner: PerformanceFlow.Shared? = PerformanceFlow.Shared(
            .init(bytes: Array(repeating: 0, count: bytes)),
            drivers: .init(work: { await gate.run($0) })
        )
        weak let marker = owner
        #if PERFORMANCE_RESOURCE_INSTRUMENTED
        var privateMarkers = owner!.performanceWeakMarkers()
        #endif
        guard case .ready(let ready) = owner!.snapshot(), case .committed = owner!.commit(try ready.start(cycle)) else {
            throw Failure(description: "Lifecycle start rejected")
        }
        await gate.waitForStarts(1)
        #if PERFORMANCE_RESOURCE_INSTRUMENTED
        let heldResources = await owner!.performanceResourceCounts()
        for (key, count) in heldResources { maxima[key] = max(maxima[key, default: 0], count) }
        resourcesSampled += 1
        try require(
            heldResources["executionReservations"] == 1 && heldResources["coordinatorWorkers"] == 1,
            "Private held driver/reservation sample does not reflect the running workload"
        )
        #endif
        if cycle % 2 == 0 {
            guard case .ready(let ready) = owner!.snapshot(), case .committed = owner!.commit(try ready.cancel()) else {
                throw Failure(description: "Lifecycle cancel rejected")
            }
            // Flush proves the cancellation decision reached the coordinator before release.
            let receipt = owner!.close()
            _ = await owner!.flush(through: receipt)
            await gate.release()
            cancelled += 1
        } else {
            let observed = SubscriberRecorder()
            observed.target(1)
            let token = try owner!.subscribe { observed.observe($0) }
            #if PERFORMANCE_RESOURCE_INSTRUMENTED
            privateMarkers += owner!.performanceWeakMarkers(subscribersOnly: true)
            let subscriberResources = await owner!.performanceResourceCounts()
            for (key, count) in subscriberResources { maxima[key] = max(maxima[key, default: 0], count) }
            resourcesSampled += 1
            try require(subscriberResources["subscribers"] == 1, "Private subscriber sample missing live registration")
            #endif
            await gate.release()
            await observed.complete.wait()
            token.cancel()
            completed += 1
        }
        await owner!.shutdown()
        try require(owner!.isQuiescent, "Lifecycle obligations did not settle")
        let settledModel = value(owner!.snapshot())
        try require(
            settledModel.changes == 1 && settledModel.completions == (cycle % 2 == 0 ? 0 : 1),
            "Lifecycle completion/cancellation model result mismatch"
        )
        try require(
            settledModel.bytes[cycle % bytes] == 1 && checksum(settledModel.bytes) == 1,
            "Lifecycle payload mutation was lost or duplicated"
        )
        let counts = await gate.counts()
        try require(
            counts.starts == [cycle] && counts.finishes == [cycle],
            "Lifecycle driver did not run/return exactly once"
        )
        try require(counts.cancelled == (cycle % 2 == 0 ? 1 : 0), "Cancellation was confused with physical termination")
        #if PERFORMANCE_RESOURCE_INSTRUMENTED
        // Cohort size one: join library handles before dropping each owner. This avoids retaining
        // all completed task allocations for a 10,000-cycle resource run.
        maxima["retainedTaskHandlesBeforeJoin"] = max(
            maxima["retainedTaskHandlesBeforeJoin", default: 0],
            RuntimeCoordinatorTaskProbe.trackedCount
        )
        await RuntimeCoordinatorTaskProbe.join()
        let settledResources = await owner!.performanceResourceCounts()
        let rounds = RuntimeDeliveryProbe.rounds
        completionPreparations += rounds.reduce(0, +)
        try require(rounds.allSatisfy { $0 <= 4 }, "Lifecycle completion preparation turn budget exceeded")
        RuntimeDeliveryProbe.reset()
        for (key, count) in settledResources {
            try require(count == 0, "Private lifecycle resource remains: \(key)=\(count)")
        }
        #endif
        if cycle < 64 { retained.append(owner!.snapshot()) }
        owner = nil
        try require(marker == nil, "Generated Shared owner retained after shutdown/drop")
        #if PERFORMANCE_RESOURCE_INSTRUMENTED
        try require(
            privateMarkers.allSatisfy { !$0.isAlive },
            "Joined host/mailbox storage, coordinator or progress survived owner drop"
        )
        weakMarkerChecks += privateMarkers.count
        #endif
        releasedOwners += 1
        participant.attempts += 1
        participant.accepted += 1
        if timing { participant.operationNanoseconds.append(now() - t) }
    }
    var row = ResultRow(
        workload: "pt004",
        payloadBytes: bytes,
        operationsPerParticipant: operations,
        writers: 1,
        readers: 0
    )
    row.wallNanoseconds = now() - start
    let heldPayloadBytes = retained.reduce(0) { $0 + value($1).bytes.count }
    try require(heldPayloadBytes == min(64, operations) * bytes, "Retained snapshot payload accounting mismatch")
    if let probe { row.memory["retainedSnapshots"] = probe.snapshot() }
    retained.removeAll(keepingCapacity: false)
    if let probe { row.memory["releasedSnapshots"] = probe.snapshot() }
    row.participants = [participant]
    row.counts = [
        "cycles": operations, "cancelledDrivers": cancelled, "completedDrivers": completed,
        "driverStarts": operations, "driverReturns": operations, "controlledLiveDriversAfterShutdown": 0,
        "inputCommitAttempts": operations + cancelled, "acceptedInputCommits": operations + cancelled,
        "automaticCompletionCommits": completed, "acceptedLifecycleCycles": operations,
        "releasedWeakOwners": releasedOwners, "registeredSubscriptionsAfterCancel": 0,
        "retainedSnapshotCount": min(64, operations), "retainedPayloadBytes": heldPayloadBytes,
        "retainedSnapshotCountAfterRelease": 0, "quiescentOwners": operations, "explicitRetries": 0,
    ]
    #if PERFORMANCE_RESOURCE_INSTRUMENTED
    for (key, count) in maxima { row.counts["maxSampled_" + key] = count }
    row.counts["completionPreparationAttempts"] = completionPreparations
    row.counts["extraCompletionPreparations"] = completionPreparations - completed
    row.counts["privateResourceSamples"] = resourcesSampled
    row.counts["weakMarkerReleaseChecks"] = weakMarkerChecks
    row.counts["trackedTaskHandlesAfterCohortJoin"] = RuntimeCoordinatorTaskProbe.trackedCount
    row.counts["privateResourcesAfterJoinedShutdown"] = 0
    row.notes.append(
        "Separate nonshipping resource-copy mode samples actual engine/coordinator/subscriber/queue/claim counts. maxSampled values are checkpoint maxima, not continuously observed peaks. Tracked Task<Void> handles include completed tasks until a per-cycle join; they are not asserted to equal simultaneously live tasks. Watchers join their exact Outcome workers. Weak markers cover host storage/progress/coordinator and registered mailbox/storage, and never retain them."
    )
    #endif
    row.notes += [
        "Alternating cancel and completion cycles await real driver entry/return and public shutdown. Weak markers measure facade-owner release; controlled driver counts are measured. Exact private worker/watcher/mailbox storage counters are not inferred from those counts. Up to 64 snapshots intentionally retain model Arrays; Array headers and authority metadata are additional. Released-snapshot memory includes runtime/allocator caches and harness lifetime."
    ]
    return row
}
