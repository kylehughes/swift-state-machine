import StateMachine
// A client names the runtime support that generated code and public signatures use.
nonisolated func accepted(_ limits: Limits, _ configuration: ManagedConfiguration) -> Int {
    limits.executions + configuration.subscriberCapacity
}
