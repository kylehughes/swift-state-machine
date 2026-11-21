import StateMachine
import StateMachineExamples

// An operation without input is requested without a payload, and its work seals its output.
nonisolated func accepted(_ work: GeneratedScreen.MeasureWork) -> GeneratedScreen.MeasureCompletion {
    let effects: [GeneratedScreen.Effect] = [.measure]
    _ = effects
    return work.succeeded(4)
}
