import StateMachine
import StateMachineExamples

nonisolated func consumeFinished(_ finished: consuming ValueWorkflow.Owned<ValueWorkflow.Finished>) {
 _ = finished.withValue { $0.value }
}
nonisolated func retainEffectsWhileConsumingSuccessor() -> [ValueWorkflow.Effect] {
 let result = ValueWorkflow.start(.init(value: 7)).finish(label: "done")
 let effects = result.effects
 consumeFinished(result.next)
 return effects
}
