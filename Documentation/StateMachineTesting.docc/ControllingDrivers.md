# Controlling drivers

Stand in for a managed owner's drivers, so a test decides when and how each call ends.

A managed owner runs each operation it starts through the driver it was created
with. In a test, a controlled driver takes that place. Pass its `run` method as
the operation's driver, and each time the host starts the operation, the call
suspends and waits. The test receives the call from `nextStarted()`, reads the
input the host passed, and finishes the call with a result, or leaves it
running. Every step is an explicit hand-off, so a test needs no sleeps or
yields to put events in order.

The examples in this article test one search graph whose fetch can fail:

```swift
import StateMachine
import StateMachineTesting
import Testing

@StateMachine(mode: .shared)
nonisolated enum Lookup: Sendable, Equatable {
    struct Idle: Sendable, Equatable {}
    struct Searching: Sendable, Equatable { let query: String }
    struct Found: Sendable, Equatable { let answer: String }
    struct Failed: Sendable, Equatable { let query: String }

    @Initial case idle(Idle = Idle())
    case searching(Searching)
    @Terminal case found(Found)
    case failed(Failed)

    enum Input: Sendable, Equatable { case search(String), retry, cancel }
    enum FetchFailure: Error, Sendable, Equatable { case offline }

    @Operation(activeIn: [Searching.self])
    enum Fetch {
        typealias Input = String
        typealias Output = String
        typealias Failure = FetchFailure
    }

    @Transition(on: Input.search, starts: [Fetch.self])
    fileprivate static func begin(_ source: Idle, _ query: String) -> Change<Searching, Effect.Begin> {
        Change(Searching(query: query), effects: [.fetch(query)])
    }

    @Transition(on: Input.retry, starts: [Fetch.self])
    fileprivate static func retry(_ source: Failed) -> Change<Searching, Effect.Retry> {
        Change(Searching(query: source.query), effects: [.fetch(source.query)])
    }

    @Transition(on: Input.cancel)
    fileprivate static func cancel(_ source: Searching) -> Idle { Idle() }

    @Transition(onSuccess: Fetch.self)
    fileprivate static func received(_ source: Searching, _ answer: Fetch.Output) -> Found {
        Found(answer: answer)
    }

    @Transition(onFailure: Fetch.self)
    fileprivate static func failed(_ source: Searching, _ failure: Fetch.Failure) -> Failed {
        Failed(query: source.query)
    }
}
```

## Finish each call

A ``ControlledDriver`` has the operation's `Input`, `Output`, and `Failure`
types. ``ControlledDriver/nextStarted(fileID:filePath:line:column:)`` returns
the oldest started call that the test has not received yet, waiting until the
host starts one. A ``ControlledDriver/Call`` carries the
``ControlledDriver/Call/input`` the host passed, and the test ends it once with
``ControlledDriver/Call/succeed(_:)``, ``ControlledDriver/Call/fail(_:)``, or
``ControlledDriver/Call/finish(_:)``. Each reports whether it ended the call, so
a second attempt returns `false` and changes nothing:

```swift
@Test(.timeLimit(.minutes(1)))
func aFailedSearchSucceedsOnRetry() async throws {
    let fetch = ControlledDriver<String, String, Lookup.FetchFailure>()
    let host = Lookup.ActorHost(fetchDriver: fetch.run)
    let snapshots = try await host.snapshots()

    try await host.send(.search("swift"))
    let first = try await fetch.nextStarted()
    #expect(first.input == "swift")
    #expect(first.fail(.offline))
    #expect(!first.succeed("Too late"))

    observing: for await snapshot in snapshots {
        switch snapshot {
        case .failed:
            try await host.send(.retry)
            try await fetch.nextStarted().succeed("Results for swift")
        case .found(let found):
            #expect(found.value.answer == "Results for swift")
            break observing
        case .idle, .searching:
            continue
        }
    }
    #expect(fetch.startedCount == 2)
    #expect(await host.shutdown() == .quiescent)
}
```

``ControlledDriver/startedCount`` counts the calls the host has started, and
``ControlledDriver/Call/isFinished`` whether the test has ended a call. The test
waits for the snapshot it expects rather than counting snapshots, because a
snapshot sequence keeps only the latest value. A time limit turns a call or a
snapshot that never arrives into a failure.

