import Combine
import Observation
import StateMachine
import StateMachineUI
import Testing

// A driving presentation first reports a registration live only once the snapshot the registration
// delivered, or a newer one, is shown, also when the registration is made from a callback of a change
// it is still assigning. Stopping discards a delivery of the observation that waited for that
// assignment, whose publication was never announced, and still shows a waiting receipt of a change made
// through the presentation. A host of your own that calls a callback whose cancellation has returned
// finds its snapshot released at once. Every waiting delivery belongs to the registration that
// delivered it: stopping releases it once the cancellation has returned, and never takes the seed of a
// registration resumed from a callback of that stop.

/// A snapshot that carries its revision, can run code of its own when the revision is read, and can
/// hold an object, as a snapshot that captures its presentation does.
private final class Shot: StateMachineSnapshot, Sendable {
    private let stored: UInt64
    private let onRead: (@Sendable () -> Void)?
    let retained: (any AnyObject & Sendable)?
    init(_ revision: UInt64, onRead: (@Sendable () -> Void)? = nil, retaining: (any AnyObject & Sendable)? = nil) {
        stored = revision
        self.onRead = onRead
        retained = retaining
    }
    var revision: UInt64 {
        onRead?()
        return stored
    }
}

/// An action that runs once, on the main actor, from whichever call reaches it first.
@MainActor private final class Once: Sendable {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func run() { exchange(&action, with: nil)?() }
}

/// A `MainActor` host of the test's own, which keeps every receive callback it was ever given.
@MainActor private final class ReplayHost: MainActorStateMachineHost {
    typealias Input = Void
    typealias Snapshot = Shot
    struct Receipt: StateMachineReceipt {
        let snapshot: Shot
        var edgeID: String? { nil }
    }
    struct Prepared: ~Copyable {}
    enum SendRejection: Error {}

    private(set) var current = Shot(0)
    private(set) var closed = false
    private var live: [Int: @MainActor (Shot) -> Void] = [:]
    private var next = 0
    /// Every receive callback a registration was given, kept after its cancellation returns, which
    /// breaks the contract a host of your own keeps.
    private(set) var callbacks: [@MainActor (Shot) -> Void] = []

    /// Advances the owner without the presentation, as another caller of the owner would.
    func advance() {
        current = Shot(current.revision + 1)
        for receive in live.values { receive(current) }
    }
    /// Delivers `shot` to every live registration without keeping it, as an owner that has moved on
    /// relinquishes a snapshot it delivered.
    func offer(_ shot: Shot) {
        for receive in live.values { receive(shot) }
    }
    func snapshot() -> Shot { current }
    func send(_ input: Void) throws(SendRejection) -> Receipt {
        advance()
        return Receipt(snapshot: current)
    }
    func commit(_ prepared: consuming Prepared) {}
    func subscribe(
        _ receive: @escaping @MainActor (Shot) -> Void,
        onFinish: @escaping @MainActor () -> Void
    ) throws(SubscriptionFailure) -> MainActorSnapshotSubscription {
        receive(current)
        if closed {
            onFinish()
            return MainActorSnapshotSubscription {}
        }
        next += 1
        let id = next
        live[id] = receive
        callbacks.append(receive)
        return MainActorSnapshotSubscription { [weak self] in self?.live[id] = nil }
    }
    @discardableResult func close() -> Receipt {
        closed = true
        current = Shot(current.revision + 1)
        return Receipt(snapshot: current)
    }
}

/// One of the two driving presentations, with a callback of its next snapshot change and of each
/// report that it observes.
@MainActor private final class Driven {
    private(set) var snapshot: () -> UInt64 = { 0 }
    private(set) var isObserving: () -> Bool = { false }
    private(set) var send: () -> Void = {}
    private(set) var resume: () -> Void = {}
    private(set) var stop: () -> Void = {}
    private(set) var close: () -> Void = {}
    private var onReport: (() -> Void)?
    /// The revisions shown when each `true` report of a Combine presentation was announced.
    private(set) var shownWhenLive: [UInt64] = []
    private var onChange: (() -> Void)?
    private var keep: [Any] = []

