import StateMachine
import Testing
import os

/// Counts evaluations of the default that `CountedDefault` declares.
private let evaluations = OSAllocatedUnfairLock(initialState: 0)

@StateMachine(mode: .shared)
nonisolated private enum PlainDefault: Sendable {
    struct Idle: Sendable { var label = "default" }
    struct Done: Sendable {}
    @Initial case idle(Idle = .init())
    @Terminal case done(Done)
    enum Input: Sendable { case finish }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Idle) -> Done { Done() }
}

@StateMachine(mode: .shared)
nonisolated private enum CountedDefault: Sendable {
    struct Idle: Sendable { let serial: Int }
    struct Done: Sendable {}
    @Initial case idle(Idle = CountedDefault.makeIdle())
    @Terminal case done(Done)
    enum Input: Sendable { case finish }
    static func makeIdle() -> Idle {
        Idle(
            serial: evaluations.withLock { count in
                count += 1
                return count
            }
        )
    }
    @Transition(on: Input.finish)
    fileprivate static func finish(_ source: Idle) -> Done { Done() }
}

@StateMachine(mode: .shared)
nonisolated private enum ClosureLookup: Sendable {
    struct Idle: Sendable { var origin: String }
    struct Loading: Sendable {
        var query: String
        var log: [String] = []
    }
    @Initial case idle(Idle = makeIdle())
    case loading(Loading)
    enum Scope {
        @Active(in: [Loading.self])
        case fetch
        @Active(in: [Loading.self])
        case audit
        @Active(in: [Loading.self])
        case hook
    }
    enum Input: Sendable { case search(String) }
    enum Rejection: Error, Sendable { case negative }
    @Operation(scope: Scope.fetch, admission: .latest)
    enum Fetch {
        typealias Input = String
        typealias Output = String
        typealias Failure = Never
    }
    @Operation(scope: Scope.audit, admission: .latest)
    enum Audit {
        typealias Input = String
        typealias Output = String
        typealias Failure = Never
    }
    /// Its effect case is spelled like a callback parameter; the `Driver` suffix keeps its label distinct from
    /// every parameter a managed owner takes.
    @Operation(scope: Scope.hook, admission: .latest)
    enum OnReconciliationRequired {
        typealias Input = String
        typealias Output = String
        typealias Failure = Never
    }
    static func makeIdle() -> Idle { Idle(origin: "default") }
    @Restoration
    fileprivate static func restore(_ saved: Int) throws(Rejection) -> Restoration {
        guard saved >= 0 else { throw .negative }
        return .idle(Idle(origin: "restored \(saved)"))
    }
    @Transition(on: Input.search, starts: [Fetch.self, Audit.self, OnReconciliationRequired.self])
    fileprivate static func search(_ source: Idle, _ query: String) -> Change<Loading, Effect.Search> {
        Change(Loading(query: query), effects: [.fetch(query), .audit(query), .onReconciliationRequired(query)])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func fetched(_ source: Loading, _ output: Fetch.Output) -> Loading {
        Loading(query: source.query, log: source.log + ["fetch=" + output])
    }
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: Loading, _ output: Audit.Output) -> Loading {
        Loading(query: source.query, log: source.log + ["audit=" + output])
    }
    @Transition(onSuccess: OnReconciliationRequired.self)
    fileprivate static func hooked(_ source: Loading, _ output: OnReconciliationRequired.Output) -> Loading {
        Loading(query: source.query, log: source.log + ["onReconciliationRequired=" + output])
    }
}

