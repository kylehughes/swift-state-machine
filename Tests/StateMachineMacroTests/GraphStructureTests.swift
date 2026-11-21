import Foundation
import StateMachine
import Testing
import os

/// A payment whose work stays authorized while the checkout moves between the two phases of its
/// scope, and whose edges emit events alongside the work they start.
@StateMachine(mode: .shared)
nonisolated private enum Checkout: Sendable, Equatable {
    struct Cart: Sendable, Equatable { var items: [String] = [] }
    struct Paying: Sendable, Equatable { let items: [String] }
    struct Confirming: Sendable, Equatable { let items: [String] }
    struct Paid: Sendable, Equatable { let receipt: String }
    @Initial case cart(Cart = Cart())
    case paying(Paying)
    case confirming(Confirming)
    @Terminal case paid(Paid)
    enum Scope {
        @Active(in: [Paying.self, Confirming.self])
        case payment
    }
    enum Input: Sendable {
        case add(String)
        case pay
        case confirm
    }
    @Operation(scope: Scope.payment)
    enum Charge {
        typealias Input = [String]
        typealias Output = String
    }
    @Event
    enum Tracked { typealias Payload = String }
    @Event
    enum Pinged {}
    @Transition(on: Input.add, emits: [Tracked.self])
    fileprivate static func add(_ source: Cart, _ item: String) -> Change<Cart, Effect.Add> {
        Change(Cart(items: source.items + [item]), effects: [.tracked("added \(item)")])
    }
    @Transition(on: Input.pay, starts: [Charge.self], emits: [Tracked.self, Pinged.self])
    fileprivate static func pay(_ source: Cart) -> Change<Paying, Effect.Pay> {
        Change(Paying(items: source.items), effects: [.tracked("paying"), .charge(source.items), .pinged])
    }
    @Transition(on: Input.confirm)
    fileprivate static func confirm(_ source: Paying) -> Confirming { Confirming(items: source.items) }
    @Transition(onSuccess: Charge.self, emits: [Tracked.self])
    fileprivate static func charged(_ source: Paying, _ receipt: Charge.Output) -> Change<Paid, Effect.Charged> {
        Change(Paid(receipt: receipt), effects: [.tracked("paid \(receipt)")])
    }
    @Transition(onSuccess: Charge.self, emits: [Tracked.self])
    fileprivate static func charged(
        _ source: Confirming,
        _ receipt: Charge.Output
    ) -> Change<Paid, Effect.Charged> {
        Change(Paid(receipt: receipt), effects: [.tracked("paid \(receipt) after confirming")])
    }
}

/// Operations whose outcomes are spelled through aliases, which the graph keeps as written while it
/// reports which outcomes can happen.
@StateMachine(mode: .shared, owners: [.local])
nonisolated private enum Spelled: Sendable {
    typealias Nothing = Swift.Never
    enum Problem: Error { case lost }
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(Running)
    enum Input: Sendable { case go }
    @Operation(activeIn: [Running.self])
    enum Quiet { typealias Failure = Nothing }
    @Operation(activeIn: [Running.self])
    enum Selected { typealias Failure = Swift::Never }
    @Operation(activeIn: [Running.self])
    enum Listen {
        typealias Output = Nothing
        typealias Failure = Problem
    }
    @Transition(on: Input.go, starts: [Quiet.self, Selected.self, Listen.self])
    fileprivate static func go(_ source: Idle) -> Change<Running, Effect.Go> {
        Change(Running(), effects: [.quiet, .selected, .listen])
    }
    @Transition(onSuccess: Quiet.self)
    fileprivate static func quieted(_ source: Running) -> Idle { Idle() }
    @Transition(onSuccess: Selected.self)
    fileprivate static func chose(_ source: Running) -> Idle { Idle() }
    @Transition(onFailure: Listen.self)
    fileprivate static func lost(_ source: Running, _ failure: Problem) -> Idle { Idle() }
}

