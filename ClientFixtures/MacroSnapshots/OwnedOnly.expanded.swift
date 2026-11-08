fileprivate struct _AtomicTypeWitness<Value: ~Copyable> {
}

fileprivate struct _AtomicSendableWitness<Value: Sendable> {
}

fileprivate struct _AtomicErrorWitness<Value: Error> {
}

fileprivate struct _AtomicCopyableWitness<Value> {
}

fileprivate static func _atomicWitnesses() {
    let _: _AtomicTypeWitness<Idle> = _AtomicTypeWitness<Idle>()
    let _: _AtomicTypeWitness<Advance<Idle, Done, Effect, Rejection>> = _AtomicTypeWitness<Advance<Idle, Done, Effect, Rejection>>()
    let _: _AtomicTypeWitness<Bool> = _AtomicTypeWitness<Bool>()


    let _ = _AtomicCopyableWitness<Effect>()

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
