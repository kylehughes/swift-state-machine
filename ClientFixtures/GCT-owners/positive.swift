// A schema that selects only Local generates it.
import StateMachine

@StateMachine(mode: .shared, owners: [.local])
nonisolated enum Counter: Sendable {
    struct Counting: Sendable { var count = 0 }
    @Initial case counting(Counting = Counting())
    enum Input: Sendable { case add }
    @Transition(on: Input.add)
    fileprivate static func add(_ source: Counting) -> Counting { Counting(count: source.count + 1) }
}
nonisolated func count() throws -> UInt64 {
    var counter = Counter.Local()
    return try counter.send(.add).revision
}
