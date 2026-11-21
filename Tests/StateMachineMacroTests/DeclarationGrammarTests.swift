import StateMachine
import StateMachineExamples
import Testing

/// One edit verb from three phases, with two failure types, and one retry verb whose phases start
/// different operations.
@StateMachine(mode: .shared)
nonisolated private enum Editor: Sendable, Equatable {
    struct Draft: Sendable, Equatable { var text = "" }
    struct Saving: Sendable, Equatable { let text: String }
    struct Failed: Sendable, Equatable { let text: String }
    @Initial case draft(Draft = Draft())
    case saving(Saving)
    case failed(Failed)
    enum Input: Sendable {
        case edit(String)
        case retry
    }
    enum DraftError: Error, Equatable, Sendable { case empty }
    enum SavingError: Error, Equatable, Sendable { case locked }
    enum SaveFailure: Error, Equatable, Sendable { case offline }
    @Operation(activeIn: [Saving.self])
    enum Save {
        typealias Input = String
        typealias Failure = SaveFailure
    }
    @Operation(activeIn: [Saving.self])
    enum Audit { typealias Input = String }
    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: Draft, _ text: String) throws(DraftError) -> Draft {
        guard !text.isEmpty else { throw .empty }
        return Draft(text: text)
    }
    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: Saving, _ text: String) throws(SavingError) -> Saving {
        throw .locked
    }
    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: Failed, _ text: String) throws(DraftError) -> Draft {
        guard !text.isEmpty else { throw .empty }
        return Draft(text: text)
    }
    @Transition(on: Input.retry, starts: [Save.self])
    fileprivate static func retry(_ source: Draft) -> Change<Saving, Effect.Draft.Retry> {
        Change(Saving(text: source.text), effects: [.save(source.text)])
    }
    @Transition(on: Input.retry, starts: [Save.self, Audit.self])
    fileprivate static func retry(_ source: Failed) -> Change<Saving, Effect.Failed.Retry> {
        Change(Saving(text: source.text), effects: [.save(source.text), .audit("retry")])
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Saving) -> Draft { Draft(text: source.text) }
    @Transition(onFailure: Save.self)
    fileprivate static func failed(_ source: Saving, _ failure: Save.Failure) -> Failed {
        Failed(text: source.text)
    }
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: Saving) -> Saving { source }
}

/// A sign-out taken from two phases by one authored function, and operations without input or output.
@StateMachine(mode: .shared)
nonisolated private enum Session: Sendable, Equatable {
    struct SignedOut: Sendable, Equatable {}
    struct Loading: Sendable, Equatable { let user: String }
    struct Loaded: Sendable, Equatable {
        let user: String
        let name: String
    }
    @Initial case signedOut(SignedOut = SignedOut())
    case loading(Loading)
    case loaded(Loaded)
    enum Input: Sendable {
        case signIn(String)
        case signOut
        case rename(String)
    }
    /// Forgets the session's credentials; it takes nothing and returns nothing.
    @Operation(activeIn: [SignedOut.self])
    enum Forget {}
    /// Fetches the signed-in user's name; it takes nothing.
    @Operation(activeIn: [Loading.self])
    enum Fetch { typealias Output = String }
    @Transition(on: Input.signIn, starts: [Fetch.self])
    fileprivate static func signIn(_ source: SignedOut, _ user: String) -> Change<Loading, Effect.SignIn> {
        Change(Loading(user: user), effects: [.fetch])
    }
    @Transition(onSuccess: Fetch.self)
    fileprivate static func fetched(_ source: Loading, _ name: String) -> Loaded {
        Loaded(user: source.user, name: name)
    }
    @Transition(from: [Loading.self, Loaded.self], on: Input.signOut, starts: [Forget.self])
    fileprivate static func signOut() -> Change<SignedOut, Effect.SignOut> {
        Change(SignedOut(), effects: [.forget])
    }
    @Transition(from: [SignedOut.self, Loaded.self], on: Input.rename)
    fileprivate static func rename(_ name: String) -> Loading { Loading(user: name) }
    @Transition(onSuccess: Forget.self)
    fileprivate static func forgotten(_ source: SignedOut) -> SignedOut { source }
}