/// A schema and namespaces that declare their own `Swift`, `Void`, and `Never`, which the graph's
/// spellings of the types the namespaces omit cannot name.
@StateMachine(mode: .shared, owners: [.local])
nonisolated private enum Shadowing: Sendable {
    enum Swift {}
    struct Void {}
    enum Never {}
    struct Idle: Sendable {}
    struct Busy: Sendable {}
    @Initial case idle(Idle)
    case busy(Busy)
    enum Input: Sendable { case go }
    @Operation(activeIn: [Busy.self])
    enum Load {
        enum Swift {}
        struct Void {}
        enum Never {}
        /// Takes the types the graph's spellings name inside the namespace, where it says they are read.
        static func exported(input: (Swift::Void).Type, output: (Swift::Void).Type, failure: (Swift::Never).Type) {}
        static func check() { exported(input: Input.self, output: Output.self, failure: Swift::Never.self) }
    }
    @Event
    enum Logged {
        struct Void {}
        static func exported(payload: (Swift::Void).Type) {}
        static func check() { exported(payload: Payload.self) }
    }
    @Transition(on: Input.go, starts: [Load.self], emits: [Logged.self])
    fileprivate static func go(_ source: Idle) -> Change<Busy, Effect.Go> {
        Change(Busy(), effects: [.load, .logged])
    }
    @Transition(onSuccess: Load.self)
    fileprivate static func loaded(_ source: Busy) -> Idle { Idle() }
}

/// A door that a validator can also restore open.
@StateMachine(mode: .shared)
nonisolated private enum Door: Sendable {
    struct Closed: Sendable {}
    struct Open: Sendable {}
    struct Broken: Sendable {}
    @Initial case closed(Closed)
    case open(Open)
    @Terminal case broken(Broken)
    enum Input: Sendable { case push, pull, kick }
    @Restoration(only: [Open.self])
    fileprivate static func restore(_ saved: Bool) -> Restoration { .open(Open()) }
    @Transition(on: Input.push)
    fileprivate static func swingOpen(_ source: Closed) -> Open { Open() }
    @Transition(on: Input.pull)
    fileprivate static func swingShut(_ source: Open) -> Closed { Closed() }
    @Transition(from: [Closed.self, Open.self], on: Input.kick)
    fileprivate static func kick() -> Broken { Broken() }
}

/// A counter with only a manual owner, whose one edge emits an event and starts nothing.
@StateMachine(mode: .shared, owners: [.local])
nonisolated private enum Tally: Sendable {
    struct Counting: Sendable { var count = 0 }
    @Initial case counting(Counting = Counting())
    enum Input: Sendable { case add }
    @Event
    enum Counted { typealias Payload = Int }
    @Transition(on: Input.add, emits: [Counted.self])
    fileprivate static func add(_ source: Counting) -> Change<Counting, Effect.Add> {
        Change(Counting(count: source.count + 1), effects: [.counted(source.count + 1)])
    }
}

/// A coin with only an owned phase, whose router still has choice and result types.
@StateMachine(mode: .shared, owners: [.owned])
nonisolated private enum Coin: Sendable {
    struct Up: Sendable {}
    struct Down: Sendable {}
    @Initial case up(Up)
    case down(Down)
    enum Input: Sendable { case flip(Bool) }
    @Transition(on: Input.flip)
    fileprivate static func stay(_ source: Up, _ heads: Bool) -> Up { source }
    @Transition(on: Input.flip)
    fileprivate static func turn(_ source: Up, _ heads: Bool) -> Down { Down() }
    @Route(on: Input.flip)
    fileprivate static func toss(_ source: Up, _ heads: Bool) -> Route.Toss { heads ? .stay : .turn }
    @Transition(on: Input.flip)
    fileprivate static func back(_ source: Down, _ heads: Bool) -> Up { Up() }
}

/// A unique ticket taken directly, with no input enum.
@StateMachine(mode: .ownedOnly)
nonisolated private enum Ticket: ~Copyable {
    struct Valid: ~Copyable { let seat: Int }
    struct Used: ~Copyable { let seat: Int }
    @Initial case valid(Valid)
    @Terminal case used(Used)
    @Event
    enum Scanned { typealias Payload = Int }
    @Transition(emits: [Scanned.self])
    fileprivate static func scan(_ source: consuming Valid) -> Change<Used, Effect.Scan> {
        let seat = source.seat
        return Change(Used(seat: seat), effects: [.scanned(seat)])
    }
}