## Hold a call past cancellation

A call ignores cancellation, as a driver that does not check for it would.
When the host cancels the call's task, ``ControlledDriver/Call/isCancelled``
becomes `true` and ``ControlledDriver/Call/waitForCancellation(fileID:filePath:line:column:)``
returns, and the call keeps running until the test finishes it. A test can
therefore deliver a result after cancellation and observe that the host
discards it:

```swift
@Test(.timeLimit(.minutes(1)))
func aResultAfterCancellationIsDiscarded() async throws {
    let fetch = ControlledDriver<String, String, Lookup.FetchFailure>()
    let host = Lookup.Shared(fetchDriver: fetch.run)

    try host.send(.search("swift"))
    let call = try await fetch.nextStarted()
    #expect(!call.isCancelled)

    let cancelled = try host.send(.cancel)
    try await call.waitForCancellation()
    #expect(call.isCancelled)
    // The call still runs, so the host still counts it.
    #expect(host.runningCount == 1)

    #expect(call.succeed("Too late"))
    #expect(await host.shutdown() == .quiescent)
    #expect(host.snapshot().model == .idle(Lookup.Idle()))
    #expect(host.snapshot().revision == cancelled.revision + 1)
}
```

Cancelling revokes the fetch's authority at once, but the driver's task is still
running, which is why `runningCount` stays at one until the test finishes the
call. A call that the test never finishes never returns, and the host's
`shutdown()` waits for it; `shutdown(deadline:)` reports it among the
outstanding executions instead.

## Choose the driver's form

One `run` serves every driver shape, and the type the host expects selects the
overload:

- A fallible operation's driver returns `Result<Output, Failure>`, and when
  `Failure` is `Never` the driver returns the output directly.
- An operation without input, whose `Input` is `Void`, has a driver that takes
  no argument, and its calls end with `succeed()` when the output is `Void`
  too.
- An `IsolatedHost` driver receives its owning actor before its input, so the
  same driver serves a host confined to an actor:

```swift
actor SearchSession {
    let fetch: ControlledDriver<String, String, Lookup.FetchFailure>
    private lazy var host = Lookup.IsolatedHost(isolation: self, fetchDriver: fetch.run)

    init(fetch: ControlledDriver<String, String, Lookup.FetchFailure>) { self.fetch = fetch }

    func search(_ query: String) throws { try host.send(.search(query)) }

    func shutdown() async -> Lookup.ShutdownResult { await host.shutdown() }
}

@Test(.timeLimit(.minutes(1)))
func anIsolatedHostRunsTheControlledDriver() async throws {
    let fetch = ControlledDriver<String, String, Lookup.FetchFailure>()
    let session = SearchSession(fetch: fetch)

    try await session.search("swift")
    try await fetch.nextStarted().succeed("Results for swift")
    #expect(await session.shutdown() == .quiescent)
}
```

A controlled driver and its calls are `Sendable`, so they serve `Shared`,
`ActorHost`, `MainActorHost`, and `IsolatedHost` owners of a `shared` schema,
and an `IsolatedHost` of an `isolated` one whose input and output are
`Sendable`.

## Drive keyed work

A ``KeyedControlledDriver`` serves a keyed operation, whose driver takes the key
before the input. Each ``KeyedControlledDriver/Call`` also carries the
``KeyedControlledDriver/Call/key`` the host started it for, so a test can finish
one key's work and leave another's running.
``KeyedControlledDriver/nextStarted(for:fileID:filePath:line:column:)`` waits
for the oldest call for one key and leaves other keys' calls queued:

```swift
@StateMachine(mode: .shared)
nonisolated enum Library: Sendable, Equatable {
    struct Browsing: Sendable, Equatable { var titles: [Int: String] = [:] }

    @Initial case browsing(Browsing = Browsing())

    enum Input: Sendable, Equatable { case open(Int), close(Int) }

    @Operation(activeIn: [Browsing.self])
    enum Download {
        typealias Key = Int
        typealias Input = String
        typealias Output = String
    }

    @Transition(on: Input.open, starts: [Download.self])
    fileprivate static func open(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Open> {
        Change(source, effects: [.download(key: id, input: "book-\(id)")])
    }

    @Transition(on: Input.close, cancels: [Download.self])
    fileprivate static func close(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Close> {
        Change(source, effects: [.cancelDownload(key: id)])
    }

    @Transition(onSuccess: Download.self)
    fileprivate static func downloaded(
        _ source: Browsing,
        _ title: Download.Output,
        request: DownloadRequest
    ) -> Browsing {
        var titles = source.titles
        titles[request.key] = title
        return Browsing(titles: titles)
    }
}

@Test(.timeLimit(.minutes(1)))
func closingOneBookLeavesTheOtherDownloading() async throws {
    let download = KeyedControlledDriver<Int, String, String, Never>()
    let host = Library.Shared(downloadDriver: download.run)
    let titles = try host.snapshots { snapshot -> [Int: String] in
        switch snapshot {
        case .browsing(let browsing): browsing.value.titles
        }
    }

    try host.send(.open(1))
    try host.send(.open(2))
    let one = try await download.nextStarted(for: 1)
    let two = try await download.nextStarted(for: 2)
    #expect(two.input == "book-2")

    try host.send(.close(1))
    try await one.waitForCancellation()
    #expect(!two.isCancelled)

    two.succeed("Two")
    one.succeed("Stale")
    for await current in titles where current == [2: "Two"] { break }
    #expect(await host.shutdown() == .quiescent)
}
```

The host starts each execution in its own task, so calls for different keys
can reach the driver in either order, whatever the order of the inputs.
`nextStarted()` returns calls for every key in the order their tasks reached
the driver, and `nextStarted(for:)` lets the test take each call by its key
instead.

## Keep values on the main actor

A ``MainActorControlledDriver`` serves a `MainActorHost` whose inputs and
outputs need not be `Sendable`, such as one of an `isolated` schema. The driver,
its calls, and their values stay on the main actor, so the test that awaits
them runs there too:

```swift
@StateMachine(mode: .isolated)
nonisolated enum Note {
    struct Draft: ~Sendable { let text: String }
    struct Saving: ~Sendable { let text: String }
    struct Saved: ~Sendable { let text: String }

    @Initial case draft(Draft)
    case saving(Saving)
    @Terminal case saved(Saved)

    enum Input: ~Sendable { case save }

    @Operation(activeIn: [Saving.self])
    enum Save {
        typealias Input = Draft
        typealias Output = Saved
    }

    @Transition(on: Input.save, starts: [Save.self])
    fileprivate static func begin(_ source: Draft) -> Change<Saving, Effect.Begin> {
        Change(Saving(text: source.text), effects: [.save(Draft(text: source.text))])
    }

    @Transition(onSuccess: Save.self)
    fileprivate static func received(_ source: Saving, _ saved: Save.Output) -> Saved { saved }
}

@MainActor @Test(.timeLimit(.minutes(1)))
func aSaveKeepsItsDraftOnTheMainActor() async throws {
    let save = MainActorControlledDriver<Note.Draft, Note.Saved, Never>()
    let host = Note.MainActorHost(Note.Draft(text: "Outline"), saveDriver: save.run)
    var snapshots = try host.snapshots()

    try host.send(.save)
    let call = try await save.nextStarted()
    #expect(call.input.text == "Outline")
    #expect(call.succeed(Note.Saved(text: call.input.text)))

    while let snapshot = await snapshots.next() {
        guard case .saved(let saved) = snapshot else { continue }
        #expect(saved.value.text == "Outline")
        break
    }
    await host.shutdown()
}
```

## Keep values on the owning actor

An ``IsolatedControlledDriver`` serves an `IsolatedHost` whose inputs and
outputs need not be `Sendable`. The driver is confined to the actor that owns
the host: the actor stores it, the host's driver closure reaches it through the
actor it receives, and the test awaits
``IsolatedControlledDriver/nextStarted(isolation:fileID:filePath:line:column:)``
on that actor, so the driver's calls and their values never leave it. Every
member that reaches a call, from `nextStarted()` to a call's
``IsolatedControlledDriver/Call/input(isolation:)`` and
``IsolatedControlledDriver/Call/succeed(_:isolation:)``, takes the owning actor,
which a call on that actor passes by default:

```swift
actor Editor {
    let save = IsolatedControlledDriver<Editor, Note.Draft, Note.Saved, Never>()
    private(set) var host: Note.IsolatedHost<Editor>?

    init() async {
        host = Note.IsolatedHost(
            Note.Draft(text: "Outline"),
            isolation: self,
            saveDriver: { editor, draft in await editor.save.run(editor, draft) }
        )
    }

    func savedText() async throws -> String? {
        guard let host else { return nil }
        var snapshots = try host.snapshots()
        try host.send(.save)
        let call = try await save.nextStarted()
        call.succeed(Note.Saved(text: call.input().text))
        while let snapshot = await snapshots.next() {
            if case .saved(let saved) = snapshot { return saved.value.text }
        }
        return nil
    }
}

@Test(.timeLimit(.minutes(1)))
func aSaveKeepsItsDraftOnItsActor() async throws {
    let editor = await Editor()
    #expect(try await editor.savedText() == "Outline")
}
```

A call from another actor, or from the destructor of an ordinary class, which
can run on any thread, does not compile, and the driver's first use binds it to
one instance of the owning actor, so a use on another instance stops the
program. The call keeps the result the test chooses on the actor and hands it to
the suspended driver there, so the test can finish a call with an output that
shares state with its input or with the actor. The driver ignores cancellation
as the others do, and
``IsolatedControlledDriver/Call/waitForCancellation(isolation:fileID:filePath:line:column:)``
waits on the same actor for the host to cancel a call's task.

An autoclosure, such as the argument of `#expect` or the right side of `&&`, is
not isolated to the owning actor, so a member that takes the actor by default
does not compile there; neither do an `IsolatedHost`'s `runningCount()`,
`subscriberCount()`, and `isQuiescent()`. Read the value into a local first:

```swift
extension Editor {
    func saveTwice() async throws -> Bool {
        guard let host else { return false }
        try host.send(.save)
        let call = try await save.nextStarted()
        let saved = call.succeed(Note.Saved(text: call.input().text))
        let again = call.succeed(Note.Saved(text: "Twice"))
        _ = await host.shutdown()
        let quiescent = host.isQuiescent()
        #expect(saved && !again && quiescent)
        return quiescent
    }
}
```

## Drive keyed work on the owning actor

A ``KeyedIsolatedControlledDriver`` serves a keyed operation of an
`IsolatedHost` whose inputs and outputs need not be `Sendable`. It is confined
to the owning actor as an ``IsolatedControlledDriver`` is, and each
``KeyedIsolatedControlledDriver/Call`` carries the
``KeyedIsolatedControlledDriver/Call/key`` the host started it for, so
``KeyedIsolatedControlledDriver/nextStarted(for:isolation:fileID:filePath:line:column:)``
waits on that actor for one key's call and leaves the other keys' calls queued:

