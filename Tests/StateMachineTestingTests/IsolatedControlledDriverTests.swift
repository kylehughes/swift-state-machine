import StateMachine
import StateMachineTesting
import Testing

/// A document whose identity, not its value, shows whether an output shares state with an input.
private final class Document {
    var title: String
    init(title: String) { self.title = title }
}

/// A shelf whose books open by identifier, with inputs and outputs that stay on the host's actor.
@StateMachine(mode: .isolated)
nonisolated private enum Shelf {
    struct Request: ~Sendable { let title: String }
    struct Book: ~Sendable { let title: String }
    struct Browsing: ~Sendable { var titles: [Int: String] = [:] }

    @Initial case browsing(Browsing = Browsing())

    enum Input: ~Sendable {
        case open(Int)
        case close(Int)
    }

    @Operation(activeIn: [Browsing.self])
    enum Open {
        typealias Key = Int
        typealias Input = Request
        typealias Output = Book
    }

    @Transition(on: Input.open, starts: [Open.self])
    fileprivate static func open(_ source: Browsing, _ id: Int) -> Change<Browsing, Effect.Open> {
        Change(Browsing(titles: source.titles), effects: [.open(key: id, input: Request(title: "book-\(id)"))])
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

/// An actor that drives its confined drivers directly, as a host's driver closures would.
private actor Desk {
    let edit = IsolatedControlledDriver<Desk, Document, Document, Never>()
    let open = KeyedIsolatedControlledDriver<Desk, Int, Document, Document, Never>()

    /// Finishes a call with its own input, which is not `Sendable`, and reports whether the driver
    /// returned that same document.
    func finishWithTheInput() async throws -> Bool {
        let document = Document(title: "draft")
        let running = Task { await edit.run(self, document) === document }
        let call = try await edit.nextStarted()
        let input = call.input()
        input.title = "edited"
        let finished = call.succeed(input)
        let again = call.succeed(Document(title: "twice"))
        let returnedTheInput = await running.value
        return finished && !again && call.isFinished && returnedTheInput && document.title == "edited"
    }

    /// Starts a call that a wait in an already-cancelled task finds queued, then takes it in a live wait.
    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    func leaveTheQueuedCallForALiveWait() async throws -> (cancelledWaitFailed: Bool, title: String) {
        // An immediate task runs the driver until it suspends, so the call is queued before the wait.
        let running = Task.immediate { await edit.run(self, Document(title: "queued")).title }
        let cancelled = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await edit.nextStarted()
                return false
            } catch {
                return true
            }
        }
        let cancelledWaitFailed = await cancelled.value
        let call = try await edit.nextStarted()
        let title = call.input().title
        call.succeed(Document(title: title + " done"))
        _ = await running.value
        return (cancelledWaitFailed, title)
    }

    /// Takes the calls of two keys out of order, then a third call for any key.
    func takeCallsByKey() async throws -> [String] {
        let one = Task { await open.run(self, 1, Document(title: "one")).title }
        let two = Task { await open.run(self, 2, Document(title: "two")).title }
        let second = try await open.nextStarted(for: 2)
        let first = try await open.nextStarted(for: 1)
        let keys = [first.key, second.key]
        let secondInput = second.input()
        second.succeed(secondInput)
        first.succeed(Document(title: "first"))
        let three = Task { await open.run(self, 3, Document(title: "three")).title }
        let any = try await open.nextStarted()
        let anyKey = any.key
        any.succeed(any.input())
        let titles = [await one.value, await two.value, await three.value]
        return keys.map(String.init) + [String(anyKey)] + titles + [String(open.startedCount)]
    }

    /// Waits for a key whose call never starts, in a task cancelled while it waits.
    func waitForAMissingKey() async -> String? {
        let waiting = Task { _ = try await open.nextStarted(for: 9) }
        waiting.cancel()
        guard case .failure(let error) = await waiting.result, let failure = error as? StateMachineTestFailure
        else { return nil }
        return failure.message
    }
}

/// An actor that owns a confined shelf host and the keyed driver that opens its books.
private actor Reader {
    let open = KeyedIsolatedControlledDriver<Reader, Int, Shelf.Request, Shelf.Book, Never>()
    private(set) var host: Shelf.IsolatedHost<Reader>!

    init() async {
        host = Shelf.IsolatedHost(
            isolation: self,
            openDriver: { reader, id, request in await reader.open.run(reader, id, request) }
        )
    }

    /// Opens two books, closes the first while it opens, and returns the titles the owner then holds.
    func openTwoAndCloseTheFirst() async throws -> (titles: [Int: String], firstCancelled: Bool, quiescent: Bool) {
        var snapshots = try host.snapshots()
        try host.send(.open(1))
        try host.send(.open(2))
        let second = try await open.nextStarted(for: 2)
        let first = try await open.nextStarted(for: 1)
        try host.send(.close(1))
        try await first.waitForCancellation()
        let secondCancelled = second.isCancelled
        let title = second.input().title
        second.succeed(Shelf.Book(title: title.uppercased()))
        first.succeed(Shelf.Book(title: "stale"))
        var titles: [Int: String] = [:]
        while let snapshot = await snapshots.next() {
            guard case .browsing(let browsing) = snapshot, !browsing.value.titles.isEmpty else { continue }
            titles = browsing.value.titles
            break
        }
        let quiescent = await host.shutdown() == .quiescent
        return (titles, first.isCancelled && !secondCancelled, quiescent)
    }
}