/// A lookup that only an actor host owns, whose schema declares its own `Event` and `Active` types, so
/// it spells those markers with their module.
@StateMachine(mode: .shared, owners: [.actorHost])
nonisolated private enum ActorLookup: Sendable {
    struct Idle: Sendable {}
    struct Looking: Sendable {}
    /// A domain type that shadows the event marker inside the schema.
    enum Event: Sendable { case looked }
    /// A domain type that shadows the scope marker inside the schema.
    struct Active: Sendable {}
    @Initial case idle(Idle = Idle())
    case looking(Looking)
    enum Scope {
        @StateMachine.Active(in: [Looking.self])
        case lookup
    }
    enum Input: Sendable { case look }
    @Operation(scope: Scope.lookup)
    enum Find { typealias Output = Int }
    @StateMachine.Event
    enum Found { typealias Payload = Int }
    @Transition(on: Input.look, starts: [Find.self])
    fileprivate static func look(_ source: Idle) -> Change<Looking, Effect.Look> { Change(Looking(), effects: [.find]) }
    @Transition(onSuccess: Find.self, emits: [Found.self])
    fileprivate static func found(_ source: Looking, _ count: Find.Output) -> Change<Idle, Effect.Found> {
        Change(Idle(), effects: [.found(count)])
    }
}

/// A counter that only a shared owner owns.
@StateMachine(mode: .shared, owners: [.shared])
nonisolated private enum SharedTally: Sendable {
    struct Counting: Sendable { var count = 0 }
    @Initial case counting(Counting = Counting())
    enum Input: Sendable { case add }
    @Transition(on: Input.add)
    fileprivate static func add(_ source: Counting) -> Counting { Counting(count: source.count + 1) }
}

/// An isolated note that only a main-actor owner owns.
@StateMachine(mode: .isolated, owners: [.mainActorHost])
nonisolated private enum MainActorNote {
    struct Draft { var text = "" }
    @Initial case draft(Draft = Draft())
    enum Input { case edit(String) }
    @Event
    enum Edited { typealias Payload = String }
    @Transition(on: Input.edit, emits: [Edited.self])
    fileprivate static func edit(_ source: Draft, _ text: String) -> Change<Draft, Effect.Edit> {
        Change(Draft(text: text), effects: [.edited(text)])
    }
}

/// Handler calls recorded in the order they ran.
private final class EventLog: Sendable {
    private let entries = OSAllocatedUnfairLock<[String]>(initialState: [])
    func record(_ entry: String) { entries.withLock { $0.append(entry) } }
    var recorded: [String] { entries.withLock { $0 } }
}

/// A main-actor owner's handler calls, and the owner they act on.
@MainActor private final class MainActorEventLog {
    var recorded: [String] = []
    var checkout: Checkout.MainActorHost?
}

