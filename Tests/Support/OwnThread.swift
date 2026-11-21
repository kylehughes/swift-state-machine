import Foundation

/// Runs `work` on a new thread of its own.
///
/// A test that blocks a thread, the main thread or a cooperative-pool one, until work on another
/// thread has run gives that work a thread of its own. Work on Dispatch's global queues waits for a
/// thread in the same per-process allowance as the cooperative pool, so while every pool thread is
/// blocked, global-queue work does not start either, and a test that waits for it on the main thread
/// or on the pool can stall the whole run. A thread of its own always starts.
public func runOnOwnThread(_ work: @escaping @Sendable () -> Void) {
    Thread { work() }.start()
}