```swift
@StateMachine(mode: .isolated)
nonisolated enum Reader {
    struct Request: ~Sendable { let title: String }
    struct Book: ~Sendable { let title: String }
    struct Browsing: ~Sendable { var titles: [Int: String] = [:] }

    @Initial case browsing(Browsing = Browsing())

    enum Input: ~Sendable { case open(Int), close(Int) }

    @Operation(activeIn: [Browsing.self])
    enum Open {
        typealias Key = Int
        typealias Input = Request
        typealias Output = Book
    }

    @Transition(on: Input.open, starts: [Open.self])
    fileprivate static func open(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Open> {
        Change(Browsing(titles: source.titles), effects: [.open(key: id, input: Request(title: "Book \(id)"))])
    }

    @Transition(on: Input.close, cancels: [Open.self])
    fileprivate static func close(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Close> {
        Change(Browsing(titles: source.titles), effects: [.cancelOpen(key: id)])
    }

    @Transition(onSuccess: Open.self)
    fileprivate static func opened(_ source: Browsing, _ book: Open.Output, request: OpenRequest) -> Browsing {
        var titles = source.titles
        titles[request.key] = book.title
        return Browsing(titles: titles)
    }
}

actor Shelf {
    let open = KeyedIsolatedControlledDriver<Shelf, Int, Reader.Request, Reader.Book, Never>()
    private(set) var host: Reader.IsolatedHost<Shelf>?

    init() async {
        host = Reader.IsolatedHost(
            isolation: self,
            openDriver: { shelf, id, request in await shelf.open.run(shelf, id, request) }
        )
    }

    func openTwoAndCloseOne() async throws -> [Int: String] {
        guard let host else { return [:] }
        var snapshots = try host.snapshots()
        try host.send(.open(1))
        try host.send(.open(2))
        let one = try await open.nextStarted(for: 1)
        let two = try await open.nextStarted(for: 2)

        try host.send(.close(1))
        try await one.waitForCancellation()
        two.succeed(Reader.Book(title: two.input().title))
        one.succeed(Reader.Book(title: "Stale"))
        while let snapshot = await snapshots.next() {
            guard case .browsing(let browsing) = snapshot, !browsing.value.titles.isEmpty else { continue }
            return browsing.value.titles
        }
        return [:]
    }
}

@Test(.timeLimit(.minutes(1)))
func closingOneBookOnItsActorLeavesTheOtherOpening() async throws {
    let shelf = await Shelf()
    #expect(try await shelf.openTwoAndCloseOne() == [2: "Book 2"])
}
```

Key equality runs on the owning actor, and a call goes to the oldest waiting
test whose key it matches. A key type of the app's own runs its equality there
too, and a comparison that starts another call or wait on the actor, or cancels
the waiting task, cannot change which call each wait receives: the driver takes
starts and waits in the order they happened, and a wait cancelled during its
comparison takes nothing.

## Drive keyed work on the main actor

A ``KeyedMainActorControlledDriver`` serves a keyed operation of a
`MainActorHost` whose inputs and outputs need not be `Sendable`. It keeps its
calls and their values on the main actor, as a ``MainActorControlledDriver``
does, and matches keys as a ``KeyedIsolatedControlledDriver`` does with the main
actor as its owner. Its `run` is the operation's driver as written, so the
`Reader` graph above runs on the main actor without an actor of the test's own:

```swift
@MainActor @Test(.timeLimit(.minutes(1)))
func closingOneBookOnTheMainActorLeavesTheOtherOpening() async throws {
    let open = KeyedMainActorControlledDriver<Int, Reader.Request, Reader.Book, Never>()
    let host = Reader.MainActorHost(openDriver: open.run)
    var snapshots = try host.snapshots()

    try host.send(.open(1))
    try host.send(.open(2))
    let one = try await open.nextStarted(for: 1)
    let two = try await open.nextStarted(for: 2)

    try host.send(.close(1))
    try await one.waitForCancellation()
    #expect(two.succeed(Reader.Book(title: two.input.title)))
    one.succeed(Reader.Book(title: "Stale"))
    while let snapshot = await snapshots.next() {
        guard case .browsing(let browsing) = snapshot, !browsing.value.titles.isEmpty else { continue }
        #expect(browsing.value.titles == [2: "Book 2"])
        break
    }
    await host.shutdown()
}
```

A call's ``KeyedMainActorControlledDriver/Call/key`` may be read from any
context; its other members are isolated to the main actor.

## Fail a wait that cannot end

`nextStarted()` and `waitForCancellation()` wait through a continuation rather than
polling. When the waiting task is cancelled first, for example by a test's time
limit, each throws a ``StateMachineTestFailure`` located at the call, so the test
reports which wait never ended instead of hanging. A wait in a task that is
already cancelled throws at once and takes nothing. `waitForCancellation()` reports
whichever of the two cancellations reaches it first: a wait begins once it has
armed its task's cancellation handler, a wait whose task is cancelled before it
begins throws, and otherwise a wait that begins after the host cancelled the
call returns at once. Once `isCancelled` reads `true`, every wait that had
begun returns, even if its task is cancelled afterward. A call that has
started but that the test has not yet received stays queued for the next
`nextStarted()`, or for the next `nextStarted(for:)` of its key.