    init(_ kind: DrivingPresentationKind, _ host: ReplayHost) {
        switch kind {
        case .combine:
            make(StateMachineObservableObject(host))
        case .observation:
            guard #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) else {
                make(StateMachineObservableObject(host))
                return
            }
            make(StateMachinePresentation(host))
        }
    }
    /// Runs `action` once, from the announcement of the next snapshot the presentation shows.
    func arm(_ action: @escaping () -> Void) { onChange = action }
    /// Runs `action` once, from the announcement of the next change of `isObserving`.
    func armReport(_ action: @escaping () -> Void) { onReport = action }
    private func reported() {
        guard let action = onReport else { return }
        onReport = nil
        action()
    }

    private func make(_ presentation: StateMachineObservableObject<ReplayHost>) {
        bind(presentation)
        keep.append(
            presentation.objectWillChange.sink { [weak self] in
                guard let action = self?.onChange else { return }
                self?.onChange = nil
                action()
            }
        )
        keep.append(
            presentation.$isObserving.dropFirst()
                .sink { [weak self, unowned presentation] observing in
                    if observing { self?.shownWhenLive.append(presentation.snapshot.revision) }
                    self?.reported()
                }
        )
    }
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    private func make(_ presentation: StateMachinePresentation<ReplayHost>) {
        bind(presentation)
        trackSnapshot(presentation)
        trackObserving(presentation)
    }
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    private func trackSnapshot(_ presentation: StateMachinePresentation<ReplayHost>) {
        withObservationTracking {
            _ = presentation.snapshot
        } onChange: { [weak self, weak presentation] in
            MainActor.assumeIsolated {
                guard let self, let presentation else { return }
                if let action = self.onChange {
                    self.onChange = nil
                    action()
                }
                self.trackSnapshot(presentation)
            }
        }
    }
    @available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    private func trackObserving(_ presentation: StateMachinePresentation<ReplayHost>) {
        withObservationTracking {
            _ = presentation.isObserving
        } onChange: { [weak self, weak presentation] in
            MainActor.assumeIsolated {
                guard let self, let presentation else { return }
                self.reported()
                self.trackObserving(presentation)
            }
        }
    }
    private func bind<Presentation: AnyObject>(_ presentation: Presentation)
    where Presentation: DrivenPresentation {
        snapshot = { [unowned presentation] in presentation.shown }
        isObserving = { [unowned presentation] in presentation.observing }
        send = { [unowned presentation] in presentation.sendInput() }
        resume = { [unowned presentation] in presentation.resume() }
        stop = { [unowned presentation] in presentation.stop() }
        close = { [unowned presentation] in presentation.closeOwner() }
        keep.append(presentation)
    }
}

/// The members of a driving presentation that `Driven` calls.
@MainActor private protocol DrivenPresentation {
    var shown: UInt64 { get }
    var observing: Bool { get }
    func sendInput()
    func resume()
    func stop()
    func closeOwner()
}

extension StateMachineObservableObject: DrivenPresentation where Host == ReplayHost {
    fileprivate var shown: UInt64 { snapshot.revision }
    fileprivate var observing: Bool { isObserving }
    fileprivate func sendInput() { _ = try? send(()) }
    fileprivate func resume() { try? resumeObserving() }
    fileprivate func stop() { stopObserving() }
    fileprivate func closeOwner() { close() }
}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
extension StateMachinePresentation: DrivenPresentation where Host == ReplayHost {
    fileprivate var shown: UInt64 { snapshot.revision }
    fileprivate var observing: Bool { isObserving }
    fileprivate func sendInput() { _ = try? send(()) }
    fileprivate func resume() { try? resumeObserving() }
    fileprivate func stop() { stopObserving() }
    fileprivate func closeOwner() { close() }
}

