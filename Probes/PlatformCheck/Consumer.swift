import Combine
import Observation
import StateMachine
import StateMachineUI

@StateMachine(mode: .shared)
nonisolated private enum PlatformWorkflow: Sendable {
    struct Idle: Sendable { let value: Int }
    @Initial case idle(Idle)
    enum Input: Sendable { case edit(Int) }

    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: Idle, _ value: Int) -> Idle {
        Idle(value: value)
    }
}

/// A shared graph whose one fallible operation runs on every managed owner.
@StateMachine(mode: .shared)
nonisolated private enum PlatformLookup: Sendable {
    struct Idle: Sendable {}
    struct Loading: Sendable { let query: Int }
    struct Loaded: Sendable { let value: Int }
    struct Failed: Sendable {}
    enum Problem: Error, Sendable { case unavailable }
    @Initial case idle(Idle = Idle())
    case loading(Loading)
    @Terminal case loaded(Loaded)
    @Terminal case failed(Failed)
    enum Input: Sendable { case load(Int) }
    @Operation(activeIn: [Loading.self])
    enum Fetch {
        typealias Input = Int
        typealias Output = Int
        typealias Failure = Problem
    }
    @Transition(on: Input.load, starts: [Fetch.self])
    fileprivate static func load(_ source: Idle, _ query: Int) -> Change<Loading, Effect.Load> {
        Change(Loading(query: query), effects: [.fetch(query)])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func loaded(_ source: Loading, _ value: Fetch.Output) -> Loaded { Loaded(value: value) }
    @Transition(onFailure: Fetch.self)
    fileprivate static func failed(_ source: Loading, _ failure: Fetch.Failure) -> Failed { Failed() }
}

/// An isolated graph whose values stay on the main actor.
@StateMachine(mode: .isolated)
nonisolated private enum PlatformNote {
    struct Draft: ~Sendable { let text: String }
    struct Saved: ~Sendable { let text: String }
    @Initial case draft(Draft)
    @Terminal case saved(Saved)
    enum Input: ~Sendable { case save }
    @Transition(on: Input.save)
    fileprivate static func save(_ source: Draft) -> Saved { Saved(text: source.text) }
}

/// Exercises the public shared-owner path in a linked library consumer.
public func stateMachinePlatformCheck() throws -> UInt64 {
    let owner = PlatformLookup.Shared(fetchDriver: { _ in .failure(.unavailable) })
    guard case .idle(let idle) = owner.snapshot(),
        case .committed(let receipt) = owner.commit(idle.load(1))
    else { return 0 }
    let after = owner.snapshot()
    let closing = owner.close()
    guard !after.isClosed, closing.snapshot.isClosed, closing.revision > after.revision else { return 0 }
    return receipt.revision + after.revision + closing.revision
}

/// Links a client-authored macro expansion and its manually driven value owner.
public func stateMachineSchemaPlatformCheck() throws -> UInt64 {
    var owner = PlatformWorkflow.Local(PlatformWorkflow.Idle(value: 0))
    guard case .idle(let initial) = owner.snapshot(),
        case .committed(let receipt) = owner.commit(initial.edit(1))
    else { return 0 }
    // A graph without operations queues no command batches to drain.
    guard owner.close().revision == receipt.revision + 1 else { return 0 }
    return receipt.revision
}

/// Links the MainActor facade, its presentations, and background ingress.
@MainActor public func stateMachineUIPlatformCheck() throws -> UInt64 {
    let presentation = StateMachineObservableObject(
        PlatformLookup.MainActorHost(fetchDriver: { _ in .failure(.unavailable) })
    )
    let receipt = try presentation.send(.load(2))
    let background = SnapshotObservableObject(presentation.snapshot, revision: { $0.revision })
    let ingress = MainActorSnapshotIngress<PlatformLookup.Snapshot> { [weak background] in
        background?.apply($0)
    }
    ingress.offer(receipt.snapshot, revision: receipt.revision)
    ingress.cancel()
    presentation.close()
    return presentation.snapshot.revision
}

/// Links native actor admission and managed shutdown through normal public imports.
public func stateMachineActorPlatformCheck() async throws -> UInt64 {
    let owner = PlatformLookup.ActorHost(fetchDriver: { _ in .failure(.unavailable) })
    let receipt = try await owner.send(.load(3))
    await owner.shutdown()
    return receipt.revision
}

/// Links the snapshot sequences of every hosted owner and the presentation that observes one.
@MainActor public func stateMachineSequencePlatformCheck() async throws -> UInt64 {
    let note = PlatformNote.MainActorHost(PlatformNote.Draft(text: "platform-sequence"))
    var last: UInt64 = 0
    for await revision in try note.snapshots({ $0.revision }).prefix(1) { last += revision }
    var snapshots = try note.snapshots()
    while let snapshot = await snapshots.next() {
        last = snapshot.revision
        if !snapshot.isClosed { note.close() }
    }
    let shared = PlatformLookup.Shared(fetchDriver: { _ in .failure(.unavailable) })
    let presentation = SnapshotObservableObject(shared.snapshot())
    presentation.observe(try shared.snapshots())
    for await snapshot in try shared.snapshots() {
        last += snapshot.revision
        if !snapshot.isClosed { shared.close() }
    }
    await presentation.follow(try shared.snapshots())
    if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
        let model = SnapshotPresentation(shared.snapshot())
        await model.follow(try shared.snapshots())
    }
    presentation.stopObserving()
    let actor = PlatformLookup.ActorHost(fetchDriver: { _ in .failure(.unavailable) })
    for await snapshot in try await actor.snapshots() {
        last += snapshot.revision
        if !snapshot.isClosed { await actor.close() }
    }
    let main = PlatformLookup.MainActorHost(fetchDriver: { _ in .failure(.unavailable) })
    let sequence: PlatformLookup.Snapshots = try main.snapshots()
    for await revision in sequence.map({ $0.revision }).prefix(1) { last += revision }
    // Another owner's sequence seeds the presentation with its first element.
    presentation.observe(try main.snapshots())
    presentation.stopObserving()
    // A host of one's own builds a sequence from its own callbacks.
    let own = try SnapshotSequence<UInt64> { receive, finish in
        receive(1)
        finish()
        return SnapshotSubscription(onCancel: {})
    }
    for await revision in own { last += revision }
    await main.shutdown()
    await note.shutdown()
    await shared.shutdown()
    await actor.shutdown()
    return last
}

