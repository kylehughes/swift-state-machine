import Combine
import Dispatch
import StateMachine
import StateMachineExamples
import StateMachineUI
import Testing

// `presentedSnapshots` belongs to the presentation: a subscriber receives the snapshot shown when it
// attaches, then each one shown afterward, as its demand allows, for as long as the presentation
// lives, and a publisher kept past the presentation's release finishes.

/// A snapshot that carries only its revision.
private struct Mark: StateMachineSnapshot, Sendable, Equatable {
    let revision: UInt64
}

/// A subscriber that records what it receives and requests `initial` demand when it subscribes.
///
/// The presentation's publisher calls it on the main actor only.
private final class Recorder<Input>: Subscriber {
    typealias Failure = Never
    private(set) var values: [Input] = []
    private(set) var finished = false
    private(set) var subscription: (any Subscription)?
    private let initial: Subscribers.Demand
    var onSubscription: (() -> Void)?
    var onValue: ((Input) -> Void)?
    var onCompletion: (() -> Void)?

    init(demand: Subscribers.Demand = .unlimited) { initial = demand }

    func receive(subscription: any Subscription) {
        self.subscription = subscription
        subscription.request(initial)
        onSubscription?()
    }
    func receive(_ input: Input) -> Subscribers.Demand {
        values.append(input)
        onValue?(input)
        return .none
    }
    func receive(completion: Subscribers.Completion<Never>) {
        finished = true
        onCompletion?()
    }
}

/// A `MainActor` host of the test's own whose input names the revision it accepts.
@MainActor private final class DialHost: MainActorStateMachineHost {
    typealias Input = UInt64
    typealias Snapshot = Mark
    struct Receipt: StateMachineReceipt {
        let snapshot: Mark
        var edgeID: String? { nil }
    }
    typealias SendRejection = Never
    typealias Prepared = Never
    typealias CommitResult = Void

    private var current = Mark(revision: 0)

    func snapshot() -> Mark { current }
    func send(_ input: UInt64) -> Receipt {
        current = Mark(revision: input)
        return Receipt(snapshot: current)
    }
    func commit(_ prepared: consuming Never) {}
    func subscribe(
        _ receive: @escaping @MainActor (Mark) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        receive(current)
        return MainActorSnapshotSubscription { withExtendedLifetime((receive, onFinish)) {} }
    }
    @discardableResult func close() -> Receipt { Receipt(snapshot: current) }
}

/// One `ObservableObject` presentation under test: its publisher, how it shows a newer revision,
/// what it shows, and how it is released.
@MainActor private struct Published {
    let publisher: () -> PresentationPublisher<Mark>
    let projecting: (@escaping @MainActor (Mark) -> UInt64) -> PresentationPublisher<UInt64>
    let show: @MainActor (UInt64) -> Void
    let shown: @MainActor () -> UInt64
    let willChange: () -> ObservableObjectPublisher
    let release: @MainActor () -> Void
    let isReleased: @MainActor () -> Bool

    static func make(_ kind: PublisherClass) -> Published {
        switch kind {
        case .passive:
            var presentation: SnapshotObservableObject<Mark>? = SnapshotObservableObject(Mark(revision: 0))
            weak let released = presentation
            return Published(
                publisher: { presentation!.presentedSnapshots },
                projecting: { presentation!.presentedSnapshots(projecting: $0) },
                show: { presentation?.apply(Mark(revision: $0)) },
                shown: { presentation?.snapshot.revision ?? 0 },
                willChange: { presentation!.objectWillChange },
                release: { presentation = nil },
                isReleased: { released == nil }
            )
        case .driving:
            var presentation: StateMachineObservableObject<DialHost>? = StateMachineObservableObject(DialHost())
            weak let released = presentation
            return Published(
                publisher: { presentation!.presentedSnapshots },
                projecting: { presentation!.presentedSnapshots(projecting: $0) },
                show: { _ = presentation?.send($0) },
                shown: { presentation?.snapshot.revision ?? 0 },
                willChange: { presentation!.objectWillChange },
                release: { presentation = nil },
                isReleased: { released == nil }
            )
        }
    }
}

/// Which `ObservableObject` presentation a test publishes from.
enum PublisherClass: CaseIterable, CustomTestStringConvertible, Sendable {
    case passive, driving