/// A one-shot event a test raises to let a driver finish, instead of relying on scheduling order.
private struct Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() { (stream, continuation) = AsyncStream<Void>.makeStream() }
    func open() { continuation.yield(()) }
    func wait() async {
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

@Suite(.timeLimit(.minutes(1))) struct GraphStructureTests {
    private struct Unexpected: Error {}

    /// Spells a `Local` command so a batch compares at once.
    private func spelled(_ command: Checkout.Command) -> String {
        switch command {
        case .cancel: "cancel"
        case .charge(let work): "charge \(work.input)"
        case .tracked(let text): "tracked \(text)"
        case .pinged: "pinged"
        }
    }

    // MARK: Graph export

    @Test func theGraphRendersDeterministicMermaidAndDot() {
        #expect(
            Door.graph.mermaid() == """
                stateDiagram-v2
                    state "closed" as p0
                    state "open" as p1
                    state "broken" as p2
                    [*] --> p0
                    [*] --> p1 : restored
                    p0 --> p1 : swingOpen
                    p1 --> p0 : swingShut
                    p0 --> p2 : kick
                    p1 --> p2 : kick
                    p2 --> [*]

                """
        )
        #expect(
            Door.graph.dot() == """
                digraph "Door" {
                    entry [shape=point];
                    p0 [label="closed"];
                    p1 [label="open"];
                    p2 [label="broken", peripheries=2];
                    entry -> p0;
                    entry -> p1 [label="restored", style=dashed];
                    p0 -> p1 [label="swingOpen"];
                    p1 -> p0 [label="swingShut"];
                    p0 -> p2 [label="kick"];
                    p1 -> p2 [label="kick"];
                }

                """
        )
    }

    /// The graph keeps each outcome's authored spelling and reports separately whether it can happen.
    @Test func theGraphKeepsAuthoredOutcomeSpellingsAndReportsWhichOutcomesHappen() throws {
        let operations = Spelled.graph.operations
        #expect(operations.map(\.failure) == ["Nothing", "Swift::Never", "Problem"])
        #expect(operations.map(\.output) == ["Swift::Void", "Swift::Void", "Nothing"])
        #expect(operations.map(\.canFail) == [false, false, true])
        #expect(operations.map(\.canSucceed) == [true, true, false])
        let decoded = try JSONDecoder().decode(StateMachineGraph.self, from: JSONEncoder().encode(Spelled.graph))
        #expect(decoded == Spelled.graph)
    }

    /// An omitted type is exported through the standard library's module, which no declaration of the
    /// schema or the namespace shadows.
    @Test func theGraphSpellsAnOmittedTypeThroughItsModule() {
        Shadowing.Load.check()
        Shadowing.Logged.check()
        let load = Shadowing.graph.operations.first
        #expect(load?.input == "Swift::Void" && load?.output == "Swift::Void" && load?.failure == "Swift::Never")
        #expect(Shadowing.graph.events.map(\.payload) == ["Swift::Void"])
    }

    @Test func theGraphDescribesDeclarationsAndRoundTripsThroughCoding() throws {
        let graph = Checkout.graph
        #expect(graph.name == "Checkout")
        #expect(graph.initial == "cart")
        #expect(graph.terminal == ["paid"])
        #expect(graph.restorable.isEmpty)
        #expect(graph.phases.map(\.id) == ["cart", "paying", "confirming", "paid"])
        #expect(graph.scopes == [StateMachineGraph.Scope(id: "payment", activeIn: ["paying", "confirming"])])
        let charge = try #require(graph.operations.first)
        #expect(charge.id == "Charge" && charge.scope == "payment" && charge.activeIn == ["paying", "confirming"])
        #expect(charge.admission == .latest && charge.input == "[String]" && charge.failure == "Swift::Never")
        #expect(charge.canFail == false && charge.canSucceed)
        #expect(graph.events.map(\.id) == ["Tracked", "Pinged"])
        #expect(graph.events.map(\.payload) == ["String", "Swift::Void"])
        #expect(
            graph.edges.map(\.id) == [
                "cart.add", "cart.pay", "paying.confirm", "paying.charged", "confirming.charged",
            ]
        )
        let pay = try #require(graph.edges.first { $0.id == "cart.pay" })
        #expect(pay.trigger == .input("pay") && pay.starts == ["Charge"] && pay.emits == ["Tracked", "Pinged"])
        #expect(graph.edges.last?.trigger == .success("Charge"))
        let decoded = try JSONDecoder().decode(StateMachineGraph.self, from: JSONEncoder().encode(graph))
        #expect(decoded == graph)
        #expect(decoded.hashValue == graph.hashValue)
        // The export records its format, the data mode, and the owners the schema generates.
        #expect(graph.formatVersion == StateMachineGraph.currentFormatVersion)
        #expect(graph.mode == .shared)
        #expect(graph.owners == [.owned, .local, .shared, .actorHost, .mainActorHost, .isolatedHost])
        #expect(Ticket.graph.mode == .ownedOnly && Ticket.graph.owners == [.owned])
        let encoded = try #require(String(data: JSONEncoder().encode(Ticket.graph), encoding: .utf8))
        #expect(encoded.contains(#""formatVersion":2"#) && encoded.contains(#""mode":"ownedOnly""#))
        #expect(encoded.contains(#""owners":["owned"]"#))
        let future = encoded.replacingOccurrences(of: #""formatVersion":2"#, with: #""formatVersion":3"#)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StateMachineGraph.self, from: Data(future.utf8))
        }
        #expect(Door.graph.restorable == ["open"])
        #expect(Coin.graph.routers.map(\.candidates) == [["up.stay", "up.turn"]])
        #expect(Coin.graph.edges.map(\.router) == ["up.toss", "up.toss", nil])
        #expect(Ticket.graph.edges.map(\.trigger) == [.direct])
    }

    // MARK: Scope eligibility

    @Test func workKeepsItsAuthorityAcrossEveryPhaseOfItsScope() throws {
        var checkout = Checkout.Local()
        try checkout.send(.pay)
        let batch = try #require(checkout.drainCommands().first)
        guard
            let work = batch.commands.lazy
                .compactMap({ command -> Checkout.ChargeWork? in
                    if case .charge(let work) = command { return work }
                    return nil
                })
                .first
        else { throw Unexpected() }
        try checkout.send(.confirm)
        guard case .committed(let receipt) = checkout.deliver(work.succeeded("r1")) else { throw Unexpected() }
        guard case .paid(let paid) = receipt.snapshot else { throw Unexpected() }
        #expect(paid.value.receipt == "r1")
        // The completed work is retired without a cancellation, so the batch holds only the event its edge emitted.
        #expect(checkout.drainCommands().last?.commands.map(spelled) == ["tracked paid r1 after confirming"])
    }

    // MARK: Events

    @Test func anOwnedPhaseReturnsItsEventsAmongItsEffects() {
        let added = Checkout.owned().add("tea")
        #expect(added.effects == [.tracked("added tea")])
        let paying = added.next.pay()
        #expect(paying.effects == [.tracked("paying"), .charge(["tea"]), .pinged])
        #expect(paying.effects.map(\.effect) == [.tracked("paying"), .charge(["tea"]), .pinged])
        let ticket = Ticket.owned(Ticket.Valid(seat: 4)).scan()
        guard case .scanned(let seat) = ticket.effects.first else {
            Issue.record("Expected the scanned event")
            return
        }
        #expect(seat == 4 && ticket.effects.count == 1)
        #expect(ticket.next.withValue { $0.seat } == 4)
    }

    @Test func aLocalOwnerCarriesEventsInItsBatchInAuthoredOrder() throws {
        var checkout = Checkout.Local()
        try checkout.send(.add("tea"))
        try checkout.send(.pay)
        let batches = checkout.drainCommands()
        #expect(
            batches.map { $0.commands.map(spelled) } == [
                ["tracked added tea"], ["tracked paying", "charge [\"tea\"]", "pinged"],
            ]
        )
        var tally = Tally.Local()
        try tally.send(.add)
        try tally.send(.add)
        let counted = tally.drainCommands().flatMap(\.commands)
            .map { command -> Int in
                switch command {
                case .counted(let count): count
                }
            }
        #expect(counted == [1, 2])
        tally.close()
        #expect(tally.drainCommands().map(\.terminal) == [true])
        let quiescent = tally.isQuiescent
        #expect(quiescent)
    }

    @Test func aSharedOwnerHandlesEventsInCommitOrderBeforeObserversSeeTheCommit() async throws {
        let log = EventLog()
        let owner = OSAllocatedUnfairLock<Checkout.Shared?>(initialState: nil)
        let checkout = Checkout.Shared(
            chargeDriver: { _ in "r1" },
            onTracked: { text in
                // A handler runs outside the owner's critical section, so it may read the owner.
                let revision = owner.withLock { $0 }?.snapshot().revision ?? 0
                log.record("\(text) at \(revision)")
            },
            onPinged: { log.record("pinged") }
        )
        owner.withLock { $0 = checkout }
        let snapshots = try checkout.snapshots()
        try checkout.send(.add("tea"))
        try checkout.send(.add("cake"))
        try checkout.send(.pay)
        for await snapshot in snapshots {
            guard case .paid = snapshot else { continue }
            break
        }
        let recorded = log.recorded.map { $0.components(separatedBy: " at ") }
        #expect(recorded.map(\.first) == ["added tea", "added cake", "paying", "pinged", "paid r1"])
        // Each tracked handler read a revision at least as new as the commit that emitted its event.
        let revisions = recorded.compactMap { $0.count == 2 ? UInt64($0[1]) : nil }
        #expect(zip(revisions, [1, 2, 3, 4] as [UInt64]).allSatisfy { $0 >= $1 } && revisions.count == 4)
        await checkout.shutdown()
        owner.withLock { $0 = nil }
    }

    @Test func anActorHostHandlesEventsInCommitOrderBeforeObserversSeeTheCommit() async throws {
        let log = EventLog()
        let checkout = Checkout.ActorHost(
            chargeDriver: { _ in "r1" },
            onTracked: { log.record($0) },
            onPinged: { log.record("pinged") }
        )
        let snapshots = try await checkout.snapshots()
        let receipt = try await checkout.send(.add("tea"))
        _ = await checkout.flush(through: receipt)
        #expect(log.recorded == ["added tea"])
        try await checkout.send(.pay)
        for await snapshot in snapshots {
            guard case .paid = snapshot else { continue }
            break
        }
        #expect(log.recorded == ["added tea", "paying", "pinged", "paid r1"])
        await checkout.shutdown()
    }

    @MainActor @Test func aMainActorHostHandlesEventsAfterTheCommitAndAllowsAHandlerToSend() async throws {
        let log = MainActorEventLog()
        let charged = Gate()
        let checkout = Checkout.MainActorHost(
            chargeDriver: { _ in
                await charged.wait()
                return "r1"
            },
            onTracked: { log.recorded.append($0) },
            onPinged: {
                log.recorded.append("pinged")
                // Handlers never run inside the owner's mutation, so this commits at once.
                if case .confirming = (try? log.checkout?.send(.confirm))?.snapshot {
                    log.recorded.append("confirmed")
                }
            }
        )
        log.checkout = checkout
        let snapshots = try checkout.snapshots()
        let receipt = try checkout.send(.pay)
        // Admission returned before any handler ran; the batch is processed on a later turn.
        #expect(log.recorded.isEmpty)
        _ = await checkout.flush(through: receipt)
        #expect(log.recorded == ["paying", "pinged", "confirmed"])
        charged.open()
        for await snapshot in snapshots {
            guard case .paid = snapshot else { continue }
            break
        }
        // The charge kept its authority when the handler moved the checkout within its scope.
        #expect(log.recorded == ["paying", "pinged", "confirmed", "paid r1 after confirming"])
        await checkout.shutdown()
        log.checkout = nil
    }

    // MARK: Owner selection

    @Test func aSingleManagedOwnerSelectionRunsItsWork() async throws {
        let log = EventLog()
        let lookup = ActorLookup.ActorHost(findDriver: { 3 }, onFound: { log.record("found \($0)") })
        let snapshots = try await lookup.snapshots()
        try await lookup.send(.look)
        // The completion's commit is revision 2; a latest-value sequence may skip revision 1.
        for await snapshot in snapshots where snapshot.revision >= 2 { break }
        #expect(log.recorded == ["found 3"])
        await lookup.shutdown()
        let tally = SharedTally.Shared()
        #expect(try tally.send(.add).revision == 1)
        await tally.shutdown()
    }

    @MainActor @Test func aMainActorOnlySelectionTakesMainActorHandlers() async throws {
        let log = MainActorEventLog()
        let note = MainActorNote.MainActorHost(onEdited: { log.recorded.append($0) })
        let receipt = try note.send(.edit("hello"))
        _ = await note.flush(through: receipt)
        #expect(log.recorded == ["hello"])
        await note.shutdown()
    }

    @Test func anOwnedOnlySelectionKeepsItsRouterTypes() throws {
        guard case .stay = Coin.owned(Coin.Up()).toss(true) else { throw Unexpected() }
        guard case .turn(let down) = Coin.owned(Coin.Up()).toss(false) else { throw Unexpected() }
        _ = down.back(true)
        #expect(Coin.Route.Toss.allCases == [.stay, .turn])
    }
}
