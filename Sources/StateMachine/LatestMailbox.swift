import os

// A capacity-one serial mailbox. Its state sits behind one lock: a change takes the envelope it
// replaces or claims out of the state, and client callbacks and the release of displaced payloads run
// after unlocking, so a call that only reads a flag never holds a payload.
nonisolated package final class LatestMailbox<Value: Sendable>: Sendable {
    private struct Envelope: Sendable {
        let revision: UInt64?
        let value: Value
        let terminal: Bool
    }
    private struct State: Sendable {
        var watermark: UInt64?
        var pending: Envelope?
        var scheduled = false
        // Set once a terminal envelope is claimed or the registration is cancelled.
        var closed = false
        var registered = false
        // Set when the owner released the lease without a terminal envelope pending or claimed.
        var released = false
    }
    private let storage: OSAllocatedUnfairLock<State>
    private let receive: @Sendable (Value) -> Void
    private let finish: @Sendable () -> Void
    private let onRelease: (@Sendable () -> Void)?
    /// Closed by cancellation; its token closes it too, even after the owner has released this mailbox.
    package let gate = RuntimeRegistrationGate()

    /// Creates a mailbox whose first envelope is `initial`.
    ///
    /// With a `revision`, an offer replaces the last accepted one only when its revision is greater,
    /// because revisions only grow. Without one, every offer is newer than the last, because its owner
    /// offers values in order, through one serial delivery, as a `Shared` owner offers images of its
    /// retained completions.
    ///
    /// `onRelease` runs once, at once, when the owner releases the registration without closing, even
    /// while a delivery is still in progress; `finish` follows that delivery.
    package init(
        initial: Value,
        revision: UInt64?,
        terminal: Bool,
        receive: @escaping @Sendable (Value) -> Void,
        finish: @escaping @Sendable () -> Void,
        onRelease: (@Sendable () -> Void)? = nil
    ) {
        storage = OSAllocatedUnfairLock(
            initialState: State(
                watermark: revision,
                pending: Envelope(revision: revision, value: initial, terminal: terminal)
            )
        )
        self.receive = receive
        self.finish = finish
        self.onRelease = onRelease
    }

    // Called only after successful registration; a newer offer may already own
    // the same serial delivery loop and may have replaced the staged initial value.
    package func activate() {
        let wake = storage.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.registered = true
            let wake = !state.scheduled && (state.pending != nil || state.released)
            if wake { state.scheduled = true }
            return wake
        }
        if wake { Task { self.deliver() } }
    }

    /// Records that the owner was released, which its lifetime reports once, from its destructor.
    ///
    /// A registration that is cancelled, or whose closed snapshot is pending or claimed, has nothing
    /// more to decide. Otherwise the owner promised nothing more: the release is reported at once, and
    /// the finish follows any delivery still pending or running, on a later task outside the releasing
    /// context. A delivery in progress retains the mailbox, not the owner, so the owner's release is
    /// decided here whatever a delivery, or a cancellation that reads the owner's state, still holds.
    package func release() {
        let open = gate.isOpen
        let decision = storage.withLock { state -> Bool? in
            guard state.registered, !state.closed, !state.released, state.pending?.terminal != true, open
            else { return nil }
            state.released = true
            let wake = !state.scheduled
            state.scheduled = true
            return wake
        }
        guard let wake = decision else { return }
        onRelease?()
        if wake { Task { self.deliver() } }
    }

    /// Offers `value`, which replaces any envelope not yet claimed unless its `revision` is not greater
    /// than the last accepted one; an offer without a revision is always newer.
    package func offer(_ value: Value, revision: UInt64?, terminal: Bool) {
        var changed = storage.withLock { state -> (wake: Bool, replaced: Envelope?)? in
            guard !state.closed else { return nil }
            if let revision, let watermark = state.watermark, revision <= watermark { return nil }
            state.watermark = revision
            let envelope = Envelope(revision: revision, value: value, terminal: terminal)
            let replaced = exchange(&state.pending, with: envelope)
            let wake = !state.scheduled
            state.scheduled = true
            return (wake, replaced)
        }
        guard let wake = changed?.wake else { return }
        changed = nil
        if wake { Task { self.deliver() } }
    }

    package func cancel() {
        gate.close()
        let discarded = storage.withLock { state -> Envelope? in
            guard !state.closed else { return nil }
            state.closed = true
            return state.pending.take()
        }
        withExtendedLifetime(discarded) {}
    }

    private func deliver() {
        var delivered = 0
        while true {
            var step = storage.withLock { state -> (envelope: Envelope?, finishing: Bool) in
                guard !state.closed, let envelope = state.pending.take() else {
                    // An owner released without closing finishes once nothing is left to deliver; the gate
                    // keeps a cancellation that came first from beginning the finish.
                    let finishing = !state.closed && state.released
                    if finishing { state.closed = true }
                    state.scheduled = false
                    return (nil, finishing)
                }
                if envelope.terminal { state.closed = true }
                return (envelope, false)
            }
            guard let envelope = step.envelope.take() else {
                if step.finishing, gate.isOpen { finish() }
                return
            }
            // Claiming an envelope and then finding the gate open is the invocation boundary. A
            // cancellation closes the gate before anything else, so one whose caller returned before
            // this read keeps the callback from beginning, and the envelope is released here, outside
            // the lock. A cancellation after this read can leave this one in-flight callback, but no
            // later callback is claimed.
            guard gate.isOpen else {
                cancel()
                return
            }
            receive(envelope.value)
            if envelope.terminal {
                // A receive that cancelled the registration keeps its finish from beginning.
                if gate.isOpen { finish() }
                return
            }
            delivered += 1
            if delivered == 32 {
                Task {
                    await Task.yield()
                    self.deliver()
                }
                return
            }
        }
    }
}
