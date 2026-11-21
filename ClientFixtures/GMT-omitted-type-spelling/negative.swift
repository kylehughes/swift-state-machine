// A bare `Void` or `Never` read inside the namespace names the namespace's own declaration, not the type the
// operation and the event omit, so no graph spelling of an omitted type can be bare.
import StateMachine

enum Swift {}
struct Void {}
enum Never {}

@StateMachine(mode: .shared, owners: [.local])
nonisolated enum Ledger: Sendable {
    enum Swift {}
    struct Void {}
    enum Never {}
    struct Open: Sendable {}
    struct Busy: Sendable {}
    @Initial case open(Open)
    case busy(Busy)
    enum Input: Sendable { case load, close }
    @Operation(activeIn: [Busy.self])
    enum Load {
        enum Swift {}
        struct Void {}
        enum Never {}
        static func exported(input: (Void).Type, output: (Void).Type, failure: (Never).Type) {}
        static func check() { exported(input: Input.self, output: Output.self, failure: Swift::Never.self) }
    }
    @Event
    enum Closing {
        struct Void {}
        static func exported(payload: (Void).Type) {}
        static func check() { exported(payload: Payload.self) }
    }
    @Transition(on: Input.load, starts: [Load.self])
    fileprivate static func load(_ source: Open) -> Change<Busy, Effect.Load> { Change(Busy(), effects: [.load]) }
    @Transition(onSuccess: Load.self)
    fileprivate static func loaded(_ source: Busy) -> Open { Open() }
    @Transition(on: Input.close, emits: [Closing.self])
    fileprivate static func close(_ source: Open) -> Change<Open, Effect.Close> { Change(source, effects: [.closing]) }
}

func exportedSpellings() -> [Swift::String] {
    let load = Ledger.graph.operations[0]
    return [load.input, load.output, load.failure, Ledger.graph.events[0].payload]
}
