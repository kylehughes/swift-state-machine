import StateMachine
import StateMachineSchema
import Testing

@StateMachine(mode: .shared)
nonisolated enum Counter: Sendable {
    struct Idle: Sendable { let value: [String: [Int?]] }
    struct Done: Sendable { let value: Int }
    @Initial case idle(Idle)
    case done(Done)
    enum Input: Sendable { case finish(Int) }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Idle, _ value: Int) -> Done {
        Done(value: value + source.value.count)
    }
}

@Test func generatedLocalAcceptsOneHistoricalCandidate() throws {
    var owner = Counter.Local(Counter.Idle(value: [:]), configuration: try RuntimeLimits())
    guard case .idle(let idle) = owner.snapshot() else {
        Issue.record("wrong initial phase")
        return
    }
    let candidate = try idle.finish(3)
    guard case .committed(let receipt) = owner.commit(candidate) else {
        Issue.record("rejected candidate")
        return
    }
    #expect(receipt.revision == 1)
    guard case .done(let done) = receipt.snapshot else {
        Issue.record("wrong destination phase")
        return
    }
    #expect(done.value.value == 3)
    #expect(owner.drainCommands(limit: 1).count == 1)
    guard case .rejected(.invalidPhase) = Counter.prepare(.finish(4), on: owner.snapshot()) else {
        Issue.record("dynamic route accepted wrong phase")
        return
    }
}

@Test func generatedOwnedAdvancesWithNestedGenericPayload() {
    let owner = Counter.owned(Counter.Idle(value: ["a": [1, nil]]))
    let done = owner.finish(8)
    #expect(done.withValue { $0.value } == 9)
}

@StateMachine(mode: .isolated)
nonisolated enum IsolatedCounter {
    final class Text {
        let value: String
        init(_ value: String) { self.value = value }
    }
    struct Idle { let text: Text }
    struct Done { let text: Text }
    @Initial case idle(Idle)
    case done(Done)
    enum Input { case finish }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Idle) -> Done {
        Done(text: source.text)
    }
}

@StateMachine(mode: .ownedOnly)
nonisolated enum UniqueCounter: ~Copyable {
    struct Idle: ~Copyable { let value: Int }
    struct Done: ~Copyable { let value: Int }
    @Initial case idle(Idle)
    case done(Done)
    enum Input { case finish(Bool) }
    enum Rejection: Error { case declined }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: consuming Idle, _ accept: Bool) -> Advance<Idle, Done, Never, Rejection> {
        if accept { return .advanced(Done(value: source.value), effects: []) }
        return .rejected(.declined, source)
    }
}

@Test func isolatedLocalAcceptsNonSendableImmutablePayload() throws {
    var owner = IsolatedCounter.Local(.init(text: .init("confined")))
    guard case .idle(let idle) = owner.snapshot() else {
        Issue.record("wrong phase")
        return
    }
    guard case .committed(let receipt) = owner.commit(try idle.finish()), case .done(let done) = receipt.snapshot else {
        Issue.record("isolated candidate rejected")
        return
    }
    #expect(done.value.text.value == "confined")
}

@Test func ownedOnlyRejectionReturnsTheUniquePredecessor() {
    let owner = UniqueCounter.owned(.init(value: 7))
    switch owner.finish(false) {
    case .advanced: Issue.record("rejection lost")
    case .rejected(let error, let original):
        #expect(error == .declined)
        #expect(original.withValue { $0.value } == 7)
        switch original.finish(true) {
        case .advanced(let next, let effects):
            #expect(next.withValue { $0.value } == 7)
            #expect(effects.isEmpty)
        case .rejected: Issue.record("recovered predecessor could not advance")
        }
    }
}
