import StateMachine
import StateMachineExamples
// The sealed completion reaches the owner only through delivery.
nonisolated func accepted(_ owner: inout GeneratedProfile.Local, _ work: GeneratedProfile.FetchWork, _ value: Profile) {
    _ = owner.deliver(work.succeeded(value))
}
