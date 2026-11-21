// Every kind of type spelling the macro reads, in each position an authored type takes, compiles with the meaning Swift gives it.
import StateMachine

/// A type the macro cannot see, which the expansion checks is not `Never`.
typealias Outside = Int

@StateMachine(mode: .shared)
nonisolated enum Matrix: Sendable {
    struct Item: Sendable, Hashable {}
    struct Box<T: Sendable>: Sendable { let value: T }
    struct Problem<T: Sendable>: Error { let detail: T }
    enum Failure: Error { case bad }
    typealias Unit = Void
    typealias `Empty` = ()
    typealias Nothing = Swift::Never
    typealias Identity<T> = T
    typealias Pair<T> = (T, T)
    enum Values { typealias Value = Swift::Int; typealias Unit = () }
    typealias NS = (Values)
    struct Idle: Sendable {}
    struct Running: Sendable {}
    @Initial case idle(Idle)
    case running(`Running`)
    enum Input: Sendable {
        case go
        case back
        case member([Int].Element)
        case parenthesized((Values).Value)
        case sugar([Item: Item?])
        case tuple((first: Item, second: Item))
        case work(@Sendable () -> Item)
        case escaped(`Item`)
        case specialized(Identity<Box<Item>>)
        case existential(any Error & Sendable)
        case metatype(Item.Type)
    }
    // Outcomes through aliases, generic aliases, members, and sugar.
    @Operation(activeIn: [Running.self])
    enum Load {
        typealias Input = Identity<Item>
        typealias Output = NS.Unit
        typealias Failure = Identity<Swift::Never>
        typealias Key = [Int].Element
    }
    @Operation(activeIn: [Running.self])
    enum Fetch {
        typealias Output = Identity<[Item]>
        typealias Failure = Matrix.Failure
    }
    @Operation(activeIn: [Running.self])
    enum Compute {
        typealias Output = @Sendable () -> Item
        typealias Failure = Problem<[Item]>
    }
    @Operation(activeIn: [Running.self])
    enum Outcome { typealias Output = Outside }
    @Operation(activeIn: [Running.self])
    enum Rejection { typealias Output = `Empty` }
    @Event enum Tracked { typealias Payload = Swift.Array<Item> }
    @Event enum Pinged { typealias Payload = Unit }
    @Transition(on: Input.go, starts: [Load.self, Fetch.self, Compute.self, Outcome.self, Rejection.self], emits: [Tracked.self, Pinged.self])
    static func go(_ source: Idle) -> Change<Running, Effect.Go> {
        Change(Running(), effects: [.load(key: 0, input: Item()), .fetch, .compute, .outcome, .rejection, .tracked([]), .pinged])
    }
    @Transition(onSuccess: Load.self)
    static func loaded(_ source: Running, request: LoadRequest) -> Running { source }
    @Transition(onSuccess: Fetch.self)
    static func fetched(_ source: Running, _ items: Swift::Array<Item>) -> Running { source }
    @Transition(onFailure: Fetch.self)
    static func fetchFailed(_ source: Running, _ failure: Failure) -> Running { source }
    @Transition(onSuccess: Compute.self)
    static func computed(_ source: Running, _ work: @escaping @Sendable () -> Item) -> Running { source }
    @Transition(onFailure: Compute.self)
    static func computeFailed(_ source: Running, _ failure: Problem<Swift::Array<Item>>) -> Running { source }
    @Transition(onSuccess: Outcome.self)
    static func outcome(_ source: Running, _ value: Int) -> Running { source }
    @Transition(onSuccess: Rejection.self)
    static func rejection(_ source: Running) -> Running { source }
    @Transition(on: Input.back)
    static func back(_ source: Running) throws(Swift::Never) -> Idle { Idle() }
    @Transition(on: Input.member)
    static func member(_ source: Idle, _ value: Int) -> Idle { source }
    @Transition(on: Input.parenthesized)
    static func parenthesized(_ source: Idle, _ value: Swift.Int) -> Idle { source }
    @Transition(on: Input.sugar)
    static func sugar(_ source: Idle, _ value: Dictionary<Item, Optional<Item>>) -> Idle { source }
    @Transition(on: Input.tuple)
    static func tuple(_ source: Idle, _ value: (first: Item, second: Item)) -> Idle { source }
    @Transition(on: Input.work)
    static func work(_ source: Idle, _ value: @escaping @Sendable () -> Item) -> Idle { source }
    @Transition(on: Input.escaped)
    static func escaped(_ source: `Idle`, _ value: borrowing Item) -> `Idle` { source }
    @Transition(on: Input.specialized)
    static func specialized(_ source: Idle, _ value: Box<Identity<Item>>) throws(Identity<Nothing>) -> Idle { source }
    @Transition(on: Input.existential)
    static func existential(_ source: Idle, _ value: any Sendable & Error) -> Idle { source }
    @Transition(on: Input.metatype)
    static func metatype(_ source: Idle, _ value: Matrix.Item.Type) throws(Problem<[Item]>) -> Idle { source }
}

func use(_ owned: consuming Matrix.Owned<Matrix.Idle>) -> Matrix.Owned<Matrix.Idle> {
    // A nonthrowing edge, even one that throws Never, returns its destination directly.
    let idle = owned.specialized(Matrix.Box(value: Matrix.Item()))
    return idle.work { Matrix.Item() }
}
func outcomes(_ pending: Matrix.PendingCompletion) -> Int? {
    if case .outcome(let value) = pending.outcome { return value }
    return nil
}
func failure(_ observed: Matrix.Observed<Matrix.Idle>) throws(Matrix.Problem<[Matrix.Item]>) -> Matrix.Prepared {
    try observed.metatype(Matrix.Item.self)
}
func loadCannotFail() -> Bool { !Matrix.graph.operations[0].canFail }
