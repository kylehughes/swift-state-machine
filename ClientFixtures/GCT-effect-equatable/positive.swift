import StateMachine
import StateMachineExamples

// A schema that lists Equatable gives its effects Equatable in every module.
nonisolated func accepted() -> Bool {
    GeneratedScreen.owned().take().effects == [.measure]
}
