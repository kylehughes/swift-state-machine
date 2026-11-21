import StateMachine
import Testing

/// A router that takes a closure `sending` while its edges borrow it or take it plain: the routed method
/// takes the closure plain, as a nonescaping closure, which cannot be `consuming`, must be.
@StateMachine(mode: .isolated, owners: [.owned])
nonisolated private enum SentWork {
    struct Idle {}
    struct Quick { let value: Int }
    struct Slow { let value: Int }
    @Initial case idle(Idle = Idle())
    @Terminal case quick(Quick)
    @Terminal case slow(Slow)
    enum Input: Sendable { case act(@Sendable () -> Int) }
    @Route(on: Input.act)
    fileprivate static func choose(_ source: Idle, _ work: sending @Sendable () -> Int) -> Route.Choose {
        work() < 10 ? .runQuickly : .runSlowly
    }
    @Transition(on: Input.act)
    fileprivate static func runQuickly(_ source: Idle, _ work: borrowing @Sendable () -> Int) -> Quick {
        Quick(value: work())
    }
    @Transition(on: Input.act)
    fileprivate static func runSlowly(_ source: Idle, _ work: @Sendable () -> Int) -> Slow { Slow(value: work()) }
}

/// The same through an alias of the closure's type, which the macro reads but generated code repeats as
/// spelled: every function borrows it, so a caller that only borrows the closure can route it.
@StateMachine(mode: .isolated, owners: [.owned])
nonisolated private enum BorrowedWork {
    typealias Work = @Sendable () -> Int
    struct Idle {}
    struct Quick { let value: Int }
    struct Slow { let value: Int }
    @Initial case idle(Idle = Idle())
    @Terminal case quick(Quick)
    @Terminal case slow(Slow)
    enum Input: Sendable { case act(Work) }
    @Route(on: Input.act)
    fileprivate static func choose(_ source: Idle, _ work: borrowing Work) -> Route.Choose {
        work() < 10 ? .runQuickly : .runSlowly
    }
    @Transition(on: Input.act)
    fileprivate static func runQuickly(_ source: Idle, _ work: borrowing Work) -> Quick { Quick(value: work()) }
    @Transition(on: Input.act)
    fileprivate static func runSlowly(_ source: Idle, _ work: borrowing Work) -> Slow { Slow(value: work()) }
}

/// An optional closure, which is escaping, that the router consumes while each edge borrows it after: the
/// method takes it plain and copies it implicitly, and the macro checks that the payload is copyable.
@StateMachine(mode: .isolated, owners: [.owned])
nonisolated private enum OptionalWork {
    struct Idle {}
    struct Quick { let value: Int }
    struct Slow { let value: Int }
    @Initial case idle(Idle = Idle())
    @Terminal case quick(Quick)
    @Terminal case slow(Slow)
    enum Input: Sendable { case act((@Sendable () -> Int)?) }
    @Route(on: Input.act)
    fileprivate static func choose(_ source: Idle, _ work: consuming (@Sendable () -> Int)?) -> Route.Choose {
        (work?() ?? 0) < 10 ? .runQuickly : .runSlowly
    }
    @Transition(on: Input.act)
    fileprivate static func runQuickly(_ source: Idle, _ work: borrowing (@Sendable () -> Int)?) -> Quick {
        Quick(value: (copy work)?() ?? 0)
    }
    @Transition(on: Input.act)
    fileprivate static func runSlowly(_ source: Idle, _ work: borrowing (@Sendable () -> Int)?) -> Slow {
        Slow(value: (copy work)?() ?? 0)
    }
}

/// An escaping closure that an edge consumes: `@escaping` shows the payload is a function the method may
/// consume, so the method takes it `consuming`, as the edge does.
@StateMachine(mode: .isolated, owners: [.owned])
nonisolated private enum KeptWork {
    struct Idle {}
    struct Kept { let work: @Sendable () -> Int }
    struct Seen { let value: Int }
    @Initial case idle(Idle = Idle())
    @Terminal case kept(Kept)
    @Terminal case seen(Seen)
    enum Input: Sendable { case act(@Sendable () -> Int) }
    @Route(on: Input.act)
    fileprivate static func choose(_ source: Idle, _ work: borrowing @escaping @Sendable () -> Int) -> Route.Choose {
        work() < 10 ? .keep : .look
    }
    @Transition(on: Input.act)
    fileprivate static func keep(_ source: Idle, _ work: consuming @escaping @Sendable () -> Int) -> Kept {
        Kept(work: work)
    }
    @Transition(on: Input.act)
    fileprivate static func look(_ source: Idle, _ work: borrowing @escaping @Sendable () -> Int) -> Seen {
        Seen(value: work())
    }
}

@Suite struct RoutedFunctionPayloadTests {
    private struct Unexpected: Error {}

    @Test func aRouterThatSendsAClosureItsEdgesBorrowRoutesIt() throws {
        guard case .runQuickly(let quick) = SentWork.owned().choose({ 3 }) else { throw Unexpected() }
        #expect(quick.withValue { $0.value } == 3)
        guard case .runSlowly(let slow) = SentWork.owned().choose({ 30 }) else { throw Unexpected() }
        #expect(slow.withValue { $0.value } == 30)
    }

    @Test func aBorrowingCallerRoutesABorrowedClosure() throws {
        func route(_ work: borrowing BorrowedWork.Work) -> BorrowedWork.Route.ChooseResult {
            BorrowedWork.owned().choose(work)
        }
        guard case .runSlowly(let slow) = route({ 12 }) else { throw Unexpected() }
        #expect(slow.withValue { $0.value } == 12)
    }

    @Test func anOptionalClosureTheRouterConsumesReachesTheEdge() throws {
        func route(_ work: borrowing (@Sendable () -> Int)?) -> OptionalWork.Route.ChooseResult {
            OptionalWork.owned().choose(work)
        }
        guard case .runQuickly(let quick) = route({ 4 }) else { throw Unexpected() }
        #expect(quick.withValue { $0.value } == 4)
        guard case .runQuickly(let empty) = route(nil) else { throw Unexpected() }
        #expect(empty.withValue { $0.value } == 0)
    }

    @Test func anEscapingClosureAnEdgeConsumesIsKept() throws {
        guard case .keep(let kept) = KeptWork.owned().choose({ 7 }) else { throw Unexpected() }
        #expect(kept.withValue { $0.work() } == 7)
    }
}
