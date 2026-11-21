import Combine
import Dispatch
import StateMachine
import StateMachineUI

// The thin layer that adapts the explorer to the presentation API of one source tree. A copy of the
// package that replays scripts against a modified tree replaces only this file when that tree's API
// differs (`Tests/ScheduleExplorer.md`, "Maintaining the explorer").

/// Whether the tree has the removal-observation pause (H1) and the driver-start pause (H2).
let explorerHasRemovalPause = true
let explorerHasDriverPause = true
/// Runs `body` with H1 bound to `pause`.
func explorerWithRemovalPause(_ pause: @escaping @Sendable () -> Void, _ body: () -> Void) {
    RemovalObservationPause.$beforeObserving.withValue(pause) { body() }
}
/// Runs `body` with the driver-start pause (H6, task-local) bound: a driver that `body` launches runs
/// `pause` before it starts.
@MainActor func explorerWithDriverPause<Result>(
    _ pause: @escaping @Sendable () -> Void,
    _ body: () async -> Result
) async -> Result {
    await DriverStartPause.$beforeStarting.withValue({ _ in pause() }) { await body() }
}
/// Whether the tree has the decided-delivery pause (H7), the removal-completion pause (H8), and the
/// capacity-conflict pause (H9).
let explorerHasDecidedDeliveryPause = true
let explorerHasRemovalCompletionPause = true
let explorerHasCapacityConflictPause = true
/// Runs `body` with H7 bound: a publisher's delivery that `body` makes runs `pause` right before
/// `receive`, after its last source check.
@MainActor func explorerWithDecidedDeliveryPause(_ pause: @escaping @Sendable () -> Void, _ body: () -> Void) {
    DecidedDeliveryPause.$beforeReceive.withValue(pause) { body() }
}
/// Runs `body` with H8 bound: a main-actor end of a sequence that `body` begins runs `pause` after it
/// released the discarded element and before its completion.
@MainActor func explorerWithRemovalCompletionPause(_ pause: @escaping @Sendable () -> Void, _ body: () -> Void) {
    RemovalCompletionPause.$afterCustody.withValue(pause) { body() }
}
/// Runs `body` with H9 bound: a batch of capacity conflicts found by work that `body` starts reports its
/// pending IDs to `pause` before any handler runs.
@MainActor func explorerWithCapacityConflictPause<Result>(
    _ pause: @escaping @Sendable ([RuntimePendingID]) -> Void,
    _ body: () async -> Result
) async -> Result {
    await CapacityConflictPause.$beforeReports.withValue(pause) { await body() }
}
/// Whether the tree has the hand-off pause (H3).
let explorerHasHandOffPause = true
/// Runs `body` with H3 bound to `pause`, so the hand-offs of a publisher registered inside it run `pause`.
func explorerWithHandOffPause<Result>(_ pause: @escaping @Sendable () -> Void, _ body: () -> Result) -> Result {
    HandOffPause.$afterTaking.withValue(pause) { body() }
}

/// Runs the async `body` with H3 bound to `pause`.
@MainActor func explorerWithHandOffPause<Result>(
    _ pause: @escaping @Sendable () -> Void,
    _ body: () async -> Result
) async -> Result {
    await HandOffPause.$afterTaking.withValue(pause) { await body() }
}
/// Whether the tree has the release-notice pause (H4) and the count-read pause (H5).
let explorerHasReleaseNoticePause = true
let explorerHasCountReadPause = true
/// Runs `body` with H4 bound to `pause`, which then runs after each of an owner's release notices.
nonisolated func explorerWithReleaseNoticePause(_ pause: @escaping @Sendable () -> Void, _ body: () -> Void) {
    ReleaseNoticePause.$afterNotice.withValue(pause) { body() }
}

/// Whether the driving presentations have `resumeObserving()`.
let explorerHasResume = true
/// Calls `resumeObserving()` of a driving presentation.
@MainActor func explorerResume<Host: MainActorStateMachineHost>(
    _ presentation: StateMachineObservableObject<Host>
) throws(SubscriptionFailure) {
    try presentation.resumeObserving()
}
@available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@MainActor func explorerResume<Host: MainActorStateMachineHost>(
    _ presentation: StateMachinePresentation<Host>
) throws(SubscriptionFailure) {
    try presentation.resumeObserving()
}

/// Whether the tree has `presentedSnapshots(projecting:)`.
let explorerHasProjection = true

