import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func legal(_ resource: consuming ResourceWorkflow.Resource) { let owner = ResourceWorkflow.start(resource); _ = owner.finish(label: "done"); _ = AtomicRecordStorage(1) }
