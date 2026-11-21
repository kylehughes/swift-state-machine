import StateMachine
import StateMachineExamples

// An operation without input issues work that has no input.
nonisolated func misuse(_ work: GeneratedScreen.MeasureWork) {
    _ = work.input
}
