import StateMachine
import StateMachineTesting

@StateMachine(mode: .shared, owners: [.local])
nonisolated enum Lamp: Sendable {
    struct Lit: Sendable { let on: Bool }
    @Initial case lit(Lit)
    enum Input: Sendable { case flip }
    @Transition(on: Input.flip)
    fileprivate static func flip(_ source: Lit) -> Lit { Lit(on: !source.on) }
}

@StateMachine(mode: .shared, owners: [.local])
nonisolated enum Twin: Sendable {
    struct Lit: Sendable { let on: Bool }
    @Initial case lit(Lit)
    enum Input: Sendable { case flip }
    @Transition(on: Input.flip)
    fileprivate static func flip(_ source: Lit) -> Lit { Lit(on: !source.on) }
}

func coverage() throws -> Int {
    var test = ManualMachineTest(Twin.Local(Twin.Lit(on: false)))
    try test.send(.flip)
    var coverage = GraphCoverage(for: Lamp.Local.self)
    coverage.record(test)
    return coverage.exercisedEdgeIDs.count
}
