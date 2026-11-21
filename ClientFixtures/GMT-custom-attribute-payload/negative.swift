// A payload type written inside Input resolves there: a nested global actor named as an attribute is
// qualified as a type is, `@Sendable` stays the built-in attribute, and `Swift::Int` keeps naming the
// standard library's type although Input declares its own `Int`.
import StateMachine

@StateMachine(mode: .shared)
nonisolated enum Decoder: Sendable {
    struct Idle: Sendable {}
    @Initial case idle(Idle)
    enum Input: Swift.Sendable {
        @globalActor actor DecodeActor { static let shared = DecodeActor() }
        struct Int: Swift.Sendable {}
        struct Sendable {}
        case decode(@DecodeActor @Sendable () -> Swift::Int)
        case count(Swift::Int)
        case local(Int)
    }
    @Transition(on: Input.decode)
    fileprivate static func decode(_ source: Idle, _ work: @Input.DecodeActor @Sendable () -> Swift.Int) -> Idle {
        source
    }
    @Transition(on: Input.count)
    fileprivate static func count(_ source: Idle, _ value: Swift.Int) -> Idle { source }
    @Transition(on: Input.local)
    fileprivate static func local(_ source: Idle, _ value: Input.Int) -> Idle { source }
}

nonisolated func send(_ decoder: Decoder.Shared) throws {
    try decoder.send(.decode({ @Decoder.Input.DecodeActor in 1 }))
    try decoder.send(.count(Decoder.Input.Int()))
    try decoder.send(.local(Decoder.Input.Int()))
}
