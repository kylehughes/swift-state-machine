import Foundation
import StateMachine
import StateMachineExamples
import os

// The distinct-projection slice (E12): `distinctSnapshots` sequences of a
// generated `Shared` owner of the profile graph, projected to the phase's name, so a change within one
// phase projects to an equal value and closing projects to the phase it closed in. Sequence 0 is
// registered at the start; `observe(B)` registers sequence 1 later. Its verbs: `apply` (`load`),
// `sendCancel` (`cancel`), `edit` (`authenticationChanged`, a change within the phase), `finish(A)`
// (`close`), `observe(B)`, `readSeq(k)` (a read of sequence k on the main actor, which returns a pending
// element at once or waits), `stop` (`cancel()` of sequence 0), and `turn`. The drivers fail at once,
// so a load reaches the failed phase on the owner's own tasks; every step waits, with a safety net, until
// each waiting read has returned or the owner has nothing more for it.
//
// Invariant I52: within one sequence two consecutive elements are equal only when the owner held a
// different projection between them, which the latest-value mailbox replaced (equality is
// registration-local, so another sequence's last element may equal its first); every element is the projection of
// a state the owner held at or after the registration; and once the owner has closed, every sequence
// ends, after the closed phase if that differs from its last element, even when it does not.

/// Runs one sequence against distinct projected sequences of a generated `Shared` owner.
@MainActor final class ExplorerDistinctRun: ExplorerRunner {
    let world: ExplorerWorld
    private let owner: GeneratedProfile.Shared
    private let request: ProfileRequest
    private var sequences: [SnapshotSequence<ExplorerPhase>?] = [nil, nil]
    private var iterators: [SnapshotSequence<ExplorerPhase>.AsyncIterator?] = [nil, nil]
    private var reads: [[String]] = [[], []]
    private var ended = [false, false]
    private var reading: [Bool] = [false, false]
    // The position in each history of the projection the last read returned.
    private var lastRead = [0, 0]
    // Every projection the owner has held since each sequence's registration.
    private var history: [[String]] = [[], []]
    private var closed = false
    // The projection of the closed phase, the last element every open sequence must reach.
    private var closedProjection: String?
    // The harness cancels every sequence at quiescence.
    private var tearingDown = false
    private var cancelled = false
    private var turns = 0
    private var equalityArmed = false

    init?(verbose: Bool = false) {
        world = ExplorerWorld(verbose: verbose)
        guard let user = try? UserID("explorer"), let request = try? ProfileRequest(userID: user) else { return nil }
        self.request = request
        owner = GeneratedProfile.Shared(
            .init(userID: user),
            fetchDriver: { _ in .failure(.unavailable) },
            auditDriver: { _ in .failure(.unavailable) }
        )
    }

    nonisolated static func phase(_ snapshot: GeneratedProfile.Snapshot) -> String {
        switch snapshot {
        case .idle: "idle"
        case .loading: "loading"
        case .loaded: "loaded"
        case .failed: "failed"
        }
    }
    private var current: String { Self.phase(owner.snapshot()) }

    private func register(_ index: Int) {
        history[index] = [current]
        lastRead[index] = 0
        sequences[index] = try? owner.distinctSnapshots { ExplorerPhase(name: Self.phase($0)) }
        iterators[index] = sequences[index]?.makeAsyncIterator()
    }

    func enabled() -> [ExplorerEvent] {
        var result: [ExplorerEvent] = []
        if !closed { result += [.apply, .sendCancel, .edit, .finish(0)] }
        if sequences[1] == nil { result.append(.observe(1)) }
        for index in 0 ..< 2 where iterators[index] != nil && !reading[index] && !ended[index] {
            result.append(.readSeq(index))
        }
        if !cancelled { result.append(.stop) }
        if !equalityArmed { result.append(.arm(.equality, .edit)) }
        if turns < 2 { result.append(.turn) }
        return result
    }

    func run(_ sequence: [ExplorerEvent]) async -> ExplorerOutcome {
        register(0)
        var enabledAfter = sequence.isEmpty ? enabled() : []
        for (index, event) in sequence.enumerated() {
            world.note("step \(index + 1): \(event)")
            turns = event == .turn ? turns + 1 : 0
            await perform(event)
            await settle()
            if !world.violations.isEmpty { break }
            if index == sequence.count - 1 { enabledAfter = enabled() }
        }
        await quiesce()
        return ExplorerOutcome(
            violations: world.violations,
            enabled: enabledAfter,
            fingerprint: "",
            trace: world.state.withLock { $0.trace }
        )
    }

    private func perform(_ event: ExplorerEvent) async {
        switch event {
        case .apply: _ = try? owner.send(.load(request))
        case .sendCancel: _ = try? owner.send(.cancel)
        case .edit: _ = try? owner.send(.authenticationChanged)
        case .finish:
            closed = true
            _ = owner.close()
            closedProjection = current
        case .observe: register(1)
        case .readSeq(let index): startRead(index)
        case .stop:
            cancelled = true
            sequences[0]?.cancel()
        case .arm(.equality, _):
            // The next `==` the owner evaluates for a projection calls the owner: it reads it and admits a
            // change, from wherever the comparison runs. A comparison inside a lock would deadlock (I16).
            equalityArmed = true
            let owner = owner
            explorerEqualityHook.withLock {
                $0 = {
                    _ = owner.subscriberCount
                    _ = try? owner.send(.authenticationChanged)
                }
            }
        case .turn: await Task { @MainActor in }.value
        default: break
        }
        record()
    }

