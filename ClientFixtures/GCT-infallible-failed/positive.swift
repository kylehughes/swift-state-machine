import StateMachine
import StateMachineExamples
// An operation that cannot fail seals only a success.
nonisolated func accepted(_ work: GeneratedNote.SaveWork) -> GeneratedNote.SaveCompletion {
    work.succeeded(GeneratedNote.Saved(text: work.input.text))
}
