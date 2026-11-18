import StateMachine
import StateMachineExamples
// A routed completion edge has no owned method of its own, so a typed call cannot skip the router.
nonisolated func misuse() -> GeneratedScreen.Owned<GeneratedScreen.Ready> {
    GeneratedScreen.owned().accept(-1)
}