/// The initial payload's declared default reaches every fresh entry point and nothing else.
@Suite(.timeLimit(.minutes(1))) struct DeclaredInitialDefaultTests {
    private func label(_ snapshot: PlainDefault.Snapshot) -> String? {
        guard case .idle(let idle) = snapshot else { return nil }
        return idle.value.label
    }

    private func serial(_ snapshot: CountedDefault.Snapshot) -> Int? {
        guard case .idle(let idle) = snapshot else { return nil }
        return idle.value.serial
    }

    private func origin(_ snapshot: ClosureLookup.Snapshot) -> String? {
        guard case .idle(let idle) = snapshot else { return nil }
        return idle.value.origin
    }

    @MainActor @Test func everyFreshEntryPointConstructsTheDeclaredDefault() async {
        let local = PlainDefault.Local()
        let shared = PlainDefault.Shared()
        let actor = PlainDefault.ActorHost()
        let main = PlainDefault.MainActorHost()
        #expect(label(local.snapshot()) == "default")
        #expect(label(shared.snapshot()) == "default")
        #expect(label(await actor.snapshot()) == "default")
        #expect(label(main.snapshot()) == "default")
        #expect(PlainDefault.owned().withValue { $0.label } == "default")
        await shared.shutdown()
        await actor.shutdown()
        await main.shutdown()
    }

    @MainActor @Test func anExplicitPayloadOverridesTheDefault() async {
        let explicit = PlainDefault.Idle(label: "explicit")
        let local = PlainDefault.Local(explicit)
        let shared = PlainDefault.Shared(explicit)
        let actor = PlainDefault.ActorHost(explicit)
        let main = PlainDefault.MainActorHost(explicit)
        #expect(label(local.snapshot()) == "explicit")
        #expect(label(shared.snapshot()) == "explicit")
        #expect(label(await actor.snapshot()) == "explicit")
        #expect(label(main.snapshot()) == "explicit")
        #expect(PlainDefault.owned(explicit).withValue { $0.label } == "explicit")
        await shared.shutdown()
        await actor.shutdown()
        await main.shutdown()
    }

    @MainActor @Test func aStaticFunctionDefaultIsEvaluatedOncePerConstructionAndNeverForAnExplicitPayload() async {
        let start = evaluations.withLock { $0 }
        let local = CountedDefault.Local()
        let shared = CountedDefault.Shared()
        let actor = CountedDefault.ActorHost()
        let main = CountedDefault.MainActorHost()
        let owned = CountedDefault.owned()
        #expect(serial(local.snapshot()) == start + 1)
        #expect(serial(shared.snapshot()) == start + 2)
        #expect(serial(await actor.snapshot()) == start + 3)
        #expect(serial(main.snapshot()) == start + 4)
        #expect(owned.withValue { $0.serial } == start + 5)
        #expect(evaluations.withLock { $0 } == start + 5)
        let explicit = CountedDefault.Local(CountedDefault.Idle(serial: -1))
        #expect(serial(explicit.snapshot()) == -1)
        #expect(evaluations.withLock { $0 } == start + 5)
        await shared.shutdown()
        await actor.shutdown()
        await main.shutdown()
    }

    @MainActor @Test func theDefaultAlsoReachesOwnersThatTakeOneClosurePerOperation() async {
        let local = ClosureLookup.Local()
        let shared = ClosureLookup.Shared(
            fetchDriver: { _ in "" },
            auditDriver: { _ in "" },
            onReconciliationRequiredDriver: { _ in "" }
        )
        let actor = ClosureLookup.ActorHost(
            fetchDriver: { _ in "" },
            auditDriver: { _ in "" },
            onReconciliationRequiredDriver: { _ in "" }
        )
        let main = ClosureLookup.MainActorHost(
            fetchDriver: { _ in "" },
            auditDriver: { _ in "" },
            onReconciliationRequiredDriver: { _ in "" }
        )
        #expect(origin(local.snapshot()) == "default")
        #expect(origin(shared.snapshot()) == "default")
        #expect(origin(await actor.snapshot()) == "default")
        #expect(origin(main.snapshot()) == "default")
        #expect(ClosureLookup.owned().withValue { $0.origin } == "default")
        let explicit = ClosureLookup.Shared(
            ClosureLookup.Idle(origin: "explicit"),
            fetchDriver: { _ in "" },
            auditDriver: { _ in "" },
            onReconciliationRequiredDriver: { _ in "" }
        )
        #expect(origin(explicit.snapshot()) == "explicit")
        await shared.shutdown()
        await actor.shutdown()
        await main.shutdown()
        await explicit.shutdown()
    }
}