    var testDescription: String {
        switch self {
        case .passive: "SnapshotObservableObject"
        case .driving: "StateMachineObservableObject"
        }
    }
}

/// Returns once the main-actor jobs enqueued before this call have run.
@MainActor private func afterEarlierJobs() async { await Task { @MainActor in }.value }

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationPublisherTests {
    // A publisher saved while the presentation shows 0 and subscribed after it shows 1 starts from 1.
    @Test(arguments: PublisherClass.allCases)
    func aSavedPublisherStartsFromTheSnapshotShownWhenItIsSubscribed(_ kind: PublisherClass) {
        let presentation = Published.make(kind)
        let saved = presentation.publisher()
        presentation.show(1)
        let recorder = Recorder<Mark>()
        saved.subscribe(recorder)
        #expect(recorder.values.map(\.revision) == [1])
    }

    // A subscriber whose first value shows a newer snapshot receives that snapshot next.
    @Test(arguments: PublisherClass.allCases)
    func aSnapshotShownFromTheFirstValueReachesTheSubscriberNext(_ kind: PublisherClass) {
        let presentation = Published.make(kind)
        presentation.show(1)
        let recorder = Recorder<Mark>()
        var showing = true
        recorder.onValue = { _ in
            guard showing else { return }
            showing = false
            presentation.show(2)
        }
        presentation.publisher().subscribe(recorder)
        #expect(recorder.values.map(\.revision) == [1, 2])
        #expect(presentation.shown() == 2)
    }

    // A snapshot shown from inside the subscriber's subscription, after it has requested demand,
    // reaches it once, in place of the snapshot shown when it attached.
    @Test(arguments: PublisherClass.allCases)
    func aSnapshotShownFromTheSubscriptionReachesTheSubscriberOnce(_ kind: PublisherClass) {
        let presentation = Published.make(kind)
        let recorder = Recorder<Mark>()
        var showing = true
        recorder.onSubscription = {
            guard showing else { return }
            showing = false
            presentation.show(1)
        }
        presentation.publisher().subscribe(recorder)
        #expect(recorder.values.map(\.revision) == [1])
        #expect(presentation.shown() == 1)
    }

    // A snapshot shown while the first value is projected replaces that value, which is older.
    @Test(arguments: PublisherClass.allCases)
    func aSnapshotShownWhileTheFirstValueIsProjectedReplacesIt(_ kind: PublisherClass) {
        let presentation = Published.make(kind)
        var showing = true
        let revisions = presentation.projecting { mark in
            if showing {
                showing = false
                presentation.show(1)
            }
            return mark.revision
        }
        let recorder = Recorder<UInt64>()
        revisions.subscribe(recorder)
        #expect(recorder.values == [1])
        #expect(presentation.shown() == 1)
    }

    // A subscriber with limited demand receives the latest snapshot once it asks again, by which time
    // the presentation already shows it; an immediately deliverable snapshot arrives before the
    // assignment.
    @Test(arguments: PublisherClass.allCases)
    func aBufferedValueArrivesWhenTheSubscriberAsksAgain(_ kind: PublisherClass) async {
        let presentation = Published.make(kind)
        let recorder = Recorder<Mark>(demand: .max(1))
        var seen: [String] = []
        recorder.onValue = { seen.append("value \($0.revision), showing \(presentation.shown())") }
        presentation.publisher().subscribe(recorder)
        presentation.show(1)
        recorder.subscription?.request(.max(1))
        await afterEarlierJobs()
        recorder.subscription?.request(.max(1))
        presentation.show(2)
        #expect(seen == ["value 0, showing 0", "value 1, showing 1", "value 2, showing 1"])
    }

    // Subscribers cancelled one by one between publications leave the others receiving in order.
    @Test(arguments: PublisherClass.allCases)
    func cancellingManySubscribersLeavesTheRestInOrder(_ kind: PublisherClass) async {
        let presentation = Published.make(kind)
        let recorders = (0 ..< 64).map { _ in Recorder<Mark>() }
        for recorder in recorders { presentation.publisher().subscribe(recorder) }
        for (index, recorder) in recorders.enumerated() where index % 4 != 0 {
            recorder.subscription?.cancel()
            await afterEarlierJobs()
        }
        presentation.show(1)
        for (index, recorder) in recorders.enumerated() {
            #expect(recorder.values.map(\.revision) == (index % 4 == 0 ? [0, 1] : [0]))
        }
    }

    // An attached subscriber receives each value after `objectWillChange` and before the snapshot
    // changes.
    @Test(arguments: PublisherClass.allCases)
    func anAttachedSubscriberReceivesEachValueBetweenTheAnnouncementAndTheChange(_ kind: PublisherClass) {
        let presentation = Published.make(kind)
        var order: [String] = []
        let announcement = presentation.willChange().sink { order.append("will change") }
        let recorder = Recorder<Mark>()
        recorder.onValue = { order.append("value \($0.revision), showing \(presentation.shown())") }
        presentation.publisher().subscribe(recorder)
        presentation.show(1)
        #expect(order == ["value 0, showing 0", "will change", "value 1, showing 0"])
        #expect(presentation.shown() == 1)
        withExtendedLifetime(announcement) {}
    }

    // The publisher keeps no reference to the presentation. Releasing the presentation finishes the
    // subscriber on a later main-actor turn, and a subscriber that attaches after the release, to a
    // publisher kept from before it, receives only the completion.
    @Test(arguments: PublisherClass.allCases)
    func aPublisherKeptPastItsPresentationFinishes(_ kind: PublisherClass) async {
        let presentation = Published.make(kind)
        let saved = presentation.publisher()
        let attached = Recorder<Mark>()
        saved.subscribe(attached)
        presentation.show(1)
        presentation.release()
        #expect(presentation.isReleased())
        await afterEarlierJobs()
        #expect(attached.values.map(\.revision) == [0, 1])
        #expect(attached.finished)
        let late = Recorder<Mark>()
        saved.subscribe(late)
        #expect(late.values.isEmpty)
        #expect(late.finished)
    }

    // A subscriber that requests one value receives the snapshot shown, then, once it asks again, the
    // latest snapshot shown meanwhile, and never an older one.
    @Test(arguments: PublisherClass.allCases)
    func aSubscriberReceivesTheLatestSnapshotAsItsDemandAllows(_ kind: PublisherClass) async {
        let presentation = Published.make(kind)
        let recorder = Recorder<Mark>(demand: .max(1))
        presentation.publisher().subscribe(recorder)
        presentation.show(1)
        presentation.show(2)
        #expect(recorder.values.map(\.revision) == [0])
        recorder.subscription?.request(.max(1))
        await afterEarlierJobs()
        #expect(recorder.values.map(\.revision) == [0, 2])
        presentation.show(3)
        #expect(recorder.values.map(\.revision) == [0, 2])
        recorder.subscription?.cancel()
        recorder.subscription?.request(.max(1))
        await afterEarlierJobs()
        #expect(recorder.values.map(\.revision) == [0, 2])
        #expect(!recorder.finished)
    }

    // A subscriber that attaches while a snapshot is announced, before it is assigned, receives the
    // snapshot still shown and then the announced one; so does one that attaches from another
    // subscriber's value.
    @Test(arguments: PublisherClass.allCases)
    func aSubscriberAttachedDuringAPublicationReceivesTheShownSnapshotThenTheNewOne(_ kind: PublisherClass) {
        let presentation = Published.make(kind)
        let announced = Recorder<Mark>()
        let handed = Recorder<Mark>()
        var attach: (() -> Void)? = { presentation.publisher().subscribe(announced) }
        let announcement = presentation.willChange().sink { attach.take()?() }
        let first = Recorder<Mark>()
        first.onValue = { if $0.revision == 1 { presentation.publisher().subscribe(handed) } }
        presentation.publisher().subscribe(first)
        presentation.show(1)
        #expect(announced.values.map(\.revision) == [0, 1])
        #expect(handed.values.map(\.revision) == [0, 1])
        withExtendedLifetime(announcement) {}
    }

    // A subscriber that cancels as it receives its subscription receives nothing, and one that
    // attaches after the presentation's release, before the turn that disposes of it, or from another
    // subscriber's completion, receives only the completion.
    @Test(arguments: PublisherClass.allCases)
    func aSubscriberThatCannotReceiveAValueReceivesNoneOrOnlyTheCompletion(_ kind: PublisherClass) async {
        let presentation = Published.make(kind)
        let cancelling = Recorder<Mark>()
        cancelling.onSubscription = { cancelling.subscription?.cancel() }
        presentation.publisher().subscribe(cancelling)
        let saved = presentation.publisher()
        let finishing = Recorder<Mark>()
        let fromCompletion = Recorder<Mark>()
        finishing.onCompletion = { saved.subscribe(fromCompletion) }
        saved.subscribe(finishing)
        presentation.release()
        let early = Recorder<Mark>()
        saved.subscribe(early)
        #expect(early.values.isEmpty && early.finished)
        #expect(!finishing.finished)
        await afterEarlierJobs()
        #expect(cancelling.values.isEmpty && !cancelling.finished)
        #expect(finishing.values.map(\.revision) == [0] && finishing.finished)
        #expect(fromCompletion.values.isEmpty && fromCompletion.finished)
    }

    // A cancellation from inside a value delivers nothing more, not even the completion.
    @Test(arguments: PublisherClass.allCases)
    func aSubscriptionCancelledFromItsValueReceivesNothingMore(_ kind: PublisherClass) async {
        let presentation = Published.make(kind)
        let inside = Recorder<Mark>()
        inside.onValue = { if $0.revision == 1 { inside.subscription?.cancel() } }
        presentation.publisher().subscribe(inside)
        presentation.show(1)
        presentation.show(2)
        #expect(inside.values.map(\.revision) == [0, 1])
        presentation.release()
        await afterEarlierJobs()
        #expect(!inside.finished)
    }

    // A pipeline that moves the values to a serial queue on another thread receives `Sendable` values
    // there, in order.
    @Test(arguments: PublisherClass.allCases)
    func aPipelineCanMoveTheValuesToAnotherThread(_ kind: PublisherClass) async {
        let presentation = Published.make(kind)
        let (stream, continuation) = AsyncStream<UInt64>.makeStream()
        let moved = presentation.publisher()
            .receive(on: DispatchQueue(label: "PresentationPublisherTests.pipeline"))
            .sink { @Sendable mark in continuation.yield(mark.revision) }
        presentation.show(1)
        presentation.show(2)
        var received: [UInt64] = []
        for await revision in stream {
            received.append(revision)
            if revision == 2 { break }
        }
        #expect(received == [0, 1, 2])
        withExtendedLifetime(moved) {}
    }
}

