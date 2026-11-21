import StateMachine

/// A generated workflow whose operation result reaches its edge through a router that may decline it.
///
/// Delivering a reading and calling `screen` on an owned `Ready` both run the router `screen`, so
/// neither can record a negative reading through `accept`.
///
/// The schema lists `Equatable`, so its effects compare in another module: an owned `take()` returns
/// effects equal to `[.measure]`.
@StateMachine(mode: .shared)
nonisolated public enum GeneratedScreen: Sendable, Equatable {
    /// The readings accepted so far.
    public struct Ready: Sendable, Equatable {
        /// Accepted readings in arrival order.
        public let readings: [Int]
        /// Creates ordinary reading data.
        public init(readings: [Int] = []) { self.readings = readings }
    }
    @Initial case ready(Ready = Ready())
    /// Closed dynamic inputs.
    public enum Input: Sendable { case measure }
    /// Why the router declined a reading.
    public enum Refusal: Error, Sendable { case negative }
    /// Takes one reading; it takes no input and cannot fail.
    @Operation(activeIn: [Ready.self])
    public enum Measure {
        /// The reading.
        public typealias Output = Int
    }
    /// Starts a reading.
    @Transition(on: Input.measure, starts: [Measure.self])
    fileprivate static func take(_ source: Ready) -> Change<Ready, Effect.Take> {
        Change(source, effects: [.measure])
    }
    /// Records an accepted reading.
    @Transition(onSuccess: Measure.self)
    fileprivate static func accept(_ source: Ready, _ reading: Measure.Output) -> Ready {
        Ready(readings: source.readings + [reading])
    }
    /// Declines a negative reading, which stays retained for reconciliation.
    @Route(onSuccess: Measure.self)
    fileprivate static func screen(_ source: Ready, _ reading: Measure.Output) throws(Refusal) -> Route.Screen {
        guard reading >= 0 else { throw .negative }
        return .accept
    }
}
