import StateMachine
import Testing

/// Counts the handles destroyed in one test.
nonisolated private final class Releases {
    var count = 0
}

/// A unique handle that records when it is destroyed.
nonisolated private struct Handle: ~Copyable {
    let descriptor: Int32
    let releases: Releases
    deinit { releases.count += 1 }
}

/// An owned-only graph whose input carries a noncopyable handle, which its verbs pass on consumed or
/// borrowed as the authored transitions take it.
@StateMachine(mode: .ownedOnly)
nonisolated private enum Attachment: ~Copyable {
    struct Idle {}
    struct Attached: ~Copyable {
        let handle: Handle
        var descriptor: Int32 { handle.descriptor }
    }
    struct Inspected { let descriptor: Int32 }
    @Initial case idle(Idle = Idle())
    @Terminal case attached(Attached)
    @Terminal case inspected(Inspected)
    enum Input: ~Copyable {
        case attach(Handle)
        case inspect(Handle)
    }

    @Transition(on: Input.attach)
    fileprivate static func attach(_ source: consuming Idle, _ handle: consuming Handle) -> Attached {
        Attached(handle: handle)
    }

    @Transition(on: Input.inspect)
    fileprivate static func inspect(_ source: consuming Idle, _ handle: borrowing Handle) -> Inspected {
        Inspected(descriptor: handle.descriptor)
    }
}

/// An `.isolated` graph with `Owned` alone, whose router lends a noncopyable payload to the edge it selects.
@StateMachine(mode: .isolated, owners: [.owned])
nonisolated private enum Lending: ~Copyable {
    struct Idle {}
    struct Kept: ~Copyable { let handle: Handle }
    struct Seen { let descriptor: Int32 }
    @Initial case idle(Idle)
    @Terminal case kept(Kept)
    @Terminal case seen(Seen)
    enum Input: ~Copyable { case offer(Handle) }

    @Route(on: Input.offer)
    fileprivate static func choose(_ source: Idle, _ handle: borrowing Handle) -> Route.Choose {
        handle.descriptor > 0 ? .keep : .look
    }

    @Transition(on: Input.offer)
    fileprivate static func keep(_ source: Idle, _ handle: consuming Handle) -> Kept { Kept(handle: handle) }

    @Transition(on: Input.offer)
    fileprivate static func look(_ source: Idle, _ handle: borrowing Handle) -> Seen {
        Seen(descriptor: handle.descriptor)
    }
}

/// An output declared outside the schema, which the macro cannot read.
private typealias EchoSilence = Void

/// An operation whose `Output` is its own request's type, so its success edge takes the request's type
/// unlabeled as the output; and one whose request is spelled through an alias, with an `Output` the macro
/// cannot read: the label `request:`, not the spelling, says which parameter is the request.
@StateMachine(mode: .shared, owners: [.owned, .local])
nonisolated private enum Echo: Sendable {
    typealias Started = ListenRequest
    struct Idle: Sendable {}
    struct Running: Sendable {}
    struct Heard: Sendable { let value: Int }
    @Initial case idle(Self.Idle = Self.Idle())
    case running(Running)
    @Terminal case heard(Heard)
    enum Input: Sendable {
        case go(Int)
        case listen(Int)
    }

    @Operation(activeIn: [Running.self])
    enum Fetch {
        typealias Input = Int
        typealias Output = FetchRequest
    }

    @Operation(activeIn: [Running.self])
    enum Listen {
        typealias Input = Int
        typealias Output = EchoSilence
    }

    @Transition(on: Input.go, starts: [Fetch.self])
    fileprivate static func go(_ source: Idle, _ value: Int) -> Change<Running, Effect.Go> {
        Change(Running(), effects: [.fetch(value)])
    }

    @Transition(on: Input.listen, starts: [Listen.self])
    fileprivate static func listen(_ source: Idle, _ value: Int) -> Change<Running, Effect.Listen> {
        Change(Running(), effects: [.listen(value)])
    }

    @Transition(onSuccess: Fetch.self)
    fileprivate static func fetched(_ source: Running, _ output: FetchRequest) -> Heard { Heard(value: output.input) }

    @Transition(onSuccess: Listen.self)
    fileprivate static func listened(_ source: Running, request: Started) -> Heard { Heard(value: request.input) }
}

