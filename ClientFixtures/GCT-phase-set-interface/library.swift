// A separate library-evolution module with public and package schemas using private and fileprivate
// @PhaseSet enums. None of the @PhaseSet names may appear in any emitted .swiftinterface.
import StateMachine

@StateMachine(mode: .shared)
public nonisolated enum EditorWorkflow: Sendable {
    public struct Draft: Sendable { public init() {} }
    public struct Reviewing: Sendable { public init() {} }
    public struct Exporting: Sendable { public init() {} }
    public struct Archived: Sendable { public init() {} }
    @Initial case draft(Draft = Draft())
    case reviewing(Reviewing)
    case exporting(Exporting)
    @Terminal case archived(Archived)
    public enum Input: Sendable {
        case submit
        case beginExport
        case finishExport
        case reset
        case archive
    }
    @PhaseSet([Draft.self, Reviewing.self])
    private enum PrivateEditable {}
    @StateMachine.PhaseSet([Draft.self, Reviewing.self])
    fileprivate enum FileprivateResettable {}
    @Transition(on: Input.submit)
    fileprivate static func submit(_ source: Draft) -> Reviewing { Reviewing() }
    @Transition(on: Input.beginExport)
    fileprivate static func beginExport(_ source: Reviewing) -> Exporting { Exporting() }
    @Transition(on: Input.finishExport)
    fileprivate static func finishExport(_ source: Exporting) -> Draft { Draft() }
    @Transition(from: PrivateEditable.self, on: Input.reset)
    fileprivate static func reset() -> Draft { Draft() }
    @Transition(from: FileprivateResettable.self, on: Input.archive)
    fileprivate static func archive() -> Archived { Archived() }
}

@StateMachine(mode: .shared)
package nonisolated enum PackageWorkflow: Sendable {
    package struct Idle: Sendable { package init() {} }
    package struct Busy: Sendable { package init() {} }
    @Initial case idle(Idle = Idle())
    case busy(Busy)
    package enum Input: Sendable {
        case work
        case reset
    }
    @PhaseSet([Idle.self, Busy.self])
    private enum PrivatePackageGroup {}
    @StateMachine.PhaseSet([Idle.self, Busy.self])
    fileprivate enum FileprivatePackageGroup {}
    @Transition(on: Input.work)
    fileprivate static func work(_ source: Idle) -> Busy { Busy() }
    @Transition(from: PrivatePackageGroup.self, on: Input.reset)
    fileprivate static func reset() -> Idle { Idle() }
}
