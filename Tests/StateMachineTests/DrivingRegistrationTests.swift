import Combine
import StateMachine
import StateMachineUI
import Testing
import os

// A driving presentation registers through one path, at creation and in `resumeObserving()`: what the
// owner delivers inside its registration call is shown only once the owner returns the registration,
// so a refusal shows nothing and changes nothing.

/// A snapshot that carries only its revision.
private struct Mark: StateMachineSnapshot, Sendable, Equatable {
    let revision: UInt64
}

/// A `MainActor` host of the test's own whose registrations the test refuses or admits.
@MainActor private final class GatedHost: MainActorStateMachineHost {
    typealias Input = Void
    typealias Snapshot = Mark
    struct Receipt: StateMachineReceipt {
        let snapshot: Mark
        var edgeID: String? { nil }
    }
    struct Prepared: ~Copyable {}
    enum SendRejection: Error {}

    private(set) var current = Mark(revision: 0)
    /// Whether `subscribe` throws, after delivering `deliveredBeforeRefusing` when that is set.
    var refusing = false
    var deliveredBeforeRefusing: Mark?
    private(set) var registrationCalls = 0
    private(set) var closed = false
    private var live: [Int: (receive: @MainActor (Mark) -> Void, finish: @MainActor () -> Void)] = [:]
    private var next = 0

    var liveRegistrations: Int { live.count }

    /// Advances the owner without the presentation, as another caller of the owner would.
    func advance() {
        current = Mark(revision: current.revision + 1)
        for registration in live.values { registration.receive(current) }
    }

    func snapshot() -> Mark { current }
    func send(_ input: Void) throws(SendRejection) -> Receipt {
        advance()
        return Receipt(snapshot: current)
    }
    func commit(_ prepared: consuming Prepared) {}
    func subscribe(
        _ receive: @escaping @MainActor (Mark) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        registrationCalls += 1
        if refusing {
            if let early = deliveredBeforeRefusing { receive(early) }
            throw .capacityExceeded
        }
        receive(current)
        if closed {
            onFinish()
            return MainActorSnapshotSubscription {}
        }
        next += 1
        let id = next
        live[id] = (receive, onFinish)
        return MainActorSnapshotSubscription { [weak self] in self?.live[id] = nil }
    }
    @discardableResult func close() -> Receipt {
        closed = true
        current = Mark(revision: current.revision + 1)
        let ending = live.values
        live = [:]
        for registration in ending {
            registration.receive(current)
            registration.finish()
        }
        return Receipt(snapshot: current)
    }
}

/// A subscriber that records every value it receives.
@MainActor private final class Values: Subscriber {
    typealias Input = Mark
    typealias Failure = Never
    private(set) var received: [UInt64] = []
    private(set) var finished = false
    nonisolated func receive(subscription: any Subscription) { subscription.request(.unlimited) }
    nonisolated func receive(_ input: Mark) -> Subscribers.Demand {
        MainActor.assumeIsolated { received.append(input.revision) }
        return .none
    }
    nonisolated func receive(completion: Subscribers.Completion<Never>) {
        MainActor.assumeIsolated { finished = true }
    }
}

/// Which driving presentation a test creates.
enum DrivingPresentationKind: CaseIterable, CustomTestStringConvertible, Sendable {
    case combine, observation
    var testDescription: String { self == .combine ? "StateMachineObservableObject" : "StateMachinePresentation" }
}

/// One of the two driving presentations, driven through the members they share.
@MainActor private struct Driving {
    let snapshot: () -> Mark
    let isObserving: () -> Bool
    let failure: () -> SubscriptionFailure?
    let resume: () throws(SubscriptionFailure) -> Void
    let stop: () -> Void
    let close: () -> Void
    let keep: AnyObject

