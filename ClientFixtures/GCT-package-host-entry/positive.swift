import StateMachine
// A raw shared host is observable and closable from any client.
nonisolated func accepted(_ host: RuntimeSharedHost<Int, Int, RuntimeTicket, Never>) -> UInt64 {
    host.close().revision
}
