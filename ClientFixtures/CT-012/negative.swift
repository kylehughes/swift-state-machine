import StateMachine
import StateMachineExamples
import Foundation

func misuse(_ note: IsolatedNote.Draft) {
    let isolated = RuntimeState<IsolatedNote.Draft, IsolatedNote.Draft>(note, limits: try! RuntimeLimits())
    _ = AtomicRecordStorage(isolated)
}
