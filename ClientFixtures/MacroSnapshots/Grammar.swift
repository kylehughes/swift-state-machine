import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Editor: Sendable, Equatable {
    struct Draft: Sendable, Equatable { var text = "" }
    struct Saving: Sendable, Equatable { let text: String }
    struct Failed: Sendable, Equatable { let text: String }
    struct Closed: Sendable, Equatable {}
    @Initial case draft(Draft = Draft())
    case saving(Saving)
    case failed(Failed)
    case closed(Closed)
    enum Input: Sendable { case edit(String), retry, close, pick(Int) }
    enum DraftError: Error, Sendable { case empty }
    enum SavingError: Error, Sendable { case locked }
    typealias Problem = DraftError
    @Operation(activeIn: [Saving.self])
    enum Save { typealias Input = String }
    @Operation(activeIn: [Saving.self])
    enum Audit {}
    @Operation(activeIn: [Closed.self])
    enum Archive {}
    @Restoration(only: [Draft.self, Failed.self])
    fileprivate static func restore(_ saved: String) -> Restoration { .draft(Draft(text: saved)) }
    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: Draft, _ text: String) throws(DraftError) -> Draft { Draft(text: text) }
    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: Saving, _ text: String) throws(SavingError) -> Saving { source }
    @Transition(on: Input.retry, starts: [Save.self])
    fileprivate static func retry(_ source: Draft) -> Change<Saving, Effect.Draft.Retry> {
        Change(Saving(text: source.text), effects: [.save(source.text)])
    }
    @Transition(on: Input.retry, starts: [Save.self, Audit.self])
    fileprivate static func retry(_ source: Failed) -> Change<Saving, Effect.Failed.Retry> {
        Change(Saving(text: source.text), effects: [.save(source.text), .audit])
    }
    @Transition(from: [Draft.self, Failed.self], on: Input.close, starts: [Archive.self])
    fileprivate static func close() -> Change<Closed, Effect.Close> { Change(Closed(), effects: [.archive]) }
    @Transition(on: Input.pick)
    fileprivate static func keep(_ source: Failed, _ value: Int) -> Failed { source }
    @Transition(on: Input.pick)
    fileprivate static func discard(_ source: Failed, _ value: Int) throws(Problem) -> Draft { Draft() }
    @Route(on: Input.pick, failure: DraftError.self)
    fileprivate static func pick(_ source: Failed, _ value: Int) -> Route.Pick { value > 0 ? .keep : .discard }
    @Transition(onSuccess: Save.self)
    fileprivate static func saved(_ source: Saving) -> Draft { Draft(text: source.text) }
    @Transition(onSuccess: Audit.self)
    fileprivate static func audited(_ source: Saving) -> Saving { source }
    @Transition(onSuccess: Archive.self)
    fileprivate static func archived(_ source: Closed) -> Closed { source }
}

@StateMachine(mode: .isolated)
nonisolated enum Sketch: Equatable {
    struct Blank: Equatable {}
    struct Drawn: Equatable { let strokes: Int }
    @Initial case blank(Blank)
    case drawn(Drawn)
    enum Input { case draw(Int), erase }
    @Operation(activeIn: [Drawn.self])
    enum Render { typealias Input = Int }
    @Transition(on: Input.draw, starts: [Render.self])
    fileprivate static func draw(_ source: Blank, _ strokes: Int) -> Change<Drawn, Effect.Draw> {
        Change(Drawn(strokes: strokes), effects: [.render(strokes)])
    }
    @Transition(from: [Blank.self, Drawn.self], on: Input.erase)
    fileprivate static func erase() -> Blank { Blank() }
    @Transition(onSuccess: Render.self)
    fileprivate static func rendered(_ source: Drawn) -> Drawn { source }
}
