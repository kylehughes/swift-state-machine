import StateMachine
import StateMachineSchema
@Operation(effect: "fetch", scope: "work", activeIn: ["loading"], admission: .latest)
enum Standalone { typealias Input = Int; typealias Output = Int; typealias Failure = Never }
