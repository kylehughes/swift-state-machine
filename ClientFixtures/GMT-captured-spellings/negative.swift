// Authored types named like a generated generic parameter or nested alias keep their meaning:
// generated code inside `IsolatedHost<Owner>`, `Observed<Phase>`, `Owned<Phase>`, and the hosts spells
// them through schema-level aliases.
import StateMachine

nonisolated struct Owner: Codable, Sendable { let open: Bool }
nonisolated struct Phase: Sendable { let value: Int }
nonisolated enum Host: Error, Sendable { case refused }

@StateMachine(mode: .shared)
nonisolated enum Gate: Sendable {
    struct Shut: Sendable {}
    struct Ajar: Sendable {}
    @Initial case shut(Shut)
    case ajar(Ajar)
    enum Input: Sendable { case open(Phase), close }
    @Transition(on: Input.open)
    fileprivate static func open(_ source: Shut, _ phase: Phase) throws(Host) -> Ajar {
        guard phase.value > 0 else { throw .refused }
        return Ajar()
    }
    @Transition(on: Input.close)
    fileprivate static func close(_ source: Ajar) -> Shut { Shut() }
    @Restoration
    fileprivate static func restore(_ saved: Owner) -> Restoration { saved.open ? .shut(Shut()) : .shut(Shut()) }
}

actor Keeper {
    private var gate: Gate.IsolatedHost<Keeper>?

    func restore() throws {
        let gate = Gate.IsolatedHost(restoring: Owner(open: false), isolation: self)
        try gate.reset(restoring: Gate.Shut())
        self.gate = gate
    }
}

nonisolated func prepare(_ observed: Gate.Observed<Gate.Shut>) throws(Host) -> Gate.Prepared {
    try observed.open(Phase(value: 1))
}
