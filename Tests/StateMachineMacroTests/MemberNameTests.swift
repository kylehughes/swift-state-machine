import StateMachine
import Testing

/// Phases, an edge, and an operation named like generated members they do not redeclare.
@StateMachine(mode: .shared)
nonisolated private enum Ledger: Sendable, Equatable {
    struct Idle: Sendable, Equatable {}
    struct Revision: Sendable, Equatable { let count: Int }
    struct Description: Sendable, Equatable { let text: String }
    struct Record: Sendable, Equatable {}
    struct Model: Sendable, Equatable {}
    struct IsClosed: Sendable, Equatable {}
    @Initial case idle(Idle)
    case revision(Revision)
    case description(Description)
    case record(Record)
    case model(Model)
    @Terminal case isClosed(IsClosed)
    enum Input: Sendable {
        case bump(Int)
        case describe, keep, shape, finish
    }
    @Operation(activeIn: [Revision.self])
    enum Authority { typealias Output = String }
    /// `Observed.revision(_:)` and `Owned.revision(_:)` take the count, so neither redeclares the
    /// wrappers' `revision` and `phase` members.
    @Transition(on: Input.bump, starts: [Authority.self])
    fileprivate static func revision(_ source: Idle, _ count: Int) -> Change<Revision, Effect.Revision> {
        Change(Revision(count: count), effects: [.authority])
    }
    @Transition(onSuccess: Authority.self)
    fileprivate static func granted(_ source: Revision, _ text: String) -> Description { Description(text: text) }
    @Transition(on: Input.keep)
    fileprivate static func keep(_ source: Description) -> Record { Record() }
    @Transition(on: Input.shape)
    fileprivate static func shape(_ source: Record) -> Model { Model() }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Model) -> IsClosed { IsClosed() }
}

@Suite struct MemberNameTests {
    @Test func phasesNamedForSnapshotMembersKeepBothTheirCasesAndTheMembers() throws {
        var local = Ledger.Local(Ledger.Idle())
        let bumped = try local.send(.bump(3))
        guard case .revision(let observed) = bumped.snapshot else {
            Issue.record("the revision phase was not observed")
            return
        }
        #expect(observed.value == Ledger.Revision(count: 3))
        #expect(bumped.snapshot.revision == 1 && observed.revision == 1)
        #expect(bumped.snapshot.description == "revision, revision 1")
        #expect(bumped.snapshot.model == .revision(Ledger.Revision(count: 3)))
        #expect(!bumped.snapshot.isClosed)
        // The operation named `Authority` is a `Completion` case beside the sealed authority.
        let batch = local.drainCommands()
        guard case .authority(let work) = batch.first?.commands.first else {
            Issue.record("the authority work was not issued")
            return
        }
        guard case .committed(let granted) = local.deliver(.authority(work.succeeded("granted"))) else {
            Issue.record("the authority completion was not admitted")
            return
        }
        #expect(granted.edgeID == "revision.granted")
        #expect(granted.snapshot.model == .description(Ledger.Description(text: "granted")))
        for input in [Ledger.Input.keep, .shape, .finish] { try local.send(input) }
        guard case .isClosed(let closed) = local.snapshot() else {
            Issue.record("the terminal phase was not observed")
            return
        }
        #expect(closed.value == Ledger.IsClosed() && closed.revision == 5)
        #expect(Ledger.graph.phases.map(\.id) == ["idle", "revision", "description", "record", "model", "isClosed"])
    }

    @Test func anEdgeNamedForAWrapperPropertyIsAMethodOfEachWrapper() throws {
        // `Owned.revision(_:)` advances, beside the owned wrapper's members.
        let owned = Ledger.owned(Ledger.Idle()).revision(4)
        #expect(owned.next.takeValue() == Ledger.Revision(count: 4))
        // `Observed.revision(_:)` prepares, beside the observation's `revision` property.
        let shared = Ledger.Shared(Ledger.Idle(), authorityDriver: { "shared" })
        guard case .idle(let observed) = shared.snapshot() else {
            Issue.record("the initial phase was not observed")
            return
        }
        #expect(observed.revision == 0)
        guard case .committed(let receipt) = shared.commit(observed.revision(2)) else {
            Issue.record("the prepared revision was not admitted")
            return
        }
        #expect(receipt.edgeID == "idle.revision" && receipt.revision == 1)
    }
}
