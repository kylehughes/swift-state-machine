fileprivate struct _TransitionSourceIsPhasePayload<Value: ~Copyable> {
}

fileprivate struct _TransitionReturnsDeclaredResult<Value: ~Copyable> {
}

fileprivate struct _TriggerPayloadMatchesDeclaration<Value: ~Copyable> {
}

fileprivate struct _EffectPayloadIsOperationInput<Value: ~Copyable> {
}

fileprivate struct _RouterSourceIsObservedPhase<Value: ~Copyable> {
}

fileprivate struct _SharedModeRequiresSendable<Value: Sendable> {
}

fileprivate struct _OperationFailureIsError<Value: Error> {
}

fileprivate struct _EffectIsCopyable<Value> {
}

fileprivate static func _stateMachineWitnesses() {
    let _: _TransitionSourceIsPhasePayload<Idle> = _TransitionSourceIsPhasePayload<Idle>()
    let _: _TransitionReturnsDeclaredResult<Advance<Idle, Done, Effect, Rejection>> = _TransitionReturnsDeclaredResult<Advance<Idle, Done, Effect, Rejection>>()
    let _: _TriggerPayloadMatchesDeclaration<Bool> = _TriggerPayloadMatchesDeclaration<Bool>()


    let _ = _EffectIsCopyable<Effect>()

}

/// Unique authority over one declared workflow phase.
internal struct Owned<Phase: ~Copyable>: ~Copyable {
    fileprivate let phase: Phase
    fileprivate init(_ phase: consuming Phase) {
        self.phase = phase
    }
    /// Borrows the payload without copying a unique resource.
    internal borrowing func withValue<Result>(_ body: (borrowing Phase) -> Result) -> Result {
        body(phase)
    }
    /// Consumes the predecessor and preserves it on authored rejection.
internal consuming func finish(_ input: Bool) -> Advance<Self, Owned<Done>, Effect, Rejection> where Phase == Idle {
    switch UniqueCounter.finish(phase, input) {
    case .advanced(let next, let effects):
        return .advanced(Owned<Done>(next), effects: effects)
    case .rejected(let failure, let original):
        return .rejected(failure, Owned<Idle>(original))
    }
    }
}

/// Creates ownership only in the declared initial phase.
internal static func owned(_ initial: consuming Idle) -> Owned<Idle> {
    Owned(initial)
}
