import StateMachine
import StateMachineSchema

final class Box { var text = "" }

@StateMachine(mode: .isolated)
nonisolated enum Note {
    struct Draft { let box: Box }
    struct Saving { let box: Box }
    @Initial case draft(Draft)
    case saving(Saving)
    enum Scope { case save }
    enum Input { case save, edit(String) }
    enum Effect { case save(Save.Input) }
    @Operation(scope: Scope.save, activeIn: [Saving.self], admission: .rejectWhenActive)
    enum Save {
        typealias Input = Box
        typealias Output = Box
        typealias Failure = Never
    }
    @Transition(on: Input.save, starts: [Save.self])
    fileprivate static func save(_ source: borrowing Draft) -> Change<Saving, Effect> {
        Change(Saving(box: source.box), effects: [.save(source.box)])
    }
    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: borrowing Draft, _ text: String) -> Change<Draft, Effect> {
        Change(copy source)
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: borrowing Saving, _ box: Save.Output) -> Change<Draft, Effect> {
        Change(Draft(box: box))
    }
}
