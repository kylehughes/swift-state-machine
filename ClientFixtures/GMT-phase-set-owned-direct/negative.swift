// An omitted reachable ~Copyable phase gains no direct edge from a @PhaseSet.
import StateMachine

@StateMachine(mode: .ownedOnly)
nonisolated enum DirectNoncopyable: ~Copyable {
    struct Fresh: ~Copyable { let id: Int }
    struct Active: ~Copyable { let id: Int }
    struct Locked: ~Copyable { let id: Int }
    struct Spent: ~Copyable {}
    @Initial case fresh(Fresh)
    case active(Active)
    case locked(Locked)
    @Terminal case spent(Spent)
    @PhaseSet([Fresh.self, Active.self])
    fileprivate enum Discardable {}
    @Transition
    fileprivate static func activate(_ source: consuming Fresh) -> Active { Active(id: source.id) }
    @Transition
    fileprivate static func lock(_ source: consuming Active) -> Locked { Locked(id: source.id) }
    @Transition
    fileprivate static func unlock(_ source: consuming Locked) -> Active { Active(id: source.id) }
    @Transition(from: Discardable.self)
    fileprivate static func discard() -> Spent { Spent() }
}

nonisolated func discardOmitted() {
    let locked = DirectNoncopyable.owned(DirectNoncopyable.Fresh(id: 1)).activate().lock()
    _ = locked.discard().takeValue()
}
