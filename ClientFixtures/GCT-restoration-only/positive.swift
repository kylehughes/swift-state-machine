import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Archive: Sendable {
    struct Draft: Sendable { var text = "" }
    struct Saving: Sendable { let text: String }
    struct Published: Sendable { let text: String }
    @Initial case draft(Draft = Draft())
    case saving(Saving)
    @Terminal case published(Published)
    enum Input: Sendable { case save }
    @Operation(activeIn: [Saving.self])
    enum Save { typealias Input = String }
    @Restoration(only: [Saving.self, Published.self])
    fileprivate static func restore(_ saved: String) -> Restoration { .published(Published(text: saved)) }
    @Transition(on: Input.save, starts: [Save.self])
    fileprivate static func save(_ source: Draft) -> Change<Saving, Effect.Save> {
        Change(Saving(text: source.text), effects: [.save(source.text)])
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Saving) -> Published { Published(text: source.text) }
}
// Exactly the listed phases are restorable, including one in which an operation can be active.
nonisolated func accepted(_ restoration: Archive.Restoration) -> String {
    switch restoration {
    case .saving(let saving): saving.text
    case .published(let published): published.text
    }
}
