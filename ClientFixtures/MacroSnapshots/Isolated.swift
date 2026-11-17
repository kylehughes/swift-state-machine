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
    @Operation(scope: Scope.save, activeIn: [Saving.self], admission: .rejectWhenActive)
    enum Save {
        typealias Input = Box
        typealias Output = Box
        typealias Failure = Never
    }
    @Restoration
    fileprivate static func restore(_ saved: Box) -> Restoration {
        .draft(Draft(box: saved))
    }
    @Transition(on: Input.save, starts: [Save.self])
    fileprivate static func save(_ source: Draft) -> Change<Saving, Effect.Save> {
        Change(Saving(box: source.box), effects: [.save(source.box)])
    }
    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: Draft, _ text: String) -> Draft {
        source
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Saving, _ box: Save.Output) -> Draft {
        Draft(box: box)
    }
}