/// The actor that owns a confined host in the platform check.
private actor PlatformDesk {
    private var host: PlatformLookup.IsolatedHost<PlatformDesk>?

    func run() async throws -> UInt64 {
        let host = PlatformLookup.IsolatedHost(isolation: self, fetchDriver: { _, query in .success(query) })
        self.host = host
        let receipt = try host.send(.load(4))
        var counted: UInt64 = 0
        for await revision in try host.snapshots({ $0.revision }) {
            counted = revision
            if revision > receipt.revision { break }
        }
        await host.shutdown()
        return counted
    }
}

/// Links the confined host, Observation tracking, Combine publishers, distinct projections, a shared
/// executor, and source-bound presentations at every deployment floor.
@MainActor public func stateMachineHostPlatformCheck() async throws -> UInt64 {
    var total = try await PlatformDesk().run()
    let main = PlatformLookup.MainActorHost(fetchDriver: { _ in .failure(.unavailable) })
    if #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
        withObservationTracking { _ = main.currentSnapshot } onChange: {}
        func observable(_ host: some Observable) {}
        observable(main)
    }
    var published: [UInt64] = []
    let cancellable = try main.snapshotPublisher().sink { published.append($0.revision) }
    let presentation = SnapshotObservableObject(main.snapshot())
    try presentation.observe(main)
    let shared = PlatformLookup.Shared(fetchDriver: { _ in .failure(.unavailable) })
    try presentation.observe(shared)
    let distinct = try shared.distinctSnapshots { $0.isClosed }
    shared.close()
    for await closed in distinct { total += closed ? 1 : 0 }
    let anchor = PlatformDesk()
    let actor = PlatformLookup.ActorHost(fetchDriver: { _ in .failure(.unavailable) }, isolatedTo: anchor)
    try await presentation.observe(actor)
    presentation.stopObserving()
    total += try await actor.send(.load(5)).revision
    await actor.shutdown()
    cancellable.cancel()
    await main.shutdown()
    return total + UInt64(published.count)
}

/// Links the manual harness, graph coverage, and each controlled driver form of the testing
/// product at every deployment floor.
public func stateMachineTestingPlatformCheck() async throws -> Int {
    var test = ManualMachineTest(PlatformLookup.Local())
    try test.send(.load(6))
    let works = test.drainFlattenedCommands().compactMap { command -> PlatformLookup.FetchWork? in
        if case .fetch(let work) = command { work } else { nil }
    }
    guard let work = works.first, case .committed = test.deliver(.fetch(work.succeeded(7))) else { return 0 }
    _ = test.acknowledgeExecution(work.execution)
    var coverage = GraphCoverage(for: PlatformLookup.Local.self)
    coverage.record(test)
    let fetch = ControlledDriver<Int, Int, PlatformLookup.Problem>()
    let owner = PlatformLookup.Shared(fetchDriver: fetch.run)
    try owner.send(.load(8))
    let call = try await fetch.nextStarted()
    call.succeed(call.input)
    await owner.shutdown()
    let keyed = KeyedControlledDriver<Int, Void, Int, Never>()
    let confined = await PlatformBench().startedCount()
    return coverage.exercisedEdgeIDs.count + fetch.startedCount + keyed.startedCount + confined
}

/// The actor that owns the confined controlled drivers in the platform check.
private actor PlatformBench {
    let save = IsolatedControlledDriver<PlatformBench, PlatformNote.Draft, PlatformNote.Saved, Never>()
    let open = KeyedIsolatedControlledDriver<PlatformBench, Int, PlatformNote.Draft, PlatformNote.Saved, Never>()

    func startedCount() -> Int { save.startedCount + open.startedCount }
}

/// Links the MainActor controlled drivers with values that stay on the main actor.
@MainActor public func stateMachineMainActorTestingPlatformCheck() async throws -> Int {
    let save = MainActorControlledDriver<PlatformNote.Draft, PlatformNote.Saved, Never>()
    let open = KeyedMainActorControlledDriver<Int, PlatformNote.Draft, PlatformNote.Saved, Never>()
    return save.startedCount + open.startedCount
}
