import StateMachine
// The execution coordinator is package machinery that no client can name.
nonisolated func misuse(_ coordinator: RuntimeCoordinator<Int, Int>) {}