    static func make(_ kind: DrivingPresentationKind, _ host: GatedHost) -> Driving {
        switch kind {
        case .combine:
            let presentation = StateMachineObservableObject(host)
            return Driving(
                snapshot: { presentation.snapshot },
                isObserving: { presentation.isObserving },
                failure: { presentation.observationFailure },
                resume: { () throws(SubscriptionFailure) in try presentation.resumeObserving() },
                stop: { presentation.stopObserving() },
                close: { presentation.close() },
                keep: presentation
            )
        case .observation:
            guard #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else {
                return make(.combine, host)
            }
            let presentation = StateMachinePresentation(host)
            return Driving(
                snapshot: { presentation.snapshot },
                isObserving: { presentation.isObserving },
                failure: { presentation.observationFailure },
                resume: { () throws(SubscriptionFailure) in try presentation.resumeObserving() },
                stop: { presentation.stopObserving() },
                close: { presentation.close() },
                keep: presentation
            )
        }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct DrivingRegistrationTests {
    // The owner reads revision 0 for the creation snapshot, then, inside the registration call, delivers
    // an accepted revision 1 and refuses the registration. The presentation shows the creation snapshot.
    @Test(arguments: DrivingPresentationKind.allCases)
    func aRefusedRegistrationKeepsTheCreationSnapshot(_ kind: DrivingPresentationKind) {
        let host = GatedHost()
        host.refusing = true
        host.deliveredBeforeRefusing = Mark(revision: 1)
        let driving = Driving.make(kind, host)
        #expect(driving.snapshot() == Mark(revision: 0))
        #expect(!driving.isObserving())
        #expect(driving.failure() == .capacityExceeded)
    }

    // After a refused creation, the owner admits registrations again and has moved on without the
    // presentation. Resuming registers once, shows the owner's current snapshot, keeps the
    // presentation's publisher subscriber attached, and clears the failure.
    @Test func resumingAfterARefusedCreationRegistersAndKeepsSubscribers() throws {
        let host = GatedHost()
        host.refusing = true
        let presentation = StateMachineObservableObject(host)
        let values = Values()
        presentation.presentedSnapshots.subscribe(values)
        host.refusing = false
        host.advance()
        #expect(presentation.snapshot.revision == 0)
        try presentation.resumeObserving()
        #expect(presentation.isObserving)
        #expect(presentation.observationFailure == nil)
        #expect(presentation.snapshot.revision == 1)
        #expect(host.registrationCalls == 2)
        host.advance()
        #expect(presentation.snapshot.revision == 2)
        #expect(values.received == [0, 1, 2])
        #expect(!values.finished)
    }

    // A refused resumption throws at once and changes nothing: the snapshot the owner delivered while
    // refusing is not shown, and the failure recorded at creation stays.
    @Test(arguments: DrivingPresentationKind.allCases)
    func aRefusedResumptionThrowsAndChangesNothing(_ kind: DrivingPresentationKind) throws {
        let host = GatedHost()
        host.refusing = true
        let driving = Driving.make(kind, host)
        host.deliveredBeforeRefusing = Mark(revision: 7)
        #expect(throws: SubscriptionFailure.capacityExceeded) { try driving.resume() }
        #expect(driving.snapshot() == Mark(revision: 0))
        #expect(!driving.isObserving())
        #expect(driving.failure() == .capacityExceeded)
        #expect(host.registrationCalls == 2)
    }

    // Stopping and resuming registers again with the same owner, after the earlier registration ended;
    // resuming while observing registers nothing.
    @Test(arguments: DrivingPresentationKind.allCases)
    func resumingAfterStoppingRegistersAgainAndResumingWhileObservingDoesNothing(_ kind: DrivingPresentationKind) throws
    {
        let host = GatedHost()
        let driving = Driving.make(kind, host)
        #expect(driving.isObserving())
        try driving.resume()
        #expect(host.registrationCalls == 1)
        driving.stop()
        #expect(!driving.isObserving())
        #expect(host.liveRegistrations == 0)
        host.advance()
        #expect(driving.snapshot() == Mark(revision: 0))
        try driving.resume()
        #expect(driving.isObserving())
        #expect(host.liveRegistrations == 1)
        #expect(driving.snapshot() == Mark(revision: 1))
        host.advance()
        #expect(driving.snapshot() == Mark(revision: 2))
    }

    // A sink of `isObserving` resumes as soon as the end is reported. Combine calls it before the property
    // changes; the resumed registration's report waits for the end's assignment, then follows it, so the
    // presentation ends observing, with `false` and then `true` reported once each.
    @Test func resumingFromTheReportOfAnEndReportsTheNewRegistrationAfterIt() throws {
        let host = GatedHost()
        let presentation = StateMachineObservableObject(host)
        var reports: [Bool] = []
        let resuming = presentation.$isObserving.dropFirst()
            .sink { observing in
                reports.append(observing)
                if !observing { try? presentation.resumeObserving() }
            }
        presentation.stopObserving()
        resuming.cancel()
        #expect(reports == [false, true])
        #expect(presentation.isObserving)
        #expect(host.liveRegistrations == 1)
    }

    // After `close()`, the closed owner finishes a resumed registration inside the call: it returns
    // without throwing, and the presentation is not observing.
    @Test(arguments: DrivingPresentationKind.allCases)
    func resumingAfterClosingReturnsWithoutObserving(_ kind: DrivingPresentationKind) throws {
        let host = GatedHost()
        let driving = Driving.make(kind, host)
        driving.close()
        #expect(!driving.isObserving())
        try driving.resume()
        #expect(!driving.isObserving())
        #expect(driving.failure() == nil)
        #expect(driving.snapshot() == host.snapshot())
        #expect(host.liveRegistrations == 0)
    }
}

/// What happened to the snapshots of a `CancelDeliveringHost`, in order.
private final class Trace: Sendable {
    private let events = OSAllocatedUnfairLock<[String]>(initialState: [])
    var all: [String] { events.withLock { $0 } }
    func append(_ event: String) { events.withLock { $0.append(event) } }
}

/// A snapshot that records its destruction.
private final class Traced: StateMachineSnapshot, Sendable {
    let revision: UInt64
    private let trace: Trace
    init(_ revision: UInt64, _ trace: Trace) {
        self.revision = revision
        self.trace = trace
    }
    deinit { trace.append("destroyed \(revision)") }
}

/// A host of the test's own that delivers one more snapshot from inside the cancellation of a
/// registration, before it frees the registration's slot.
@MainActor private final class CancelDeliveringHost: MainActorStateMachineHost {
    typealias Input = Void
    typealias Snapshot = Traced
    struct Receipt: StateMachineReceipt {
        let snapshot: Traced
        var edgeID: String? { nil }
    }
    struct Prepared: ~Copyable {}
    enum SendRejection: Error {}

