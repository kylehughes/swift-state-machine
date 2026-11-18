import StateMachine
@StateMachine(mode: .shared)
nonisolated enum Archived: Sendable {
    struct Editing: Sendable { let text: String }
    struct Publishing: Sendable { let text: String }
    @Initial case editing(Editing)
    case publishing(Publishing)
    enum Input: Sendable { case edit(String), publish }
    @Operation(activeIn: [Editing.self])
    enum Autosave { typealias Input = String; typealias Output = Void }
    @Operation(activeIn: [Publishing.self])
    enum Publish { typealias Input = String; typealias Output = Void }
    @Restoration(allows: [Editing.self])
    fileprivate static func restore(_ saved: String) -> Restoration { .editing(Editing(text: saved)) }
    @Transition(on: Input.edit, starts: [Autosave.self])
    fileprivate static func edit(_ source: Editing, _ text: String) -> Change<Editing, Effect.Edit> {
        Change(Editing(text: text), effects: [.autosave(text)])
    }
    @Transition(on: Input.publish, starts: [Publish.self])
    fileprivate static func publish(_ source: Editing) -> Change<Publishing, Effect.Publish> {
        Change(Publishing(text: source.text), effects: [.publish(source.text)])
    }
    @Transition(onSuccess: Autosave.self)
    fileprivate static func autosaved(_ source: Editing, _ output: Autosave.Output) -> Editing { source }
    @Transition(onSuccess: Publish.self)
    fileprivate static func published(_ source: Publishing, _ output: Publish.Output) -> Editing {
        Editing(text: source.text)
    }
}
// A phase in which an operation can be active is restorable only when it is listed.
nonisolated func misuse() {
    let restored: Archived.Restoration = .publishing(Archived.Publishing(text: "saved"))
    _ = restored
}