/// A router whose candidate spells its failure through an alias, pinned to one public failure.
@StateMachine(mode: .shared)
nonisolated private enum Pinned: Sendable {
    struct Start: Sendable {}
    struct Left: Sendable {}
    struct Right: Sendable {}
    @Initial case start(Start = Start())
    @Terminal case left(Left)
    @Terminal case right(Right)
    enum Input: Sendable { case pick(Int) }
    enum Problem: Error, Equatable, Sendable { case negative, odd }
    typealias Alias = Problem
    @Transition(on: Input.pick)
    fileprivate static func goLeft(_ source: Start, _ value: Int) -> Left { Left() }
    @Transition(on: Input.pick)
    fileprivate static func goRight(_ source: Start, _ value: Int) throws(Alias) -> Right {
        guard value.isMultiple(of: 2) else { throw .odd }
        return Right()
    }
    @Route(on: Input.pick, failure: Problem.self)
    fileprivate static func pick(_ source: Start, _ value: Int) throws(Problem) -> Route.Pick {
        guard value >= 0 else { throw .negative }
        return value < 10 ? .goLeft : .goRight
    }
}

/// An archive whose phases are listed exactly, excluding a resting phase.
@StateMachine(mode: .shared)
nonisolated private enum Archive: Sendable {
    struct Draft: Sendable { var text = "" }
    struct Saving: Sendable { let text: String }
    struct Published: Sendable { let text: String }
    @Initial case draft(Draft = Draft())
    case saving(Saving)
    @Terminal case published(Published)
    enum Input: Sendable { case save }
    @Operation(activeIn: [Saving.self])
    enum Save { typealias Input = String }
    @Restoration(only: [Saving.self, Published.self])
    fileprivate static func restore(_ saved: String) -> Restoration {
        saved.hasPrefix("!") ? .published(Published(text: saved)) : .saving(Saving(text: saved))
    }
    @Transition(on: Input.save, starts: [Save.self])
    fileprivate static func save(_ source: Draft) -> Change<Saving, Effect.Save> {
        Change(Saving(text: source.text), effects: [.save(source.text)])
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Saving) -> Published {
        Published(text: source.text)
    }
}

/// One router name in two phases, choosing among the same edge names, with results per phase.
@StateMachine(mode: .shared)
nonisolated private enum Toggle: Sendable {
    struct Idle: Sendable {}
    struct Busy: Sendable {}
    @Initial case idle(Idle = Idle())
    case busy(Busy)
    enum Input: Sendable { case go(Int) }
    enum Refusal: Error, Equatable, Sendable { case negative }
    @Transition(on: Input.go)
    fileprivate static func stay(_ source: Idle, _ value: Int) -> Idle { source }
    @Transition(on: Input.go)
    fileprivate static func move(_ source: Idle, _ value: Int) -> Busy { Busy() }
    @Route(on: Input.go)
    fileprivate static func pick(_ source: Idle, _ value: Int) throws(Refusal) -> Route.Pick {
        guard value >= 0 else { throw .negative }
        return value > 0 ? .move : .stay
    }
    @Transition(on: Input.go)
    fileprivate static func stay(_ source: Busy, _ value: Int) -> Busy { source }
    @Transition(on: Input.go)
    fileprivate static func move(_ source: Busy, _ value: Int) -> Idle { Idle() }
    @Route(on: Input.go)
    fileprivate static func pick(_ source: Busy, _ value: Int) -> Route.Pick { value > 0 ? .move : .stay }
}

/// Unique phases that share an edge name and a discard edge taken from two phases.
@StateMachine(mode: .ownedOnly)
nonisolated private enum Token: ~Copyable {
    struct Fresh: ~Copyable { let id: Int }
    struct Used: ~Copyable { let id: Int }
    struct Spent: ~Copyable {}
    @Initial case fresh(Fresh)
    case used(Used)
    @Terminal case spent(Spent)
    enum Input { case use, discard }
    @Transition(on: Input.use)
    fileprivate static func use(_ source: consuming Fresh) -> Used { Used(id: source.id) }
    @Transition(on: Input.use)
    fileprivate static func use(_ source: consuming Used) -> Used { source }
    @Transition(from: [Fresh.self, Used.self], on: Input.discard)
    fileprivate static func discard() -> Spent { Spent() }
}

