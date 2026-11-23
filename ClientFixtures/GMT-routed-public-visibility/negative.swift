// A public @Route in a public schema cannot use a fileprivate routed: payload type.
import StateMachine

@StateMachine(mode: .isolated, owners: [.owned, .local])
public nonisolated enum VisibilityFlow {
    fileprivate struct SecretStep { let score: Int }
    public struct Ready { public init() {} }
    public struct Done { public let score: Int }
    @Initial case ready(Ready = Ready())
    @Terminal case done(Done)
    public enum Input { case go }

    @Transition(on: Input.go)
    fileprivate static func finish(_ source: Ready, routed step: SecretStep) -> Done {
        Done(score: step.score)
    }

    @Transition(on: Input.go)
    fileprivate static func stay(_ source: Ready) -> Ready { source }

    @Route(on: Input.go)
    public static func choose(_ source: Ready) -> Route.Choose {
        .finish(SecretStep(score: 1))
    }
}