    let trace = Trace()
    private(set) var held = false

    func snapshot() -> Traced { Traced(0, trace) }
    func send(_ input: Void) throws(SendRejection) -> Receipt { Receipt(snapshot: Traced(0, trace)) }
    func commit(_ prepared: consuming Prepared) {}
    func subscribe(
        _ receive: @escaping @MainActor (Traced) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        held = true
        return MainActorSnapshotSubscription { [weak self] in
            guard let self else { return }
            receive(Traced(20, trace))
            trace.append("freed")
            held = false
        }
    }
    @discardableResult func close() -> Receipt { Receipt(snapshot: Traced(0, trace)) }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct DrivingDisposalTests {
    // A driving presentation is released on the main actor. Its disposal turn cancels the subscription,
    // and the host delivers revision 20 from inside that cancellation, before it frees the slot. The
    // presentation is gone, so its storage keeps that snapshot and releases it only once the
    // cancellation has returned, after the slot is free, as stopping and closing do.
    @Test(arguments: DrivingPresentationKind.allCases)
    func aSnapshotDeliveredInsideTheDisposalCancellationIsReleasedAfterTheSlotIsFree(
        _ kind: DrivingPresentationKind
    ) async {
        let host = CancelDeliveringHost()
        var presentation: AnyObject? = Self.make(kind, host)
        #expect(host.held)
        presentation = nil
        #expect(presentation == nil)
        while host.held, !Task.isCancelled { await Task.yield() }
        let events = host.trace.all
        let freed = events.firstIndex(of: "freed")
        let destroyed = events.firstIndex(of: "destroyed 20")
        #expect(freed != nil && destroyed != nil && freed! < destroyed!, "\(events)")
    }

    private static func make(_ kind: DrivingPresentationKind, _ host: CancelDeliveringHost) -> AnyObject {
        if kind == .observation, #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            return StateMachinePresentation(host)
        }
        return StateMachineObservableObject(host)
    }
}

/// A snapshot that records its destruction under its own name.
private final class Named: StateMachineSnapshot, Sendable {
    let revision: UInt64
    private let name: String
    private let trace: Trace
    init(_ revision: UInt64, _ name: String, _ trace: Trace) {
        self.revision = revision
        self.name = name
        self.trace = trace
    }
    deinit { trace.append("destroyed \(name)") }
}

/// A host of the test's own with one slot, which runs the test's code once inside its next
/// registration call or inside its next cancellation, before that cancellation frees the slot.
@MainActor private final class ArmedHost: MainActorStateMachineHost {
    typealias Input = Void
    typealias Snapshot = Named
    struct Receipt: StateMachineReceipt {
        let snapshot: Named
        var edgeID: String? { nil }
    }
    struct Prepared: ~Copyable {}
    enum SendRejection: Error {}

