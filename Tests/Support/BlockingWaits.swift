import Dispatch
import os

// A test that blocks a thread waits for a step that some other code takes: a thread of its own, a
// production callback, or a later line of the test. When that step can be skipped, by a failed
// requirement, a thrown error, or a wait that the test's cancellation ended early, as when its time
// limit expires, an untimed wait blocks for the rest of the run. These helpers make every such wait
// end: a hold is released on every path out of the test, and a test's own wait ends when its task is
// cancelled.

/// A gate that holds every thread that waits on it until a test opens it, and then stays open.
///
/// A test that holds a production callback or a thread of its own here opens the gate in a `defer`
/// right after making it, as well as at the step that lets the thread go, so no path out of the test
/// leaves the thread held. Opening it again changes nothing.
public final class ThreadGate: Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let opened = OSAllocatedUnfairLock(initialState: false)

    /// Makes a closed gate.
    public init() {}

    /// Whether the gate has opened.
    public var isOpen: Bool { opened.withLock { $0 } }

    /// Opens the gate, letting go every thread that waits on it, now or later.
    public func open() {
        let opening = opened.withLock { opened in
            defer { opened = true }
            return !opened
        }
        if opening { semaphore.signal() }
    }

    /// Blocks the calling thread until the gate opens, however long that takes.
    ///
    /// A hold inside production code waits here, so a task that the code cancels while it is held stays
    /// held; the test's `defer` opens the gate.
    public func wait() {
        semaphore.wait()
        // Each thread the gate lets go passes the opening on to the next.
        semaphore.signal()
    }

    /// Blocks the calling thread until the gate opens or the calling task is cancelled; outside any
    /// task, until the gate opens.
    ///
    /// A hold that may run on the test's own task waits here, so the test's cancellation ends it.
    ///
    /// - Returns: Whether the gate opened.
    @discardableResult public func waitUnlessCancelled() -> Bool {
        guard semaphore.waitUnlessCancelled() else { return false }
        semaphore.signal()
        return true
    }
}

extension DispatchSemaphore {
    /// Waits for a signal, as `wait()` does, unless the calling task is cancelled first; outside any
    /// task, until the signal arrives.
    ///
    /// A test that blocks its own thread until another thread has taken a step returns when its task
    /// is cancelled, so a step that never comes fails the test at its time limit rather than hanging the
    /// run.
    ///
    /// - Returns: Whether the signal arrived.
    @discardableResult public func waitUnlessCancelled() -> Bool {
        while wait(timeout: .now() + .milliseconds(10)) == .timedOut {
            if Task.isCancelled { return false }
        }
        return true
    }
}

/// Runs `work` on a new thread of its own, as ``runOnOwnThread(_:)`` does, and blocks the calling
/// thread until `work` has returned or the calling task is cancelled.
///
/// - Returns: Whether `work` returned.
@discardableResult public func runOnOwnThreadAndWait(_ work: @escaping @Sendable () -> Void) -> Bool {
    let done = DispatchSemaphore(value: 0)
    runOnOwnThread {
        work()
        done.signal()
    }
    return done.waitUnlessCancelled()
}
