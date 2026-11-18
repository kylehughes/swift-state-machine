import StateMachine
import StateMachineExamples
import Testing

/// A routed input whose router and both candidates throw the same failure type.
@StateMachine(mode: .shared)
nonisolated private enum SharedFailureFlow: Sendable {
    struct Start: Sendable {}
    struct Left: Sendable { let value: Int }
    struct Right: Sendable { let value: Int }
    @Initial case start(Start = Start())
    case left(Left)
    case right(Right)
    enum Input: Sendable { case pick(Int) }
    enum Problem: Error, Equatable, Sendable { case negative, tooLarge, odd }
    @Transition(on: Input.pick)
    fileprivate static func goLeft(_ source: Start, _ value: Int) throws(Problem) -> Left {
        guard value < 100 else { throw .tooLarge }
        return Left(value: value)
    }
    @Transition(on: Input.pick)
    fileprivate static func goRight(_ source: Start, _ value: Int) throws(Problem) -> Right {
        guard value.isMultiple(of: 2) else { throw .odd }
        return Right(value: value)
    }
    @Route(on: Input.pick)
    fileprivate static func pick(_ source: Start, _ value: Int) throws(Problem) -> Route.Pick {
        guard value >= 0 else { throw .negative }
        return value < 10 ? .goLeft : .goRight
    }
}

/// A routed input whose router and candidate throw different failure types.
@StateMachine(mode: .isolated)
nonisolated private enum MixedFailureFlow {
    struct Start {}
    struct Done {}
    @Initial case start(Start = Start())
    case done(Done)
    enum Input { case go(Int) }
    enum Refusal: Error { case negative }
    enum Problem: Error { case odd }
    @Transition(on: Input.go)
    fileprivate static func finish(_ source: Start, _ value: Int) throws(Problem) -> Done {
        guard value.isMultiple(of: 2) else { throw .odd }
        return Done()
    }
    @Route(on: Input.go)
    fileprivate static func screen(_ source: Start, _ value: Int) throws(Refusal) -> Route.Screen {
        guard value >= 0 else { throw .negative }
        return .finish
    }
}

@Suite struct RouterSurfaceTests {
    private struct Unexpected: Error {}

    @Test func aRouterMethodThrowsTheFailureTypeItsGroupShares() throws {
        var owner = SharedFailureFlow.Local()
        guard case .start(let start) = owner.snapshot() else { throw Unexpected() }
        // The closure's declared thrown type compiles only if `pick` throws exactly `Problem`.
        let pick: (Int) throws(SharedFailureFlow.Problem) -> SharedFailureFlow.Prepared = { try start.pick($0) }
        #expect(throws: SharedFailureFlow.Problem.negative) { _ = try pick(-1) }
        #expect(throws: SharedFailureFlow.Problem.odd) { _ = try pick(11) }
        guard case .committed = owner.commit(try pick(4)), case .left(let left) = owner.snapshot() else {
            throw Unexpected()
        }
        #expect(left.value.value == 4)
    }

    @Test func sendStillNamesTheFunctionThatThrew() throws {
        var owner = SharedFailureFlow.Local()
        do {
            try owner.send(.pick(-1))
            Issue.record("a negative value was admitted")
        } catch {
            guard case .preparation(.pick(.negative)) = error else { throw Unexpected() }
        }
        do {
            try owner.send(.pick(11))
            Issue.record("an odd value was admitted")
        } catch {
            guard case .preparation(.goRight(.odd)) = error else { throw Unexpected() }
        }
    }

    @Test func differentFailureTypesWidenToPreparationRejection() throws {
        guard case .start(let start) = MixedFailureFlow.Local().snapshot() else { throw Unexpected() }
        let screen: (Int) throws(MixedFailureFlow.PreparationRejection) -> MixedFailureFlow.Prepared = {
            try start.screen($0)
        }
        do {
            _ = try screen(-1)
            Issue.record("a negative value was prepared")
        } catch {
            guard case .screen(.negative) = error else { throw Unexpected() }
        }
        do {
            _ = try screen(1)
            Issue.record("an odd value was prepared")
        } catch {
            guard case .finish(.odd) = error else { throw Unexpected() }
        }
    }
}

/// `withValue` lends the phase to a closure that may throw a typed error or return a unique value.
@Suite struct OwnedBorrowTests {
    private struct Token: ~Copyable { let attempts: Int }
    private enum Refusal: Error, Equatable { case declined }

    @Test func withValueReturnsAUniqueValueAndPropagatesATypedError() throws {
        let owned = GeneratedRetry.owned(GeneratedRetry.Waiting(attempts: 2, locked: false))
        let token = owned.withValue { waiting in Token(attempts: waiting.attempts) }
        #expect(token.attempts == 2)
        // A closure that cannot throw needs no `try`.
        let locked = owned.withValue { $0.locked }
        #expect(!locked)
        let refuse: (GeneratedRetry.Waiting) throws(Refusal) -> Int = { _ in throw .declined }
        #expect(throws: Refusal.declined) { _ = try owned.withValue(refuse) }
    }
}
