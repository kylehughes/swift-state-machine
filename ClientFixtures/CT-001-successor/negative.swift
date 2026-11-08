import StateMachine
import StateMachineExamples

nonisolated func consumeFinished(_ finished: consuming ValueWorkflow.Owned<ValueWorkflow.Finished>) {
 _ = finished.withValue { $0.value }
}
nonisolated func misuseInfallibleSuccessor() {
 let result = ValueWorkflow.start(.init(value: 7)).finish(label: "done")
 consumeFinished(result.next)
 consumeFinished(result.next)
}