/// Attaches `subscriber` to the presentation's `presentedSnapshots`.
@MainActor func explorerSubscribe(
    _ presentation: SnapshotObservableObject<ExplorerShot>,
    _ subscriber: ExplorerSubscriber
) {
    presentation.presentedSnapshots.subscribe(subscriber)
}
/// Reads the publisher value now and returns a function that attaches a subscriber to it later.
@MainActor func explorerSave(
    _ presentation: SnapshotObservableObject<ExplorerShot>
) -> @MainActor (ExplorerSubscriber) -> Void {
    let publisher = presentation.presentedSnapshots
    return { publisher.subscribe($0) }
}
/// Attaches `subscriber` to `presentedSnapshots(projecting:)`.
@MainActor func explorerSubscribeProjected(
    _ presentation: SnapshotObservableObject<ExplorerShot>,
    _ subscriber: ExplorerSubscriber,
    _ transform: @escaping @MainActor (ExplorerShot) -> ExplorerShot
) {
    presentation.presentedSnapshots(projecting: transform).subscribe(subscriber)
}
/// Releases `kept` on another thread in the schedule where the destructor's main-actor job finishes first.
func explorerDropAfterItsJob<Kept: Sendable>(_ kept: consuming Kept) async {
    // The caller's reference is consumed here, so the worker's release is the last one.
    await dropAfterItsJob(consume kept)
}

/// Reads `presentedSnapshots(projecting:)` now and returns a function that attaches a subscriber to it later.
@MainActor func explorerSaveProjected(
    _ presentation: SnapshotObservableObject<ExplorerShot>,
    _ transform: @escaping @MainActor (ExplorerShot) -> ExplorerShot
) -> @MainActor (ExplorerSubscriber) -> Void {
    let publisher = presentation.presentedSnapshots(projecting: transform)
    return { publisher.subscribe($0) }
}
@MainActor func explorerSaveProjected(
    _ presentation: StateMachineObservableObject<ExplorerMainHost>,
    _ transform: @escaping @MainActor (ExplorerShot) -> ExplorerShot
) -> @MainActor (ExplorerSubscriber) -> Void {
    let publisher = presentation.presentedSnapshots(projecting: transform)
    return { publisher.subscribe($0) }
}

// The driving Combine class.
@MainActor func explorerSubscribe(
    _ presentation: StateMachineObservableObject<ExplorerMainHost>,
    _ subscriber: ExplorerSubscriber
) {
    presentation.presentedSnapshots.subscribe(subscriber)
}
@MainActor func explorerSave(
    _ presentation: StateMachineObservableObject<ExplorerMainHost>
) -> @MainActor (ExplorerSubscriber) -> Void {
    let publisher = presentation.presentedSnapshots
    return { publisher.subscribe($0) }
}
@MainActor func explorerSubscribeProjected(
    _ presentation: StateMachineObservableObject<ExplorerMainHost>,
    _ subscriber: ExplorerSubscriber,
    _ transform: @escaping @MainActor (ExplorerShot) -> ExplorerShot
) {
    presentation.presentedSnapshots(projecting: transform).subscribe(subscriber)
}
/// Whether the tree has the presentation publisher's delivery-decision pause (H10).
let explorerHasPresentationDeliveryPause = true
/// Runs `body` with H10 bound: a presentation publisher's delivery of a buffered value scheduled inside it runs
/// `pause` between the two reads that decide it.
@MainActor func explorerWithPresentationDeliveryPause<Result>(
    _ pause: @escaping @Sendable () -> Void,
    _ body: () async -> Result
) async -> Result {
    await PresentationDeliveryPause.$betweenReads.withValue(pause) { await body() }
}
/// Attaches `subscriber` to `presentedSnapshots` through `receive(on: queue)`, so its values, and the demand it
/// returns from each, cross to `queue`: Combine requests that demand of the presentation's subscription there.
@MainActor func explorerSubscribeElsewhere<Host: MainActorStateMachineHost>(
    _ presentation: StateMachineObservableObject<Host>,
    _ subscriber: ExplorerElsewhereSubscriber,
    on queue: DispatchQueue,
    once: Bool
) where Host.Snapshot == ExplorerShot {
    // Only the revision crosses to the queue: a client value stays the presentation's, released on the main actor.
    let revisions = presentation.presentedSnapshots.map(\.revision).receive(on: queue)
    if once {
        revisions.prefix(1).subscribe(subscriber)
    } else {
        revisions.subscribe(subscriber)
    }
}
