import Dispatch
import Foundation
import StateMachine
import StateMachineTestSupport
import os

/// Releases `kept` on another thread in the schedule where the destructor's main-actor job finishes
/// first, and returns once the release has finished.
///
/// That thread pauses right after the destructor has made its job runnable, until the job has run on
/// the main actor, and only then returns from the destructor and destroys the object's stored
/// properties.
///
/// A value that the job does not own alone, because the object's own storage still refers to it, is
/// released on the dropping thread in this schedule. The main actor must be free while this waits.
///
/// The dropping thread is one of its own: it blocks until the main actor has run the job, and a
/// cooperative-pool thread blocked there would be one fewer for every other test.
func dropAfterItsJob<Kept: Sendable>(_ kept: consuming Kept) async {
    let slot = OSAllocatedUnfairLock<Kept?>(initialState: kept)
    await withCheckedContinuation { (dropped: CheckedContinuation<Void, Never>) in
        runOnOwnThread {
            DestructorPause.$afterScheduling.withValue({
                // The jobs a destructor enqueues inherit this binding, and a destructor that runs inside
                // one of them, on the main actor, does not pause.
                guard !Thread.isMainThread else { return }
                // Main-actor jobs run in the order they were enqueued, so this one runs after the job the
                // destructor has just enqueued has returned.
                let ran = DispatchSemaphore(value: 0)
                Task { @MainActor in ran.signal() }
                ran.wait()
            }) {
                slot.withLock { $0 = nil }
            }
            dropped.resume()
        }
    }
}