@Suite(.timeLimit(.minutes(1))) struct IsolatedControlledDriverTests {
    @Test func aCallFinishesWithAValueThatSharesStateWithItsInput() async throws {
        #expect(try await Desk().finishWithTheInput())
    }

    @available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
    @Test func aWaitInAnAlreadyCancelledTaskLeavesTheQueuedCallForTheNextWait() async throws {
        let result = try await Desk().leaveTheQueuedCallForALiveWait()
        #expect(result.cancelledWaitFailed)
        #expect(result.title == "queued")
    }

    @Test func aKeyedIsolatedDriverHandsEachKeysCallToItsWait() async throws {
        #expect(try await Desk().takeCallsByKey() == ["1", "2", "3", "first", "two", "three", "3"])
    }

    @Test func aKeyedIsolatedWaitForAKeyThatNeverStartsFailsWhenTheWaitIsCancelled() async {
        let message = await Desk().waitForAMissingKey()
        #expect(message?.contains("a call for 9") == true)
    }

    @Test func aKeyedIsolatedDriverServesAConfinedHost() async throws {
        let result = try await Reader().openTwoAndCloseTheFirst()
        #expect(result.titles == [2: "BOOK-2"])
        #expect(result.firstCancelled)
        #expect(result.quiescent)
    }

    // The driver's `run` is the keyed operation's driver as written, and its calls, inputs, and
    // outputs stay on the main actor.
    @MainActor @Test func aKeyedMainActorDriverServesAMainActorHost() async throws {
        let open = KeyedMainActorControlledDriver<Int, Shelf.Request, Shelf.Book, Never>()
        let host = Shelf.MainActorHost(openDriver: open.run)
        var snapshots = try host.snapshots()
        try host.send(.open(1))
        try host.send(.open(2))
        let second = try await open.nextStarted(for: 2)
        let first = try await open.nextStarted(for: 1)
        #expect(first.key == 1 && second.key == 2)
        try host.send(.close(1))
        try await first.waitForCancellation()
        #expect(first.isCancelled && !second.isCancelled)
        #expect(second.succeed(Shelf.Book(title: second.input.title.uppercased())))
        #expect(!second.succeed(Shelf.Book(title: "twice")))
        #expect(second.isFinished)
        first.succeed(Shelf.Book(title: "stale"))
        var titles: [Int: String] = [:]
        while let snapshot = await snapshots.next() {
            guard case .browsing(let browsing) = snapshot, !browsing.value.titles.isEmpty else { continue }
            titles = browsing.value.titles
            break
        }
        #expect(titles == [2: "BOOK-2"])
        #expect(open.startedCount == 2)
        #expect(await host.shutdown() == .quiescent)
    }

    @MainActor @Test func aKeyedMainActorDriverTakesAnyKeysCallInStartOrder() async throws {
        let open = KeyedMainActorControlledDriver<Int, Shelf.Request, Shelf.Book, Never>()
        let host = Shelf.MainActorHost(openDriver: open.run)
        try host.send(.open(5))
        let call = try await open.nextStarted()
        #expect(call.key == 5)
        #expect(call.input.title == "book-5")
        call.succeed(Shelf.Book(title: "five"))
        #expect(await host.shutdown() == .quiescent)
    }

    // Each form of `run` is the driver of the matching operation shape.
    @MainActor @Test func aKeyedMainActorDriverOffersEachDriverForm() async throws {
        let fallible = KeyedMainActorControlledDriver<Int, String, String, ShelfFailure>()
        let infallible = KeyedMainActorControlledDriver<Int, String, String, Never>()
        let fallibleWithoutInput = KeyedMainActorControlledDriver<Int, Void, String, ShelfFailure>()
        let infallibleWithoutInput = KeyedMainActorControlledDriver<Int, Void, Void, Never>()
        let fails: @MainActor (Int, String) async -> Result<String, ShelfFailure> = fallible.run
        let returns: @MainActor (Int, String) async -> String = infallible.run
        let failsWithoutInput: @MainActor (Int) async -> Result<String, ShelfFailure> = fallibleWithoutInput.run
        let returnsWithoutInput: @MainActor (Int) async -> Void = infallibleWithoutInput.run
        let failing = Task { await fails(1, "a") }
        try await fallible.nextStarted(for: 1).fail(.missing)
        #expect(await failing.value == .failure(.missing))
        let returning = Task { await returns(2, "b") }
        try await infallible.nextStarted(for: 2).succeed("two")
        #expect(await returning.value == "two")
        let failingWithoutInput = Task { await failsWithoutInput(3) }
        try await fallibleWithoutInput.nextStarted().succeed("three")
        #expect(await failingWithoutInput.value == .success("three"))
        let returningWithoutInput = Task { await returnsWithoutInput(4) }
        let empty = try await infallibleWithoutInput.nextStarted(for: 4)
        #expect(empty.succeed())
        await returningWithoutInput.value
    }
}

/// A failure of a keyed driver form under test.
private enum ShelfFailure: Error, Equatable { case missing }
