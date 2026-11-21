// A restoration function may take its saved data as sending: every restoring initializer and reset takes it so, and Local conforms.
import StateMachine
import StateMachineTesting

nonisolated public final class Archive { public var draft = ""; public init() {} }

@StateMachine(mode: .isolated, owners: [.local, .mainActorHost, .isolatedHost])
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
    var local = Editor.Local(restoring: Archive())
    try local.reset(restoring: Archive())
    var test = ManualMachineTest(Editor.Local(restoring: Archive()))
    try test.reset(restoring: Archive())
}
@MainActor func host() { _ = Editor.MainActorHost(restoring: Archive()) }
actor Workspace {
    func open() { _ = Editor.IsolatedHost(restoring: Archive(), isolation: self) }
}
