import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Editor: Sendable {
    struct Draft: Sendable {}
    struct Failed: Sendable {}
    struct Saving: Sendable {}
    @Initial case draft(Draft)
    case failed(Failed)
    case saving(Saving)
    enum Input: Sendable { case retry, fail }
    @Operation(activeIn: [Saving.self])
    enum Save {}
    @Operation(activeIn: [Saving.self])
    enum Audit {}
    @Transition(on: Input.retry, starts: [Save.self])
    fileprivate static func retry(_ source: Draft) -> Change<Saving, Effect.Draft.Retry> {
        Change(Saving(), effects: [.save])
    }
    @Transition(on: Input.retry, starts: [Save.self, Audit.self])
    fileprivate static func retry(_ source: Failed) -> Change<Saving, Effect.Failed.Retry> {
        Change(Saving(), effects: [.save, .audit])
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Saving) -> Draft { Draft() }
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: Saving) -> Saving { source }
    @Transition(on: Input.fail)
    fileprivate static func fail(_ source: Saving) -> Failed { Failed() }
}
// Same-named edges that start different operations have their own phase-qualified effect types.
nonisolated func accepted() -> [Editor.Effect.Failed.Retry] { [.save, .audit] }