/// A public `.isolated` graph with `Owned` alone, whose router reads the request of an operation that
/// carries an `Int` with a phase that is not `Sendable`, and whose edges each send the request: the
/// request is `Sendable` because its input is.
@StateMachine(mode: .isolated, owners: [.owned])
nonisolated public enum PublicTray {
    /// Waiting for a value.
    public struct Idle {
        /// Creates the waiting phase.
        public init() {}
    }
    /// Loading the value.
    public struct Running {
        /// Creates the loading phase.
        public init() {}
    }
    /// The loaded value.
    public struct Done {
        /// The value the request carried.
        public let value: Int
    }
    @Initial case idle(Idle)
    case running(Running)
    @Terminal case done(Done)
    /// Starts a load.
    public enum Input { case go(Int) }
    /// Loads a value for the `Int` it was started with.
    @Operation(activeIn: [Running.self])
    public enum Load {
        /// What the work receives.
        public typealias Input = Int
    }

    @Transition(on: Input.go, starts: [Load.self])
    fileprivate static func go(_ source: Idle, _ input: Int) -> Change<Running, Effect.Go> {
        Change(Running(), effects: [.load(input)])
    }

    @Route(onSuccess: Load.self)
    fileprivate static func pick(_ source: Running, request: LoadRequest) -> Route.Pick {
        request.input > 0 ? .finish : .retry
    }

    @Transition(onSuccess: Load.self)
    fileprivate static func finish(_ source: Running, request: sending LoadRequest) -> Done {
        Done(value: request.input)
    }

    @Transition(onSuccess: Load.self)
    fileprivate static func retry(_ source: Running, request: sending LoadRequest) -> Running { Running() }
}

private func requireSendable<Value: Sendable>(_ type: Value.Type) {}
private func requireHashable<Value: Hashable>(_ type: Value.Type) {}

struct ForwardedParameterTests {
    /// An `Owned` verb consumes a noncopyable payload the authored transition consumes, and only lends
    /// one it borrows, so each handle is destroyed exactly once, by its final owner.
    @Test func ownedVerbsForwardANoncopyablePayloadAsTheTransitionTakesIt() {
        let releases = Releases()
        let attached = Attachment.owned().attach(Handle(descriptor: 7, releases: releases))
        #expect(attached.withValue { $0.descriptor } == 7)
        #expect(releases.count == 0)
        _ = attached.takeValue()
        #expect(releases.count == 1)
        let inspected = Attachment.owned().inspect(Handle(descriptor: 9, releases: releases))
        #expect(inspected.withValue { $0.descriptor } == 9)
        #expect(releases.count == 2)
    }

    /// An `Owned` router lends the payload to the router and passes it on to the edge it selects.
    @Test func anOwnedRouterLendsANoncopyablePayloadAndPassesItOn() {
        let releases = Releases()
        switch Lending.owned(Lending.Idle()).choose(Handle(descriptor: 3, releases: releases)) {
        case .keep(let kept):
            #expect(kept.withValue { $0.handle.descriptor } == 3)
            #expect(releases.count == 0)
        case .look: Issue.record("Expected keep")
        }
        #expect(releases.count == 1)
        switch Lending.owned(Lending.Idle()).choose(Handle(descriptor: -1, releases: releases)) {
        case .keep: Issue.record("Expected look")
        case .look(let seen): #expect(seen.withValue { $0.descriptor } == -1)
        }
        #expect(releases.count == 2)
    }

    /// An unlabeled success parameter of the request's own type is the output of an operation that
    /// produces its request, and a parameter labeled `request:` that spells the request through an alias
    /// is the request of one that produces nothing.
    @Test func aSuccessParameterTakesTheRoleItsLabelSays() throws {
        let fetch = Echo.owned().go(1)
        let heard = fetch.next.fetched(Echo.FetchRequest(input: 4))
        #expect(heard.withValue { $0.value } == 4)
        let listen = Echo.owned().listen(2)
        #expect(listen.next.listened(request: Echo.ListenRequest(input: 5)).withValue { $0.value } == 5)
        var local = Echo.Local()
        _ = try local.send(.go(6))
        guard case .fetch(let work)? = local.drainCommands().first?.commands.first else {
            Issue.record("Expected the fetch work")
            return
        }
        guard case .committed = local.deliver(work.succeeded(Echo.FetchRequest(input: work.input + 1))),
            case .heard(let observed) = local.snapshot()
        else {
            Issue.record("Expected the fetched output to be heard")
            return
        }
        #expect(observed.value.value == 7)
    }

    /// A request is `Sendable` and `Hashable` exactly when its input is, so a public request that carries
    /// an `Int` passes through a router to edges that send it.
    @Test func aRequestIsSendableWhenItsInputIs() {
        requireSendable(PublicTray.LoadRequest.self)
        requireHashable(PublicTray.LoadRequest.self)
        let running = PublicTray.owned(PublicTray.Idle()).go(1)
        switch running.next.pick(request: PublicTray.LoadRequest(input: 3)) {
        case .finish(let done): #expect(done.withValue { $0.value } == 3)
        case .retry: Issue.record("Expected finish")
        }
    }
}
