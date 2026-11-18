import StateMachine

final class Box { var text = "" }

@StateMachine(mode: .isolated)
nonisolated enum Note {
    struct Draft { let box: Box }
    struct Saving { let box: Box }
    @Initial case draft(Draft)
    case saving(Saving)
    enum Input { case save, edit(String) }
    @Operation(activeIn: [Saving.self], admission: .rejectWhenActive)
    enum Save {
        typealias Input = Box
        typealias Output = Box
    }
    @Operation(activeIn: [Draft.self])
    enum Autosave {
        typealias Input = String
        typealias Output = Void
    }
    @Restoration(allows: [Draft.self])
    fileprivate static func restore(_ saved: Box) -> Restoration {
        .draft(Draft(box: saved))
    }
    @Transition(on: Input.save, starts: [Save.self])
    fileprivate static func save(_ source: Draft) -> Change<Saving, Effect.Save> {
        Change(Saving(box: source.box), effects: [.save(source.box)])
    }
    @Transition(on: Input.edit, starts: [Autosave.self])
    fileprivate static func edit(_ source: Draft, _ text: String) -> Change<Draft, Effect.Edit> {
        Change(source, effects: [.autosave(text)])
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Saving, _ box: Save.Output) -> Draft {
        Draft(box: box)
    }
    @Transition(onSuccess: Autosave.self)
    fileprivate static func autosaved(_ source: Draft, _ output: Autosave.Output) -> Draft {
        source
    }
}
