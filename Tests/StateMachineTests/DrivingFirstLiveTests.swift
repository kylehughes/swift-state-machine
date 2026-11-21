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
// finds its snapshot released at once.

/// A snapshot that carries only its revision and reports its release.
private final class Shot: StateMachineSnapshot, Sendable {
    let revision: UInt64
    init(_ revision: UInt64) { self.revision = revision }
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
}
