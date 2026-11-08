import StateMachine
import StateMachineExamples
import Foundation
typealias Flow = ReferenceProfile
func misuse(_ resource: consuming ResourceWorkflow.Resource) { _ = AtomicRecordStorage(resource) }