    let trace = Trace()
    private(set) var revision: UInt64 = 0
    private(set) var closed = false
    private(set) var held = 0
    /// Runs once inside the next registration call, after the host delivered and before it returns.
    var insideSubscribe: (@MainActor () -> Void)?
    /// Runs once inside the next cancellation, before it frees the slot.
    var insideCancel: (@MainActor () -> Void)?
    private var live: [Int: (receive: @MainActor (Named) -> Void, finish: @MainActor () -> Void)] = [:]
    private var next = 0

    func snapshot() -> Named { Named(revision, "read \(revision)", trace) }
    func send(_ input: Void) throws(SendRejection) -> Receipt {
        revision += 1
        for registration in live.values { registration.receive(Named(revision, "delivered \(revision)", trace)) }
        return Receipt(snapshot: Named(revision, "sent \(revision)", trace))
    }
    func commit(_ prepared: consuming Prepared) {}
    func subscribe(
        _ receive: @escaping @MainActor (Named) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        guard held == 0 else { throw .capacityExceeded }
        held += 1
        next += 1
        let id = next
        receive(Named(revision, "staged \(id)", trace))
        if closed { onFinish() } else { live[id] = (receive, onFinish) }
        insideSubscribe.take()?()
        return MainActorSnapshotSubscription { [weak self] in
            guard let self else { return }
            insideCancel.take()?()
            live[id] = nil
            held -= 1
            trace.append("freed \(id)")
        }
    }
    @discardableResult func close() -> Receipt {
        closed = true
        revision += 1
        let ending = live.values
        live = [:]
        for registration in ending {
            registration.receive(Named(revision, "closing \(revision)", trace))
            registration.finish()
        }
        return Receipt(snapshot: Named(revision, "closed \(revision)", trace))
    }
}

/// One of the two driving presentations of an `ArmedHost`.
@MainActor private struct ArmedDriving {
    let isObserving: () -> Bool
    let resume: () throws(SubscriptionFailure) -> Void
    let stop: () -> Void
    let close: () -> Void
    let keep: AnyObject

    static func make(_ kind: DrivingPresentationKind, _ host: ArmedHost) -> ArmedDriving {
        if kind == .observation, #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            let presentation = StateMachinePresentation(host)
            return ArmedDriving(
                isObserving: { presentation.isObserving },
                resume: { () throws(SubscriptionFailure) in try presentation.resumeObserving() },
                stop: { presentation.stopObserving() },
                close: { presentation.close() },
                keep: presentation
            )
        }
        let presentation = StateMachineObservableObject(host)
        return ArmedDriving(
            isObserving: { presentation.isObserving },
            resume: { () throws(SubscriptionFailure) in try presentation.resumeObserving() },
            stop: { presentation.stopObserving() },
            close: { presentation.close() },
            keep: presentation
        )
    }
}