/// A snapshot confined to the main actor.
@MainActor private final class Box {
    var count: Int
    let revision: UInt64
    init(count: Int, revision: UInt64) {
        self.count = count
        self.revision = revision
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct PresentationProjectionPublisherTests {
    // A snapshot that is not `Sendable` reaches Combine as a `Sendable` projection that the
    // presentation computes on the main actor, and a projection publisher kept across observations
    // stays open until the presentation is released.
    @Test func aConfinedSnapshotIsPublishedThroughAProjection() async throws {
        var presentation: SnapshotObservableObject<Box>? = SnapshotObservableObject(
            Box(count: 0, revision: 0),
            revision: { $0.revision }
        )
        let counts = presentation!.presentedSnapshots(projecting: { $0.count })
        let recorder = Recorder<Int>()
        counts.subscribe(recorder)
        presentation?.apply(Box(count: 5, revision: 1))
        presentation?.stopObserving()
        presentation?.apply(Box(count: 7, revision: 2))
        #expect(recorder.values == [0, 5, 7])
        presentation = nil
        await afterEarlierJobs()
        #expect(recorder.finished)
    }

    // A driving presentation of a host whose snapshot is not `Sendable` publishes a projection.
    @Test func aDrivingPresentationOfAConfinedSnapshotPublishesAProjection() async throws {
        let host = GeneratedNote.MainActorHost(
            .init(text: "draft"),
            drivers: .init(save: { input in .init(text: input.text) })
        )
        var presentation: StateMachineObservableObject<GeneratedNote.MainActorHost>? = StateMachineObservableObject(
            host
        )
        let revisions = presentation!.presentedSnapshots(projecting: { $0.revision })
        let recorder = Recorder<UInt64>()
        revisions.subscribe(recorder)
        let first = try #require(recorder.values.first)
        presentation?.close()
        #expect(recorder.values.count == 2 && recorder.values.last! > first)
        presentation = nil
        await afterEarlierJobs()
        #expect(recorder.finished)
    }
}
