// Separate library-evolution module with public schemas using fileprivate @Route and fileprivate routed: types
// (including a non-Sendable closure struct, a ~Copyable handle, and split-shape per-phase routers).
// None of the fileprivate routed payload types or fileprivate choice enums may appear in emitted .swiftinterfaces.
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned, .local, .mainActorHost])
public nonisolated enum PublicSortingFlow {
    fileprivate struct SecretStep {
        let left: Int
        let resolve: (Bool) -> Int
    }

    public struct Ready {
        public let seed: Int
        public init(seed: Int = 0) { self.seed = seed }
    }

    public struct Comparing {
        public let left: Int
        public let resolve: (Bool) -> Int
        public init(left: Int, resolve: @escaping (Bool) -> Int) {
            self.left = left
            self.resolve = resolve
        }
    }

    public struct Finished {
        public let winner: Int
        public init(winner: Int) { self.winner = winner }
    }

    @Initial case ready(Ready = Ready())
    case comparing(Comparing)
    @Terminal case finished(Finished)

    public enum Input {
        case start(Int)
        case choose(Bool)
    }

    @Operation(activeIn: [Ready.self])
    public enum StepDelay {
        public typealias Input = Int
        public typealias Output = String
    }

    @Transition(on: Input.start, starts: [StepDelay.self])
    fileprivate static func start(_ source: Ready, _ delay: Int) -> Change<Ready, Effect.Start> {
        Change(source, effects: [.stepDelay(delay)])
    }

    @Transition(onSuccess: StepDelay.self)
    fileprivate static func presentFirst(
        _ source: Ready,
        _ output: String,
        request: StepDelayRequest,
        routed step: SecretStep
    ) -> Comparing {
        Comparing(left: step.left + request.input, resolve: step.resolve)
    }

    @Transition(onSuccess: StepDelay.self)
    fileprivate static func finishReady(
        _ source: Ready,
        _ output: String,
        request: StepDelayRequest
    ) -> Finished {
        Finished(winner: source.seed + request.input)
    }

    @Route(onSuccess: StepDelay.self)
    fileprivate static func routeReadyStep(
        _ source: Ready,
        _ output: String,
        request: StepDelayRequest
    ) -> Route.RouteReadyStep {
        if output.isEmpty {
            return .finishReady
        }
        return .presentFirst(SecretStep(left: source.seed, resolve: { $0 ? 1 : 2 }))
    }

    @Transition(on: Input.choose)
    fileprivate static func advance(_ source: Comparing, _ pickLeft: Bool, routed step: SecretStep) -> Comparing {
        Comparing(left: step.left, resolve: step.resolve)
    }

    @Transition(on: Input.choose)
    fileprivate static func finish(
        _ source: Comparing,
        _ pickLeft: Bool,
        routed summary: (winner: Int, label: String)
    ) -> Finished {
        Finished(winner: summary.winner)
    }

    @Route(on: Input.choose)
    fileprivate static func routeChoice(_ source: Comparing, _ pickLeft: Bool) -> Route.RouteChoice {
        let score = source.resolve(pickLeft)
        return score > 1
            ? .finish((winner: score, label: "done"))
            : .advance(SecretStep(left: score, resolve: source.resolve))
    }
}

@StateMachine(mode: .isolated, owners: [.owned, .local])
public nonisolated enum MoveOnlyRoutedPublicFlow {
    fileprivate struct SecretHandle: ~Copyable {
        let fd: Int
    }

    public struct Open { public init() {} }
    public struct Taken { public let fd: Int }
    public struct Inspected { public let fd: Int }
    @Initial case open(Open = Open())
    @Terminal case taken(Taken)
    @Terminal case inspected(Inspected)
    public enum Input { case run(Bool) }

    @Transition(on: Input.run)
    fileprivate static func take(_ source: Open, _ consumeFlag: Bool, routed handle: consuming SecretHandle) -> Taken {
        Taken(fd: handle.fd)
    }

    @Transition(on: Input.run)
    fileprivate static func inspect(
        _ source: Open,
        _ consumeFlag: Bool,
        routed handle: borrowing SecretHandle
    )
        -> Inspected
    {
        Inspected(fd: handle.fd)
    }

    @Route(on: Input.run)
    fileprivate static func routeOpen(_ source: Open, _ consumeFlag: Bool) -> Route.RouteOpen {
        consumeFlag ? .take(SecretHandle(fd: 7)) : .inspect(SecretHandle(fd: 9))
    }
}

@StateMachine(mode: .shared, owners: [.owned, .local, .shared])
public nonisolated enum SplitShapeRoutedFlow: Sendable {
    public struct Alpha: Sendable { public init() {} }
    public struct Beta: Sendable { public init() {} }
    public struct Done: Sendable { public let tag: String }
    @Initial case alpha(Alpha = Alpha())
    case beta(Beta)
    @Terminal case done(Done)
    public enum Input: Sendable { case step(Bool) }

    @Transition(on: Input.step)
    fileprivate static func next(_ source: Alpha, _ go: Bool, routed count: Int) -> Beta { Beta() }
    @Transition(on: Input.step)
    fileprivate static func stay(_ source: Alpha, _ go: Bool) -> Alpha { source }
    @Route(on: Input.step)
    fileprivate static func choose(_ source: Alpha, _ go: Bool) -> Route.Alpha.Choose {
        go ? .next(1) : .stay
    }

    @Transition(on: Input.step)
    fileprivate static func next(_ source: Beta, _ go: Bool, routed label: String) -> Done { Done(tag: label) }
    @Transition(on: Input.step)
    fileprivate static func stay(_ source: Beta, _ go: Bool) -> Beta { source }
    @Route(on: Input.step)
    fileprivate static func choose(_ source: Beta, _ go: Bool) -> Route.Beta.Choose {
        go ? .next("ok") : .stay
    }
}
