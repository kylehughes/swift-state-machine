import StateMachine
import StateMachineExamples
// An operation that cannot fail has no failure to seal.
nonisolated func misuse(_ work: GeneratedNote.SaveWork, _ never: Never) -> GeneratedNote.SaveCompletion {
    work.failed(never)
}
