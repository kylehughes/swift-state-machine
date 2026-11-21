import StateMachine
import StateMachineExamples

// A schema that does not list Equatable leaves its effects without it.
nonisolated func misuse(_ request: ProfileRequest) -> Bool {
    GeneratedProfile.Effect.fetch(request) == GeneratedProfile.Effect.fetch(request)
}