/// One closure per operation selects the same drivers as the `Drivers` value.
@Suite(.timeLimit(.minutes(1))) struct DriverInitializerTests {
    private static let settled = ["audit=A", "fetch=F", "onReconciliationRequired=O"]

    private func origin(_ snapshot: ClosureLookup.Snapshot) -> String? {
        guard case .idle(let idle) = snapshot else { return nil }
        return idle.value.origin
    }

    /// The three recorded driver inputs, in the order the operations were started.
    private final class Inputs: Sendable {
        private let storage = OSAllocatedUnfairLock<[String]>(initialState: [])
        func record(_ input: String) { storage.withLock { $0.append(input) } }
        var all: [String] { storage.withLock { $0 } }
    }

    private func settledLog(_ snapshot: ClosureLookup.Snapshot) -> [String]? {
        guard case .loading(let loading) = snapshot, loading.value.log.count == 3 else { return nil }
        return loading.value.log.sorted()
    }

    @Test func aSharedOwnerRunsEachClosureForItsOwnOperation() async throws {
        let inputs = Inputs()
        let owner = ClosureLookup.Shared(
            fetchDriver: { input in
                inputs.record(input)
                return "F"
            },
            auditDriver: { input in
                inputs.record(input)
                return "A"
            },
            onReconciliationRequiredDriver: { input in
                inputs.record(input)
                return "O"
            }
        )
        let snapshots = try owner.snapshots()
        try owner.send(.search("q"))
        var log: [String]?
        for await snapshot in snapshots {
            log = settledLog(snapshot)
            if log != nil { break }
        }
        #expect(log == Self.settled)
        #expect(inputs.all == ["q", "q", "q"])
        await owner.shutdown()
    }

    @Test func anActorOwnerRunsEachClosureForItsOwnOperation() async throws {
        let inputs = Inputs()
        let owner = ClosureLookup.ActorHost(
            fetchDriver: { input in
                inputs.record(input)
                return "F"
            },
            auditDriver: { input in
                inputs.record(input)
                return "A"
            },
            onReconciliationRequiredDriver: { input in
                inputs.record(input)
                return "O"
            }
        )
        let snapshots = try await owner.snapshots()
        try await owner.send(.search("q"))
        var log: [String]?
        for await snapshot in snapshots {
            log = settledLog(snapshot)
            if log != nil { break }
        }
        #expect(log == Self.settled)
        #expect(inputs.all == ["q", "q", "q"])
        await owner.shutdown()
    }

    @MainActor @Test func aMainActorOwnerRunsEachClosureOnTheMainActor() async throws {
        let inputs = Inputs()
        let owner = ClosureLookup.MainActorHost(
            fetchDriver: { input in
                MainActor.assertIsolated()
                inputs.record(input)
                return "F"
            },
            auditDriver: { input in
                MainActor.assertIsolated()
                inputs.record(input)
                return "A"
            },
            onReconciliationRequiredDriver: { input in
                MainActor.assertIsolated()
                inputs.record(input)
                return "O"
            }
        )
        let snapshots = try owner.snapshots()
        try owner.send(.search("q"))
        var log: [String]?
        for await snapshot in snapshots {
            log = settledLog(snapshot)
            if log != nil { break }
        }
        #expect(log == Self.settled)
        #expect(inputs.all == ["q", "q", "q"])
        await owner.shutdown()
    }

    @Test func aRestoredSharedOwnerRunsTheSuppliedClosures() async throws {
        let owner = try ClosureLookup.Shared(
            restoring: 0,
            fetchDriver: { _ in "F" },
            auditDriver: { _ in "A" },
            onReconciliationRequiredDriver: { _ in "O" }
        )
        #expect(origin(owner.snapshot()) == "restored 0")
        let snapshots = try owner.snapshots()
        try owner.send(.search("q"))
        var log: [String]?
        for await snapshot in snapshots {
            log = settledLog(snapshot)
            if log != nil { break }
        }
        #expect(log == Self.settled)
        await owner.shutdown()
    }

    @Test func aRestoredActorOwnerRunsTheSuppliedClosures() async throws {
        let owner = try ClosureLookup.ActorHost(
            restoring: 0,
            fetchDriver: { _ in "F" },
            auditDriver: { _ in "A" },
            onReconciliationRequiredDriver: { _ in "O" }
        )
        #expect(origin(await owner.snapshot()) == "restored 0")
        let snapshots = try await owner.snapshots()
        try await owner.send(.search("q"))
        var log: [String]?
        for await snapshot in snapshots {
            log = settledLog(snapshot)
            if log != nil { break }
        }
        #expect(log == Self.settled)
        await owner.shutdown()
    }

    @MainActor @Test func aRestoredMainActorOwnerRunsTheSuppliedClosures() async throws {
        let owner = try ClosureLookup.MainActorHost(
            restoring: 0,
            fetchDriver: { _ in "F" },
            auditDriver: { _ in "A" },
            onReconciliationRequiredDriver: { _ in "O" }
        )
        #expect(origin(owner.snapshot()) == "restored 0")
        let snapshots = try owner.snapshots()
        try owner.send(.search("q"))
        var log: [String]?
        for await snapshot in snapshots {
            log = settledLog(snapshot)
            if log != nil { break }
        }
        #expect(log == Self.settled)
        await owner.shutdown()
    }

    @Test func aRejectedArchiveThrowsBeforeAnyClosureCanRun() async {
        let started = OSAllocatedUnfairLock(initialState: false)
        do {
            _ = try ClosureLookup.Shared(
                restoring: -1,
                fetchDriver: { _ in
                    started.withLock { $0 = true }
                    return "F"
                },
                auditDriver: { _ in "A" },
                onReconciliationRequiredDriver: { _ in "O" }
            )
            Issue.record("A negative archive was restored")
        } catch {
            #expect(error == .negative)
        }
        do {
            _ = try ClosureLookup.ActorHost(
                restoring: -1,
                fetchDriver: { _ in "F" },
                auditDriver: { _ in "A" },
                onReconciliationRequiredDriver: { _ in "O" }
            )
            Issue.record("A negative archive was restored")
        } catch {
            #expect(error == .negative)
        }
        #expect(!started.withLock { $0 })
    }

    @MainActor @Test func aRejectedArchiveThrowsFromTheMainActorOwnerToo() async {
        do {
            _ = try ClosureLookup.MainActorHost(
                restoring: -1,
                fetchDriver: { _ in "F" },
                auditDriver: { _ in "A" },
                onReconciliationRequiredDriver: { _ in "O" }
            )
            Issue.record("A negative archive was restored")
        } catch {
            #expect(error == .negative)
        }
    }
}