// A registration in progress, interrupted by a stop from a callback of that registration.
@MainActor @Suite(.timeLimit(.minutes(1))) struct InterruptedRegistrationTests {
    // Resuming registers again. The presentation clears its failure, which is already `nil`, and shows
    // the newer snapshot the owner delivered; a sink of `objectWillChange` stops observing from inside
    // that. The new registration is cancelled at once, and nothing holds the owner's slot.
    @Test func aStopFromTheChangeOfAResumedRegistrationCancelsIt() throws {
        let host = GatedHost()
        let presentation = StateMachineObservableObject(host)
        presentation.stopObserving()
        host.advance()
        var stopped = false
        let stopping = presentation.objectWillChange.sink {
            guard !stopped else { return }
            stopped = true
            presentation.stopObserving()
        }
        try presentation.resumeObserving()
        stopping.cancel()
        #expect(stopped)
        #expect(!presentation.isObserving)
        #expect(host.liveRegistrations == 0)
    }

    // After a refused creation, resuming registers, and clearing the failure announces a change. A sink
    // of `objectWillChange` stops observing from inside that announcement, before the presentation shows
    // the owner's newer snapshot. The new registration is cancelled at once, and the snapshot it
    // delivered is not shown.
    @Test func aStopFromTheChangeThatClearsTheFailureCancelsTheResumedRegistration() throws {
        let host = GatedHost()
        host.refusing = true
        let presentation = StateMachineObservableObject(host)
        host.refusing = false
        host.advance()
        var stopped = false
        let stopping = presentation.objectWillChange.sink {
            guard !stopped else { return }
            stopped = true
            presentation.stopObserving()
        }
        try presentation.resumeObserving()
        stopping.cancel()
        #expect(stopped)
        #expect(presentation.observationFailure == nil)
        #expect(!presentation.isObserving)
        #expect(host.liveRegistrations == 0)
        #expect(presentation.snapshot.revision == 0)
    }

    // The closed owner finishes a resumed registration inside the call, and the presentation cancels it
    // once the owner returns it. The host stops the presentation from inside that cancellation. The
    // registration was never live, so `isObserving` stays `false` throughout.
    @Test(arguments: DrivingPresentationKind.allCases)
    func aStopInsideTheCancellationOfAFinishedRegistrationReportsNothing(_ kind: DrivingPresentationKind) throws {
        let host = ArmedHost()
        let driving = ArmedDriving.make(kind, host)
        driving.close()
        var observedInside: Bool?
        host.insideCancel = {
            driving.stop()
            observedInside = driving.isObserving()
        }
        try driving.resume()
        #expect(observedInside == false)
        #expect(!driving.isObserving())
        #expect(host.held == 0)
    }

    // The closed owner stages its snapshot and finishes inside the registration call, and then the host
    // stops the presentation from inside that same call. The staged snapshot is released only once the
    // registration's cancellation has freed the slot.
    @Test(arguments: DrivingPresentationKind.allCases)
    func aStopInsideTheRegistrationCallKeepsWhatItStagedUntilTheSlotIsFree(_ kind: DrivingPresentationKind) throws {
        let host = ArmedHost()
        let driving = ArmedDriving.make(kind, host)
        driving.close()
        host.insideSubscribe = { driving.stop() }
        try driving.resume()
        #expect(!driving.isObserving())
        #expect(host.held == 0)
        let events = host.trace.all
        let freed = events.firstIndex(of: "freed 2")
        let destroyed = events.firstIndex(of: "destroyed staged 2")
        #expect(freed != nil && destroyed != nil && freed! < destroyed!, "\(events)")
    }

    // The same stop inside the registration call of an open owner: the owner returns a live
    // registration, which the presentation cancels at once, and the snapshot it staged waits for that.
    @Test(arguments: DrivingPresentationKind.allCases)
    func aStopInsideAnOpenRegistrationCallCancelsItBeforeReleasingWhatItStaged(_ kind: DrivingPresentationKind) throws {
        let host = ArmedHost()
        let driving = ArmedDriving.make(kind, host)
        driving.stop()
        host.insideSubscribe = { driving.stop() }
        try driving.resume()
        #expect(!driving.isObserving())
        #expect(host.held == 0)
        let events = host.trace.all
        let freed = events.firstIndex(of: "freed 2")
        let destroyed = events.firstIndex(of: "destroyed staged 2")
        #expect(freed != nil && destroyed != nil && freed! < destroyed!, "\(events)")
    }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct DrivingReleaseDuringPublicationTests {
    // The owner delivers a newer snapshot, and a sink of the change it announces releases the
    // presentation's last reference. The snapshot that delivery replaces is released only by the
    // disposal, once the registration's cancellation has freed the slot.
    @Test func aSnapshotReplacedAfterAReleaseInsideItsPublicationWaitsForTheSlot() async {
        let host = ArmedHost()
        var presentation: StateMachineObservableObject<ArmedHost>? = StateMachineObservableObject(host)
        weak let released = presentation
        let releasing = presentation?.objectWillChange.sink { presentation = nil }
        _ = try? host.send(())
        #expect(released == nil)
        while host.held > 0, !Task.isCancelled { await Task.yield() }
        releasing?.cancel()
        let events = host.trace.all
        let freed = events.firstIndex(of: "freed 1")
        let destroyed = events.firstIndex(of: "destroyed read 0")
        #expect(freed != nil && destroyed != nil && freed! < destroyed!, "\(events)")
    }
}
