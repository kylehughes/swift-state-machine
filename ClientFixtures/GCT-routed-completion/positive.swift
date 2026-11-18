import StateMachine
import StateMachineExamples
// An owned phase finishes a routed completion through its router, which can decline the value.
nonisolated func accepted() -> Bool {
    switch GeneratedScreen.owned().screen(-1) {
    case .accept: return true
    case .rejected: return false
    @unknown default: return false
    }
}