/// A confined graph with one router.
@StateMachine(mode: .isolated)
nonisolated private enum Confined {
    struct Idle {}
    struct Busy {}
    @Initial case idle(Idle = Idle())
    @Terminal case busy(Busy)
    enum Input { case go }
    @Transition(on: Input.go)
    fileprivate static func stay(_ source: Idle) -> Idle { source }
    @Transition(on: Input.go)
    fileprivate static func move(_ source: Idle) -> Busy { Busy() }
    @Route(on: Input.go)
    fileprivate static func pick(_ source: Idle) -> Route.Pick { .move }
}

@Suite struct DeclarationGrammarTests {
    private struct Unexpected: Error {}

    // MARK: One name in several phases

    @Test func oneEditVerbLeavesEachPhase() throws {
        var editor = Editor.Local()
        try editor.send(.edit("draft"))
        guard case .draft(let draft) = editor.snapshot() else { throw Unexpected() }
        #expect(draft.value == Editor.Draft(text: "draft"))
        // Each phase's typed method throws that phase's failure.
        let edit: (String) throws(Editor.DraftError) -> Editor.Prepared = { try draft.edit($0) }
        #expect(throws: Editor.DraftError.empty) { _ = try edit("") }
        try editor.send(.retry)
        guard case .saving(let saving) = editor.snapshot() else { throw Unexpected() }
        let locked: (String) throws(Editor.SavingError) -> Editor.Prepared = { try saving.edit($0) }
        #expect(throws: Editor.SavingError.locked) { _ = try locked("x") }
        // Functions of one name that throw different types have phase-prefixed rejection cases.
        do {
            try editor.send(.edit("x"))
            Issue.record("the saving edit was admitted")
        } catch {
            guard case .preparation(.savingEdit(.locked)) = error else { throw Unexpected() }
        }
        var fresh = Editor.Local()
        do {
            try fresh.send(.edit(""))
            Issue.record("an empty draft edit was admitted")
        } catch {
            guard case .preparation(.draftEdit(.empty)) = error else { throw Unexpected() }
        }
    }

    @Test func oneRetryVerbStartsEachPhaseOperations() throws {
        let fromDraft = Editor.owned(Editor.Draft(text: "a")).retry()
        let draftEffects: [Editor.Effect.Draft.Retry] = fromDraft.effects
        #expect(draftEffects == [.save("a")])
        // An owned completion edge is callable on the owned phase; it reaches `Failed`.
        let failed = fromDraft.next.failed(.offline)
        let fromFailed = failed.retry()
        let failedEffects: [Editor.Effect.Failed.Retry] = fromFailed.effects
        #expect(failedEffects == [.save("a"), .audit("retry")])
        #expect(failedEffects.map(\.effect) == [.save("a"), .audit("retry")])
    }

    @Test func oneRouterNameChoosesInEachPhase() throws {
        func same<Value>(_: Value.Type, _: Value.Type) {}
        same(Toggle.Route.Idle.Pick.self, Toggle.Route.Busy.Pick.self)
        same(Toggle.Route.Pick.self, Toggle.Route.Idle.Pick.self)
        guard case .move(let busy) = Toggle.owned().pick(1) else { throw Unexpected() }
        guard case .move(let idle) = busy.pick(1) else { throw Unexpected() }
        guard case .rejected(.negative, _) = idle.pick(-1) else { throw Unexpected() }
        var owner = Toggle.Local()
        guard case .idle(let observed) = owner.snapshot() else { throw Unexpected() }
        let pick: (Int) throws(Toggle.Refusal) -> Toggle.Prepared = { try observed.pick($0) }
        guard case .committed = owner.commit(try pick(1)), case .busy(let moved) = owner.snapshot() else {
            throw Unexpected()
        }
        // The busy router cannot throw, so its method needs no `try`.
        guard case .committed = owner.commit(moved.pick(1)), case .idle = owner.snapshot() else {
            throw Unexpected()
        }
        do {
            try owner.send(.go(-1))
            Issue.record("a negative value was admitted")
        } catch {
            guard case .preparation(.pick(.negative)) = error else { throw Unexpected() }
        }
    }

