import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func request() -> ProfileRequest { try! ProfileRequest(userID: UserID("kyle")) }
func legal(_ initial: Flow.Idle) {
 let owner = Flow.owned(initial)
 let result = owner.load(request())
 switch consume result {
 case .advanced(let next, let effects): _ = next.withValue { $0.request }; _ = effects
 case .rejected(_, let original): _ = original.withValue { $0.userID }
 }
}
nonisolated func consumeFinished(_ finished: consuming ValueWorkflow.Owned<ValueWorkflow.Finished>) {
 _ = finished.withValue { $0.value }
}
nonisolated func retainEffectsWhileConsumingSuccessor() -> [ValueWorkflow.Effect] {
 let result = ValueWorkflow.start(.init(value: 7)).finish(label: "done")
 let effects = result.effects
 consumeFinished(result.next)
 return effects
}
