import os

public struct Idle: Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}
public struct Loading: Sendable {
    public let request: String
    public init(_ request: String) { self.request = request }
}
public struct Request: Sendable {
    public let value: String
    public init?(_ value: String) {
        guard !value.isEmpty else { return nil }
        self.value = value
    }
}
@frozen public enum ValidationFailure: Error { case denied }
public enum Intent: Sendable, Equatable { case log(String), fetch(String) }
public struct Owned<Phase: ~Copyable>: ~Copyable {
    fileprivate let phase: Phase
    fileprivate init(_ phase: consuming Phase) { self.phase = phase }
    public borrowing func withValue<Result>(_ body: (borrowing Phase) -> Result) -> Result {
        body(phase)
    }
}
@frozen public enum Advance<Before: ~Copyable, After: ~Copyable>: ~Copyable {
    case advanced(After, effects: [Intent])
    case rejected(ValidationFailure, Before)
}
public func start(_ value: Idle) -> Owned<Idle> { Owned(value) }
extension Owned where Phase == Idle {
    public consuming func begin(_ request: Request, allowed: Bool) -> Advance<Owned<Idle>, Owned<Loading>> {
        guard allowed else { return .rejected(.denied, self) }
        return .advanced(Owned<Loading>(Loading(request.value)), effects: [.log(phase.name), .fetch(request.value)])
    }
}
extension Owned where Phase == Loading {
    public consuming func cancel() -> Owned<Idle> { Owned<Idle>(Idle(phase.request)) }
}

public enum Model: Sendable {
    case idle(Idle)
    case loading(Loading)
}
private final class Identity: Sendable {}
private struct Provenance: Sendable {
    let owner: Identity
    let revision: UInt64
}
public struct Observed<Phase: Sendable>: Sendable {
    public let value: Phase
    fileprivate let provenance: Provenance
}
public enum Snapshot: Sendable {
    case idle(Observed<Idle>)
    case loading(Observed<Loading>)
}
private struct Payload: Sendable {
    let provenance: Provenance
    let next: Model
    let start: Bool
}
public struct Prepared: ~Copyable, Sendable {
    fileprivate let payload: Payload
    fileprivate init(_ payload: Payload) { self.payload = payload }
}
extension Observed where Phase == Idle {
    public func begin(_ request: Request) -> Prepared {
        Prepared(Payload(provenance: provenance, next: .loading(Loading(request.value)), start: true))
    }
}
extension Observed where Phase == Loading {
    public func cancel() -> Prepared {
        Prepared(Payload(provenance: provenance, next: .idle(Idle(value.request)), start: false))
    }
}
public enum Admission: Sendable, Equatable { case accepted, foreign, conflict, closed }
private struct Storage: Sendable {
    let identity = Identity()
    var revision: UInt64 = 0
    var model: Model
    var active = false
    var closed = false
}
public final class Shared: Sendable {
    private let storage: OSAllocatedUnfairLock<Storage>
    public init(_ initial: Idle) { storage = OSAllocatedUnfairLock(initialState: Storage(model: .idle(initial))) }
    public func snapshot() -> Snapshot {
        let record = storage.withLock { ($0.model, Provenance(owner: $0.identity, revision: $0.revision)) }
        switch record.0 {
        case .idle(let value): return .idle(Observed(value: value, provenance: record.1))
        case .loading(let value): return .loading(Observed(value: value, provenance: record.1))
        }
    }
    public func commit(_ prepared: consuming Prepared) -> Admission {
        // Extraction occurs before the SDK closure. Only this Copyable Sendable value is captured.
        let payload = prepared.payload
        return storage.withLock { state in
            guard state.identity === payload.provenance.owner else { return .foreign }
            guard !state.closed else { return .closed }
            guard state.revision == payload.provenance.revision else { return .conflict }
            state.model = payload.next
            state.active = payload.start
            state.revision += 1
            return .accepted
        }
    }
    public func close() { storage.withLock { $0.closed = true; $0.active = false } }
    public var isClosed: Bool { storage.withLock { $0.closed } }
}

public struct Ticket<Operation>: Sendable {
    fileprivate let sequence: Int
    fileprivate init(_ sequence: Int) { self.sequence = sequence }
}
public enum Fetch: Sendable {}
public enum Save: Sendable {}
public struct Completion<Operation>: Sendable {
    public let value: String
    fileprivate let ticket: Ticket<Operation>
}
public struct Work: Sendable {
    public let input: String
    fileprivate let ticket: Ticket<Fetch>
    fileprivate init(input: String, sequence: Int) { self.input = input; ticket = Ticket(sequence) }
    public func succeeded(_ output: String) -> Completion<Fetch> { Completion(value: output, ticket: ticket) }
}
public struct SaveWork: Sendable {
    fileprivate let ticket: Ticket<Save>
    public func succeeded(_ output: String) -> Completion<Save> { Completion(value: output, ticket: ticket) }
}
public actor AdmissionHost {
    private var value = ""
    private var active: Int?
    private var sequence = 0
    public init() {}
    public func issueFetch(_ input: String) -> Work {
        sequence += 1; active = sequence
        return Work(input: input, sequence: sequence)
    }
    public func issueSave() -> SaveWork { SaveWork(ticket: Ticket(0)) }
    public func admit(_ completion: Completion<Fetch>) {
        guard active == completion.ticket.sequence else { return }
        value = completion.value; active = nil
    }
    public func read() -> String { value }
}
public func sharedWorker(_ work: Work, host: AdmissionHost) -> Task<Void, Never> {
    Task.detached {
        let result = work.succeeded(work.input.uppercased())
        await host.admit(result)
    }
}

// Immutable value-semantic data explicitly prohibited from implicit Sendable inference.
public struct IsolatedValue: ~Sendable {
    public let text: String
    public init(_ text: String) { self.text = text }
}
@MainActor public final class IsolatedHost {
    private var value = IsolatedValue("")
    private var worker: Task<Void, Never>?
    public init() {}
    public func run(_ input: IsolatedValue) {
        worker = Task { @MainActor in
            let output = await self.drive(input)
            self.value = output
        }
    }
    private func drive(_ input: IsolatedValue) async -> IsolatedValue { IsolatedValue(input.text.uppercased()) }
    public func join() async { await worker?.value }
    public func read() -> IsolatedValue { value }
}
public func requireSendable<T: Sendable>(_ value: T) {}
