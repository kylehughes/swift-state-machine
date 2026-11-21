// One name may leave different phases.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Editor: Sendable {
    struct Draft: Sendable { let text: String }
    struct Saving: Sendable { let text: String }
    @Initial case draft(Draft)
    case saving(Saving)
    enum Input: Sendable { case edit(String), clear, save }
    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: Draft, _ text: String) -> Draft { Draft(text: text) }
    @Transition(on: Input.save)
    fileprivate static func save(_ source: Draft) -> Saving { Saving(text: source.text) }
    @Transition(on: Input.clear)
    fileprivate static func edit(_ source: Saving) -> Draft { Draft(text: "") }
}