@MainActor @Suite(.timeLimit(.minutes(1))) struct DrivingFirstLiveTests {
    // The presentation stops at revision 0, then sends an input. From the announcement of revision 1,
    // it resumes, and the owner delivers revision 1 inside the registration call. The registration
    // becomes live only once revision 1 is shown.
    @Test(arguments: DrivingPresentationKind.allCases)
    func aResumeFromAChangeCallbackReportsLiveOnlyOnceItsSeedIsShown(_ kind: DrivingPresentationKind) {
        let host = ReplayHost()
        let driven = Driven(kind, host)
        driven.stop()
        var insideCallback: (observing: Bool, shown: UInt64)?
        driven.arm {
            driven.resume()
            insideCallback = (driven.isObserving(), driven.snapshot())
        }
        driven.send()
        #expect(insideCallback?.observing == false)
        #expect(insideCallback?.shown == 0)
        if kind == .combine { #expect(driven.shownWhenLive.last == 1) }
        #expect(driven.isObserving())
        #expect(driven.snapshot() == 1)
    }

    // From the announcement of revision 1, the owner advances to 2 without the presentation, the
    // presentation resumes, whose registration delivers 2 while 1 is still being assigned, and stops
    // again. Revision 2 was never announced, so it is never shown.
    @Test(arguments: DrivingPresentationKind.allCases)
    func stoppingDiscardsADeliveryThatWaitedForTheAssignment(_ kind: DrivingPresentationKind) {
        let host = ReplayHost()
        let driven = Driven(kind, host)
        driven.stop()
        driven.arm {
            host.advance()
            driven.resume()
            driven.stop()
        }
        driven.send()
        #expect(driven.snapshot() == 1)
        #expect(!driven.isObserving())
        // The ordinal check returned to revision 1, so resuming shows the owner's revision 2.
        driven.resume()
        #expect(driven.snapshot() == 2)
        #expect(driven.isObserving())
    }

    // From the announcement of revision 1, the presentation sends another input, whose receipt,
    // revision 2, waits; the owner advances to 3, and a resumed registration delivers it. Stopping
    // discards the delivery and still shows the receipt.
    @Test(arguments: DrivingPresentationKind.allCases)
    func stoppingStillShowsAWaitingReceipt(_ kind: DrivingPresentationKind) {
        let host = ReplayHost()
        let driven = Driven(kind, host)
        driven.stop()
        driven.arm {
            driven.send()
            host.advance()
            driven.resume()
            driven.stop()
        }
        driven.send()
        #expect(driven.snapshot() == 2)
        #expect(!driven.isObserving())
    }

    // A receipt that waits after the delivery is newer than it, and stopping still shows it.
    @Test(arguments: DrivingPresentationKind.allCases)
    func aReceiptAfterAWaitingDeliveryIsShownAfterAStop(_ kind: DrivingPresentationKind) {
        let host = ReplayHost()
        let driven = Driven(kind, host)
        driven.stop()
        driven.arm {
            host.advance()
            driven.resume()
            driven.send()
            driven.stop()
        }
        driven.send()
        #expect(driven.snapshot() == 3)
    }

    // From the report that ends the registration while the presentation closes, the presentation
    // resumes. The owner is already closed, so the new registration finishes inside the call, and no
    // registration is live once `close()` returns.
    @Test(arguments: DrivingPresentationKind.allCases)
    func aResumeFromTheEndOfACloseFindsTheOwnerClosed(_ kind: DrivingPresentationKind) {
        let host = ReplayHost()
        let driven = Driven(kind, host)
        #expect(driven.isObserving())
        driven.armReport { driven.resume() }
        driven.close()
        #expect(!driven.isObserving())
        #expect(driven.snapshot() == 1)
        driven.resume()
        #expect(!driven.isObserving())
    }

    // A host of your own keeps the receive callback of a registration the presentation stopped, and
    // calls it after the cancellation returned with a snapshot that nothing else holds. No cancellation
    // is running, so the presentation releases it at once.
    @Test(arguments: DrivingPresentationKind.allCases)
    func aLateCallbackAfterTheCancellationReturnedReleasesItsSnapshotAtOnce(_ kind: DrivingPresentationKind) {
        let host = ReplayHost()
        let driven = Driven(kind, host)
        driven.stop()
        let obsolete = try! #require(host.callbacks.first)
        weak var released: Shot?
        do {
            let late = Shot(9)
            released = late
            obsolete(late)
        }
        #expect(released == nil)
        #expect(driven.snapshot() == 0)
        withExtendedLifetime(driven) {}
    }

    // While revision 1 is being assigned, the owner delivers revision 2, which waits, and the
    // presentation stops before the assignment completes. The host keeps nothing, so once the
    // cancellation has returned nothing holds revision 2, while the presentation is still stopped.
    @Test(arguments: DrivingPresentationKind.allCases)
    func stoppingReleasesAWaitingDeliveryOnceTheCancellationReturned(_ kind: DrivingPresentationKind) {
        let host = ReplayHost()
        let driven = Driven(kind, host)
        weak var waiting: Shot?
        driven.arm {
            let shot = Shot(2)
            waiting = shot
            host.offer(shot)
            driven.stop()
        }
        host.advance()
        #expect(driven.snapshot() == 1)
        #expect(!driven.isObserving())
        #expect(waiting == nil)
        withExtendedLifetime(driven) {}
    }

    // The same schedule, where the waiting delivery holds its presentation, as a snapshot that captures
    // the screen showing it does: releasing every other reference releases the presentation.
    @Test(arguments: DrivingPresentationKind.allCases)
    func aWaitingDeliveryThatHoldsItsPresentationDoesNotKeepItAlive(_ kind: DrivingPresentationKind) {
        let host = ReplayHost()
        weak var released: AnyObject?
        weak var waiting: Shot?
        do {
            let presentation = DrivingPresentationKind.make(kind, host)
            released = presentation.object
            presentation.onNextChange {
                let shot = Shot(2, retaining: presentation.object)
                waiting = shot
                host.offer(shot)
                presentation.stop()
            }
            host.advance()
            presentation.detach()
        }
        #expect(waiting == nil)
        #expect(released == nil)
    }

    // While revision 1 is being assigned, the presentation stops. From the report of that stop, the
    // owner advances to revision 2 and the presentation resumes, whose registration's seed waits for the
    // assignment. The stop that already returned its cancellation never takes that seed, so the
    // presentation reports live showing revision 2.
    @Test(arguments: DrivingPresentationKind.allCases)
    func aResumeFromTheReportOfAStopKeepsItsSeed(_ kind: DrivingPresentationKind) {
        let host = ReplayHost()
        let driven = Driven(kind, host)
        driven.arm {
            driven.armReport {
                host.advance()
                driven.resume()
            }
            driven.stop()
        }
        host.advance()
        #expect(driven.isObserving())
        #expect(driven.snapshot() == 2)
        #expect(host.snapshot().revision == 2)
        if kind == .combine { #expect(driven.shownWhenLive.last == 2) }
    }

    // A delivered snapshot whose revision, when read, stops the presentation is not shown: the
    // registration that delivered it ended before its revision was known.
    @Test(arguments: DrivingPresentationKind.allCases)
    func aDeliveryWhoseRevisionStopsThePresentationIsNotShown(_ kind: DrivingPresentationKind) {
        let host = ReplayHost()
        let driven = Driven(kind, host)
        let stop = Once { driven.stop() }
        host.offer(Shot(1, onRead: { MainActor.assumeIsolated { stop.run() } }))
        #expect(driven.snapshot() == 0)
        #expect(!driven.isObserving())
        driven.resume()
        #expect(driven.isObserving())
        #expect(driven.snapshot() == 0)
    }
}

/// A driving presentation that a test holds only through this value, so that dropping it and
/// `detach()` leave no reference of the test's own.
@MainActor private struct HeldPresentation {
    let object: AnyObject & Sendable
    let stop: () -> Void
    private let arm: (@escaping () -> Void) -> Void
    private let release: () -> Void
    fileprivate init(
        object: AnyObject & Sendable,
        stop: @escaping () -> Void,
        arm: @escaping (@escaping () -> Void) -> Void,
        release: @escaping () -> Void
    ) {
        self.object = object
        self.stop = stop
        self.arm = arm
        self.release = release
    }
    /// Runs `action` once, from the announcement of the next snapshot change.
    func onNextChange(_ action: @escaping () -> Void) { arm(action) }
    /// Ends the observation of changes.
    func detach() { release() }
}

extension DrivingPresentationKind {
    /// A presentation of `host` that the returned value holds weakly but for `object`.
    @MainActor fileprivate static func make(_ kind: DrivingPresentationKind, _ host: ReplayHost) -> HeldPresentation {
        if kind == .observation, #available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *) {
            let presentation = StateMachinePresentation(host)
            return HeldPresentation(
                object: presentation,
                stop: { [weak presentation] in presentation?.stopObserving() },
                arm: { [weak presentation] action in
                    guard let presentation else { return }
                    let once = Once(action)
                    withObservationTracking {
                        _ = presentation.snapshot
                    } onChange: {
                        MainActor.assumeIsolated { once.run() }
                    }
                },
                release: {}
            )
        }
        let presentation = StateMachineObservableObject(host)
        let box = CancellableBox()
        return HeldPresentation(
            object: presentation,
            stop: { [weak presentation] in presentation?.stopObserving() },
            arm: { [weak presentation] action in
                let once = Once(action)
                box.cancellable = presentation?.objectWillChange.sink { once.run() }
            },
            release: { box.cancellable = nil }
        )
    }
}

/// The subscription of a Combine callback, which the test ends before releasing its presentation.
@MainActor private final class CancellableBox {
    var cancellable: AnyCancellable?
}
