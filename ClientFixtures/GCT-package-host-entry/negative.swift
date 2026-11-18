import StateMachine
// Draining and acknowledging a manually driven host are package entry points, not client API.
nonisolated func misuse(_ host: RuntimeSharedHost<Int, Int, RuntimeTicket, Never>) {
    _ = host.drainCommands(limit: 1)
}
