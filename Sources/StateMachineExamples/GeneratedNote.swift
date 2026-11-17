import StateMachine
import StateMachineSchema

/// The isolated schema counterpart of the handwritten editor, with confined value inputs and outputs.
@StateMachine(mode: .isolated)
nonisolated public enum GeneratedNote {
    /// Independent editable data.
    public struct Draft: ~Sendable {
        /// The current text.
        public let text: String
        /// Creates ordinary draft data.
        public init(text: String) { self.text = text }
    }
    /// Historical submitted data, independent of whether its task remains authorized.
    public struct Saving: ~Sendable {
        /// The submitted text.
        public let text: String
        /// Creates ordinary historical data.
        public init(text: String) { self.text = text }
    }
    /// Independent saved data returned within the driver's actor.
    public struct Saved: ~Sendable {
        /// The saved text.
        public let text: String
        /// Creates ordinary result data without granting completion authority.
        public init(text: String) { self.text = text }
    }
    @Initial case draft(Draft)
    case saving(Saving)
    case saved(Saved)
    /// Authority that edges invalidate and operations hold.
    enum Scope { case save }
    /// Dynamic editor inputs.
    public enum Input: ~Sendable {
        case save
        case edit(String)
        case cancel
    }
    /// One confined operation; no Sendable conformance is imposed on its input or outcome.
    @Operation(scope: Scope.save, activeIn: [Saving.self], admission: .latest)
    public enum Save {
        /// The immutable input.
        public typealias Input = Draft
        /// The independent output.
        public typealias Output = Saved
        /// This sample's storage cannot fail.
        public typealias Failure = Never
    }
    @Transition(on: Input.save, starts: [Save.self])
    fileprivate static func begin(_ source: Draft) -> Change<Saving, Effect.Begin> {
        Change(Saving(text: source.text), effects: [.save(Draft(text: source.text))])
    }
    @Transition(onSuccess: Save.self)
    fileprivate static func received(_ source: Saving, _ output: Save.Output) -> Saved {
        output
    }
    @Transition(on: Input.edit)
    fileprivate static func edit(_ source: Draft, _ text: String) -> Draft {
        Draft(text: text)
    }
    @Transition(on: Input.edit)
    fileprivate static func replace(_ source: Saving, _ text: String) -> Draft {
        Draft(text: text)
    }
    @Transition(on: Input.cancel)
    fileprivate static func cancel(_ source: Saving) -> Draft {
        Draft(text: source.text)
    }
}
