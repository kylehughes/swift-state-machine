import StateMachine
enum Scope {
    @Active(in: [Loading.self])
    case work
}
struct Loading {}
@Operation(scope: Scope.work, admission: .latest)
enum Standalone { typealias Input = Int; typealias Output = Int; typealias Failure = Never }
