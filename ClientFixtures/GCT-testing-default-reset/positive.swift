// A harness resets to the schema's declared initial default, as the owner does.
import StateMachine
import StateMachineTesting

@StateMachine(mode: .shared, owners: [.local])
nonisolated enum Counter: Sendable {
    struct Counting: Sendable { var count = 0 }
    @Initial case counting(Counting = Counting())
    enum Input: Sendable { case add }
    @Transition(on: Input.add)
    fileprivate static func add(_ source: Counting) -> Counting { Counting(count: source.count + 1) }
}

func exercise() throws {
    var test = ManualMachineTest(Counter.Local(Counter.Counting()))
    try test.send(.add)
    try test.reset(expecting: test.snapshot())
    try test.reset()
}
