// routed: requires a @Route, which is unavailable in .ownedOnly.
import StateMachine

@StateMachine(mode: .ownedOnly)
nonisolated enum MoveOnlyRoutedRefused: ~Copyable {
    struct Open: ~Copyable {}
    struct Done: ~Copyable {}
    @Initial case open(Open)
    @Terminal case done(Done)

    @Transition
    fileprivate static func finish(_ source: consuming Open, routed fd: Int) -> Done {
        _ = fd
        return Done()
    }
}
