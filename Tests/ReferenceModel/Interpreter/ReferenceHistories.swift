/// Replay vocabulary uses slots for retained observations/proposals and exact tickets,
/// so ABA and stale whole-root submissions remain distinguishable in the trace.
enum ReferenceCommand: Equatable, Sendable {
    case snapshot(Int)
    case prepare(Int, SequentialReference.Input, observation: Int?)
    case commit(Int)
    case input(SequentialReference.Input)
    case retain(operation: Int, ReferenceOutcome)
    case reconcile(operation: Int)
    case acknowledge(operation: Int)
    case drain(Int)
    case subscribe(Int)
    case consume(Int)
    case unsubscribe(Int)
    case reset(ReferenceRoot)
    case fork(owner: UInt64, loading: ReferenceRestorationPolicy)
    case restore(owner: UInt64, root: ReferenceRoot, loading: ReferenceRestorationPolicy)
    case close
}
enum ReferenceResponse: Equatable, Sendable {
    case snapshot(ReferenceSnapshot)
    case prepared
    case rejected(ReferenceRejection)
    case admission(ReferenceAdmission)
    case delivery(ReferenceDelivery)
    case batches([ReferenceBatch])
    case subscribed(Bool)
    case observation(ReferenceSnapshot?)
    case acknowledged
    case missingSlot
}
struct ReferenceReplay: Sendable {
    private(set) var machine: SequentialReference
    private(set) var observations: [Int: ReferenceSnapshot] = [:]
    private(set) var candidates: [Int: ReferenceCandidate] = [:]
    private(set) var tickets: [ReferenceTicket] = []
    private(set) var subscriptions: [Int: UInt64] = [:]
    init(_ machine: SequentialReference) { self.machine = machine }
    mutating func execute(_ command: ReferenceCommand) -> ReferenceResponse {
        let response: ReferenceResponse
        switch command {
        case .snapshot(let slot):
            observations[slot] = machine.snapshot
            response = .snapshot(machine.snapshot)
        case .prepare(let slot, let input, let observation):
            if let observation, observations[observation] == nil { return .missingSlot }
            do {
                candidates[slot] = try machine.prepare(input, on: observation.flatMap { observations[$0] })
                response = .prepared
            } catch {
                candidates.removeValue(forKey: slot)
                response = .rejected(error)
            }
        case .commit(let slot):
            guard let candidate = candidates.removeValue(forKey: slot) else { return .missingSlot }
            response = .admission(machine.commit(candidate))
        case .input(let input):
            do { response = .admission(machine.commit(try machine.prepare(input))) } catch {
                response = .rejected(error)
            }
        case .retain(let operation, let outcome):
            guard tickets.indices.contains(operation) else { return .missingSlot }
            response = .delivery(machine.retain(tickets[operation], outcome: outcome))
        case .reconcile(let operation):
            guard tickets.indices.contains(operation) else { return .missingSlot }
            response = .delivery(machine.reconcile(tickets[operation].operation))
        case .acknowledge(let operation):
            guard tickets.indices.contains(operation) else { return .missingSlot }
            machine.acknowledge(tickets[operation])
            response = .acknowledged
        case .drain(let limit): response = .batches(machine.drain(limit: limit))
        case .subscribe(let slot):
            let id = machine.subscribe()
            subscriptions[slot] = id
            response = .subscribed(id != nil)
        case .consume(let slot):
            guard let id = subscriptions[slot] else { return .missingSlot }
            response = .observation(machine.consumeSubscriber(id))
        case .unsubscribe(let slot):
            if let id = subscriptions.removeValue(forKey: slot) { machine.unsubscribe(id) }
            response = .acknowledged
        case .reset(let root):
            do { response = .admission(machine.commit(try machine.prepareReset(root))) } catch {
                response = .rejected(error)
            }
        case .fork(let owner, let loading):
            do {
                machine = try machine.fork(owner: owner, loading: loading)
                response = .snapshot(machine.snapshot)
            } catch { response = .rejected(error) }
        case .restore(let owner, let root, let loading):
            guard owner != machine.owner else { return .rejected(.domain) }
            do {
                machine = try SequentialReference.restore(
                    owner: owner,
                    root: root,
                    configuration: machine.configuration,
                    loading: loading
                )
                response = .snapshot(machine.snapshot)
            } catch { response = .rejected(error) }
        case .close: response = .snapshot(machine.close())
        }
        for ticket in machine.reservations.map(\.ticket) where !tickets.contains(ticket) { tickets.append(ticket) }
        return response
    }
}
struct ReferenceHistoryCall: Equatable, Sendable {
    let client: Int
    let invocation: Int
    let response: Int
    let command: ReferenceCommand
    let result: ReferenceResponse
    init(client: Int, invocation: Int, response: Int, command: ReferenceCommand, result: ReferenceResponse) {
        self.client = client
        self.invocation = invocation
        self.response = response
        self.command = command
        self.result = result
    }
}
enum ReferenceHistoryVerdict: Equatable, Sendable {
    case witness([Int])
    case noWitness, invalidHistory
}
/// Exhaustive only for the supplied finite calls.
///
/// It does not establish universal
/// linearizability, and does not combine observation offering with callback execution.
enum ReferenceHistoryChecker {
    static func check(_ calls: [ReferenceHistoryCall], initial: ReferenceReplay) -> ReferenceHistoryVerdict {
        guard calls.allSatisfy({ $0.invocation < $0.response }) else { return .invalidHistory }
        for first in calls.indices {
            for second in calls.indices where first < second && calls[first].client == calls[second].client {
                if calls[first].invocation < calls[second].response && calls[second].invocation < calls[first].response
                {
                    return .invalidHistory
                }
            }
        }
        func search(_ state: ReferenceReplay, remaining: [Int], path: [Int]) -> [Int]? {
            if remaining.isEmpty { return path }
            for index in remaining {
                let call = calls[index]
                if remaining.contains(where: { $0 != index && calls[$0].response < call.invocation }) { continue }
                var next = state
                guard next.execute(call.command) == call.result else { continue }
                if let witness = search(next, remaining: remaining.filter { $0 != index }, path: path + [index]) {
                    return witness
                }
            }
            return nil
        }
        if let path = search(initial, remaining: Array(calls.indices), path: []) { return .witness(path) }
        return .noWitness
    }
}
struct ReferenceTraceStep: Equatable, Sendable {
    let command: ReferenceCommand
    let response: ReferenceResponse
}
/// Fixed LCG parameters make seeds portable; wrapping is confined to test generation,
/// never used for authoritative revisions or identities.
enum ReferenceTraceGenerator {
    static func commands(seed: UInt64, count: Int = 100) -> [ReferenceCommand] {
        var value = seed
        func draw() -> UInt64 {
            value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return value
        }
        var result: [ReferenceCommand] = [.subscribe(0)]
        while result.count < max(1, count) {
            let number = draw()
            let input = Int((number >> 16) % 17) + 1
            switch number % 18 {
            case 0: result.append(.snapshot(0))
            case 1: result.append(.prepare(0, .presentation(input), observation: 0))
            case 2: result.append(.commit(0))
            case 3: result.append(.input(.load(input)))
            case 4: result.append(.input(.refresh(input)))
            case 5: result.append(.input(.retry))
            case 6: result.append(.input(.cancel))
            case 7: result.append(.input(.authentication))
            case 8: result.append(.input(.presentation(input)))
            case 9: result.append(.retain(operation: 0, .success(input)))
            case 10: result.append(.reconcile(operation: 0))
            case 11: result.append(.acknowledge(operation: 0))
            case 12: result.append(.drain(2))
            case 13: result.append(.consume(0))
            case 14: result.append(.reset(.init(.idle(input))))
            case 15: result.append(.fork(owner: UInt64(100 + result.count), loading: .cancelLoading))
            case 16:
                result.append(
                    .restore(owner: UInt64(100 + result.count), root: .init(.idle(input)), loading: .rejectLoading)
                )
            default: result.append(.input(.load(-1)))
            }
        }
        if count > 1 { result[result.count - 1] = .close }
        return Array(result.prefix(max(0, count)))
    }
    static func replay(seed: UInt64, count: Int = 100) -> [ReferenceTraceStep] {
        var replay = ReferenceReplay(.init(owner: 1))
        return commands(seed: seed, count: count).map { .init(command: $0, response: replay.execute($0)) }
    }
}
