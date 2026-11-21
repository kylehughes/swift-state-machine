fileprivate struct _TransitionSourceIsPhasePayload<Value: ~Swift::Copyable> {
}

fileprivate struct _TransitionReturnsDeclaredResult<Value: ~Swift::Copyable> {
}

fileprivate struct _TriggerPayloadMatchesDeclaration<Value: ~Swift::Copyable> {
}

fileprivate struct _RouterSourceIsPhasePayload<Value: ~Swift::Copyable> {
}

fileprivate struct _SharedModeRequiresSendable<Value: Swift::Sendable & ~Swift::Copyable> {
}

fileprivate struct _OperationFailureIsError<Value: Swift::Error> {
}

fileprivate struct _OperationKeyIsHashable<Value: Swift::Hashable & Swift::Sendable> {
}

fileprivate struct _EffectIsCopyable<Value> {
}

/// The schema, for generated code that names it where a value of its name could take the name.
internal typealias _StateMachineSchema = UniqueCounter

fileprivate typealias _StateMachineScopeID = StateMachine::RuntimeScopeID

fileprivate typealias _StateMachineOperation = StateMachine::RuntimeOperation

fileprivate typealias _StateMachineKey = StateMachine::RuntimeKey

fileprivate static func _stateMachineNamesSchema(_ type: Self.Type) {
}

@available(*, unavailable, message: "'UniqueCounter' names another type inside the schema, where an extension declares a member of that name; rename that member, because generated code names the schema 'UniqueCounter'.")
fileprivate static func _stateMachineNamesSchema<Value: ~Swift::Copyable>(_ type: Value.Type) {
}

fileprivate static func _stateMachineInputPayload<Value: ~Swift::Copyable>(_ value: borrowing Value) -> _TriggerPayloadMatchesDeclaration<Value> {
    _TriggerPayloadMatchesDeclaration<Value>()
}

fileprivate static func _stateMachineIsSwiftNever(_ type: Swift::Never.Type) {
}

@available(*, unavailable, message: "The macro reads this type as the standard library's Never, but it resolves to a different type; spell that type with its module name, or write Swift::Never.")
fileprivate static func _stateMachineIsSwiftNever<Value: ~Swift::Copyable>(_ type: Value.Type) {
}

fileprivate static func _stateMachineWitnesses() {
    _stateMachineNamesSchema(_StateMachineSchema.self)
    do {
        typealias _StateMachineChecked = Never;
        _stateMachineIsSwiftNever(_StateMachineChecked.self)
    }
    let _: _TransitionSourceIsPhasePayload<Idle> = _TransitionSourceIsPhasePayload<Idle>()
    let _: _TransitionReturnsDeclaredResult<StateMachine::Advance<Idle, Done, Swift::Never, Rejection>> = _TransitionReturnsDeclaredResult<Advance<Idle, Done, Never, Rejection>>()
    do {
        func witness(_ input: consuming Input) {
            switch consume input {
            case .finish(let bound):
                let payload = _stateMachineInputPayload(bound);
                let _: _TriggerPayloadMatchesDeclaration<Bool> = payload;
            case _:
                break
            }
        }
    }


    let _ = _EffectIsCopyable<Effect>()

}

/// Inert descriptions of the operations this workflow can start.
internal enum Effect {


}

/// Unique authority over one declared workflow phase.
internal struct Owned<Phase: ~Swift::Copyable>: ~Swift::Copyable {
    fileprivate let phase: Phase
    fileprivate init(_ phase: consuming Phase) {
        self.phase = phase
    }
    /// Borrows the payload without copying a unique resource, returning what `body` returns or throws.
    internal borrowing func withValue<Result: ~Swift::Copyable, Failure: Swift::Error>(
        _ body: (borrowing Phase) throws(Failure) -> Result
    ) throws(Failure) -> Result {
        try body(phase)
    }
    /// Consumes this authority and returns its payload, so a unique resource can move on.
    internal consuming func takeValue() -> Phase {
        phase
    }
    /// Consumes the predecessor and preserves it on authored rejection.
internal consuming func finish(_ input: Bool) -> StateMachine::Advance<Self, Owned<Done>, Swift::Never, Rejection> where Phase == Idle {
    switch _StateMachineSchema.finish(phase, input) {
    case .advanced(let next, let effects):
        return .advanced(Owned<Done>(next), effects: effects)
    case .rejected(let failure, let original):
        return .rejected(failure, Owned<Idle>(original))
    }
    }

}

/// Creates ownership only in the declared initial phase.
internal static func owned(_ initial: consuming Idle = _StateMachineSchema.Idle()) -> Owned<Idle> {
    Owned(initial)
}

fileprivate typealias _StateMachineGraph = StateMachine::StateMachineGraph

/// The declared phases, inputs, scopes, operations, events, edges, and routers of this graph,
/// without payloads or authority.
internal nonisolated static let graph: StateMachine::StateMachineGraph = _stateMachineGraph()

nonisolated private static func _stateMachineGraph() -> StateMachine::StateMachineGraph {
    var phases: [_StateMachineGraph.Phase] = []
    phases.append(_StateMachineGraph.Phase(id: "idle", payload: "Idle"))
    phases.append(_StateMachineGraph.Phase(id: "done", payload: "Done"))
    var inputs: [_StateMachineGraph.Input] = []
    inputs.append(_StateMachineGraph.Input(id: "finish", payload: "Bool"))
    var edges: [_StateMachineGraph.Edge] = []
    edges.append(_StateMachineGraph.Edge(id: "idle.finish", name: "finish",
        source: "idle", destination: "done", trigger: .input("finish"),
        router: nil, starts: [],
        cancels: [],
        emits: [], invalidates: []))
    return .init(
        name: "UniqueCounter",
        mode: .ownedOnly,
        owners: [.owned],
        initial: "idle",
        terminal: ["done"],
        restorable: [],
        phases: phases,
        inputs: inputs,
        scopes: [],
        operations: [],
        events: [],
        edges: edges,
        routers: []
    )
}