    @Test func uniquePhasesShareEdgeNames() {
        let used = Token.owned(Token.Fresh(id: 7)).use().use()
        let identifier = used.withValue { $0.id }
        #expect(identifier == 7)
        let spent = used.discard()
        _ = spent.takeValue()
        _ = Token.owned(Token.Fresh(id: 8)).discard().takeValue()
    }

    // MARK: Transitions from several phases

    @Test func aSignOutLeavesEveryListedPhase() throws {
        var session = Session.Local()
        try session.send(.signIn("kyle"))
        guard case .fetch(let fetch)? = session.drainCommands().first?.commands.first else { throw Unexpected() }
        guard case .committed = session.deliver(fetch.succeeded("Kyle")) else { throw Unexpected() }
        #expect(session.acknowledgeExecution(fetch.execution) == .recorded)
        guard case .loaded(let loaded) = session.snapshot() else { throw Unexpected() }
        #expect(loaded.value == Session.Loaded(user: "kyle", name: "Kyle"))
        // The typed method exists on each listed phase.
        guard case .committed = session.commit(loaded.signOut()) else { throw Unexpected() }
        guard case .signedOut = session.snapshot() else { throw Unexpected() }
        // The admitted completion retired the fetch without cancelling the work that returned it, so the
        // only queued command is the sign-out's start.
        let commands = session.drainCommands().flatMap(\.commands)
        guard commands.count == 1, case .forget(let forget) = commands[0] else { throw Unexpected() }
        guard case .committed = session.deliver(forget.succeeded()) else { throw Unexpected() }
        #expect(session.acknowledgeExecution(forget.execution) == .recorded)
        // Signing out while loading revokes the fetch.
        try session.send(.signIn("kyle"))
        try session.send(.signOut)
        guard case .signedOut = session.snapshot() else { throw Unexpected() }
        // A listed phase without an edge of that name still rejects the input.
        do {
            try session.send(.signOut)
            Issue.record("signing out while signed out was admitted")
        } catch {
            guard case .preparation(.invalidPhase) = error else { throw Unexpected() }
        }
        try session.send(.rename("ada"))
        guard case .loading(let loading) = session.snapshot() else { throw Unexpected() }
        #expect(loading.value == Session.Loading(user: "ada"))
    }

    @Test func ownedPhasesEachHaveTheSharedEdge() throws {
        let signedIn = Session.owned().signIn("kyle")
        #expect(signedIn.effects == [.fetch])
        let fromLoading = signedIn.next.signOut()
        #expect(fromLoading.effects == [.forget])
        #expect(fromLoading.effects.map(\.effect) == [Session.Effect.forget])
        let loaded = Session.owned().rename("ada").fetched("Ada")
        let fromLoaded = loaded.signOut()
        // Each listed phase's qualified name and the short name are one type.
        let qualified: [Session.Effect.Loaded.SignOut] = fromLoaded.effects
        let other: [Session.Effect.Loading.SignOut] = qualified
        #expect(other == [.forget])
    }

    // MARK: Operations without input or output

    @Test func aManagedOwnerRunsDriversThatTakeNoInput() async throws {
        let session = Session.Shared(forgetDriver: {}, fetchDriver: { "Kyle" })
        let snapshots = try session.snapshots()
        try session.send(.signIn("kyle"))
        var reachedLoaded = false
        for await snapshot in snapshots {
            if case .loaded(let loaded) = snapshot {
                #expect(loaded.value.name == "Kyle")
                reachedLoaded = true
                break
            }
        }
        #expect(reachedLoaded)
        await session.shutdown()
    }

    // MARK: Pinned router failures

    @Test func aPinnedRouterThrowsItsDeclaredFailure() throws {
        var owner = Pinned.Local()
        guard case .start(let start) = owner.snapshot() else { throw Unexpected() }
        // The closure's declared thrown type compiles only if `pick` throws exactly `Problem`, although
        // its candidate spells its failure `Alias`.
        let pick: (Int) throws(Pinned.Problem) -> Pinned.Prepared = { try start.pick($0) }
        #expect(throws: Pinned.Problem.negative) { _ = try pick(-1) }
        #expect(throws: Pinned.Problem.odd) { _ = try pick(11) }
        guard case .committed = owner.commit(try pick(4)), case .left = owner.snapshot() else { throw Unexpected() }
        // The owned result's rejection holds the pinned failure.
        guard case .rejected(let failure, _) = Pinned.owned().pick(-1) else { throw Unexpected() }
        let pinned: Pinned.Problem = failure
        #expect(pinned == .negative)
    }

