// Saved data a restoring reset takes as sending cannot be used again after the reset.
import StateMachine

nonisolated public final class Archive { public var draft = ""; public init() {} }

@StateMachine(mode: .isolated, owners: [.local])
nonisolated enum Editor {
    struct Idle { let archive: Archive }
    struct Open {}
    @Initial case idle(Idle)
    case open(Open)
    enum Input { case open, close }
    @Transition(on: Input.open)
    fileprivate static func open(_ source: Idle) -> Open { Open() }
    @Transition(on: Input.close)
    fileprivate static func close(_ source: Open) -> Idle { Idle(archive: Archive()) }
    @Restoration
    fileprivate static func restore(_ saved: sending Archive) -> Restoration { .idle(Idle(archive: saved)) }
}
func check() throws {
    let archive = Archive()
    var local = Editor.Local(restoring: archive)
    try local.reset(restoring: archive)
    archive.draft = "edited"
}
