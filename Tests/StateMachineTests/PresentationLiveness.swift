import Combine
import Observation
import StateMachineUI

// A presentation reports an observation live once it has shown the observation's first snapshot,
// which a sequence's owner can deliver on a later turn. These waits end on the presentation's own
// report of that change, never on scheduling.

/// Returns once `presentation` reports a live observation.
@MainActor func untilObserving<Snapshot>(_ presentation: SnapshotObservableObject<Snapshot>) async {
    var subscription: AnyCancellable?
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        var resumed = false
        // The published value arrives at once, and then with each change.
        subscription = presentation.$isObserving.sink { live in
            guard live, !resumed else { return }
            resumed = true
            continuation.resume()
        }
    }
    subscription?.cancel()
}

/// Returns once `presentation` reports a live observation.
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, macCatalyst 17.0, *)
@MainActor func untilObserving<Snapshot>(_ presentation: SnapshotPresentation<Snapshot>) async {
    while !presentation.isObserving {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = presentation.isObserving
            } onChange: {
                continuation.resume()
            }
        }
    }
}