    // MARK: Restoration

    @Test func onlyListedPhasesAreRestorable() throws {
        func phase(_ restoration: Archive.Restoration) -> String {
            // Exhaustive without a default: the resting `Draft` has no case.
            switch restoration {
            case .saving: "saving"
            case .published: "published"
            }
        }
        #expect(phase(.saving(Archive.Saving(text: "a"))) == "saving")
        let restored = Archive.Local(restoring: "!done")
        guard case .published(let published) = restored.snapshot() else { throw Unexpected() }
        #expect(published.value.text == "!done" && published.revision == 0)
        let saving = Archive.Local(restoring: "draft")
        guard case .saving = saving.snapshot() else { throw Unexpected() }
        #expect(saving.pendingCompletions().isEmpty)
    }

    // MARK: Defaults and shared result types

    @Test func localDrainsEverythingAndAcknowledgesTerminationByDefault() throws {
        var session = Session.Local()
        try session.send(.signIn("kyle"))
        try session.send(.signOut)
        // Without a limit, every queued batch transfers at once.
        let batches = session.drainCommands()
        #expect(batches.map(\.receipt.revision) == [1, 2])
        #expect(session.drainCommands().isEmpty)
        // Signing out revoked the fetch before it was drained, so its start is not issued.
        let starts = batches.flatMap(\.commands)
            .compactMap { command -> Session.ForgetWork? in
                if case .fetch = command { Issue.record("a revoked fetch was issued") }
                guard case .forget(let work) = command else { return nil }
                return work
            }
        guard starts.count == 1, let forget = starts.first else { throw Unexpected() }
        // Without a disposition, the acknowledgment records termination.
        let acknowledgment: StateMachine.AcknowledgmentResult = session.acknowledgeExecution(forget.execution)
        #expect(acknowledgment == .recorded)
        #expect(session.acknowledgeExecution(forget.execution, disposition: .terminated) == .duplicate)
    }

    @Test func scheduleIndependentResultsAreModuleTypes() {
        func same<Value>(_: Value.Type, _: Value.Type) {}
        same(GeneratedProfile.ExecutionDisposition.self, ExecutionDisposition.self)
        same(GeneratedNote.ExecutionDisposition.self, Session.ExecutionDisposition.self)
        same(GeneratedProfile.AcknowledgmentResult.self, AcknowledgmentResult.self)
        same(GeneratedNote.AcknowledgmentResult.self, Session.AcknowledgmentResult.self)
        same(GeneratedProfile.FlushResult.self, FlushResult.self)
        same(GeneratedRetry.FlushResult.self, GeneratedNote.FlushResult.self)
        let disposition: GeneratedProfile.ExecutionDisposition = .skippedBeforeStart
        let shared: StateMachine.ExecutionDisposition = disposition
        #expect(shared == .skippedBeforeStart)
    }

    // MARK: Value conformances

    @Test func effectsCompareInAnotherModuleWhenTheSchemaIsEquatable() {
        func requireEquatable<Value: Equatable>(_: Value.Type) {}
        let change = GeneratedScreen.owned().take()
        #expect(change.effects == [.measure])
        #expect(change.effects.map(\.effect) == [GeneratedScreen.Effect.measure])
        requireEquatable(GeneratedScreen.Effect.self)
        requireEquatable(GeneratedScreen.Effect.Take.self)
        requireEquatable(GeneratedScreen.Effect.Ready.Take.self)
        requireEquatable(GeneratedScreen.Restoration.self)
    }

    @Test func routerChoicesAreCaseIterableHashableValues() {
        func requireSendable<Value: Sendable>(_: Value.Type) {}
        #expect(GeneratedRetry.Route.Decide.allCases == [.again, .giveUp])
        #expect(Set(GeneratedRetry.Route.Waiting.Decide.allCases).count == 2)
        requireSendable(GeneratedRetry.Route.Decide.self)
        // A confined graph's choices are plain values too.
        #expect(Confined.Route.Pick.allCases == [.stay, .move])
        requireSendable(Confined.Route.Idle.Pick.self)
    }
}