    // The owner's projection now, appended to each live sequence's history when it changed.
    private func record() {
        let now = current
        for index in 0 ..< 2 where sequences[index] != nil && history[index].last != now { history[index].append(now) }
    }

    private func startRead(_ index: Int) {
        guard let start = iterators[index], !reading[index] else { return }
        reading[index] = true
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, watchOS 26.0, visionOS 26.0, *) else { return }
        Task.immediate { @MainActor [weak self] in
            var reader = start
            let value = await reader.next()
            self?.finished(index, value, reader)
        }
    }

    private func finished(
        _ index: Int,
        _ element: ExplorerPhase?,
        _ reader: SnapshotSequence<ExplorerPhase>.AsyncIterator
    ) {
        let value = element?.name
        reading[index] = false
        iterators[index] = reader
        // The owner's own tasks move it on too (a failed load), so sample its state as the read returns.
        record()
        guard let value else {
            ended[index] = true
            // Only the owner's closing ends a sequence the harness did not cancel, and only after the
            // closed phase, unless that equals the sequence's last element.
            if !(index == 0 && cancelled), !tearingDown,
                let problem = explorerDistinctEndProblem(
                    reads: reads[index],
                    closed: closed,
                    closedProjection: closedProjection
                )
            {
                world.violate(.distinctProjection, "sequence \(index) \(problem)")
            }
            return
        }
        world.note("sequence \(index) read \(value)")
        if ended[index] { world.violate(.distinctProjection, "sequence \(index) read \(value) after its end") }
        // Equal consecutive elements need a different projection between them, which the latest-value
        // mailbox replaced before the read: the sequence omits a projection equal to the one before it.
        if reads[index].last == value, !history[index][lastRead[index]...].contains(where: { $0 != value }) {
            world.violate(
                .distinctProjection,
                "sequence \(index) read \(value) twice in a row: \(reads[index] + [value])"
            )
        }
        // The element may stand for an earlier state than the owner's now (the seed, read before later
        // offers arrived): anchor it at its earliest position after the previous element's, in order.
        let read = explorerDistinctReadProblem(
            value,
            reads: reads[index],
            history: history[index],
            lastRead: lastRead[index]
        )
        lastRead[index] = read.anchor
        if let problem = read.problem { world.violate(.distinctProjection, "sequence \(index) \(problem)") }
        reads[index].append(value)
    }

    // A waiting read has more to come while the owner's projection differs from its last element, or
    // the owner has closed and the sequence has not ended.
    private func waiting() -> Bool {
        record()
        for index in 0 ..< 2 where reading[index] {
            if index == 0, cancelled { return true }
            if closed || reads[index].last != current { return true }
        }
        return false
    }

    private func settle() async {
        for _ in 0 ..< 2000 {
            if !waiting() { return }
            await Task { @MainActor in }.value
        }
        world.violate(.stuck, "a waiting read never returned (reads \(reads), owner at \(current), closed \(closed))")
    }

    private func quiesce() async {
        world.note("quiesce")
        explorerEqualityHook.withLock { $0 = nil }
        // A closed owner ends every sequence: each read past what it already read returns the end.
        if closed {
            for index in 0 ..< 2 where sequences[index] != nil && !(index == 0 && cancelled) {
                // The owner processes its batches in turn, so each read can return a later state.
                for _ in 0 ..< 12 where !ended[index] {
                    startRead(index)
                    await settle()
                }
                if !ended[index] {
                    world.violate(.distinctProjection, "sequence \(index) did not end after the owner closed")
                }
            }
        }
        tearingDown = true
        for index in 0 ..< 2 { sequences[index]?.cancel() }
        for _ in 0 ..< 2000 where reading.contains(true) { await Task { @MainActor in }.value }
        sequences = [nil, nil]
        iterators = [nil, nil]
        _ = owner.close()
        for _ in 0 ..< 2000 where owner.subscriberCount > 0 { await Task { @MainActor in }.value }
        if owner.subscriberCount > 0 {
            world.violate(.leak, "the owner still counts \(owner.subscriberCount) registrations")
        }
    }
}

/// The action armed to run inside the next `==` of a distinct projection (the `equality` site).
let explorerEqualityHook = OSAllocatedUnfairLock<(@Sendable () -> Void)?>(initialState: nil)

/// A phase name whose `==` runs the action armed at the `equality` site once.
nonisolated struct ExplorerPhase: Equatable, Sendable {
    let name: String
    static func == (lhs: ExplorerPhase, rhs: ExplorerPhase) -> Bool {
        let action = explorerEqualityHook.withLock { $0.take() }
        action?()
        return lhs.name == rhs.name
    }
}
