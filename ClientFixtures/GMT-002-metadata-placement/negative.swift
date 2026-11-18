import StateMachine
enum Scope { case work }
struct Loading {}
@Operation(scope: Scope.work, activeIn: [Loading.self], admission: .latest)
enum Standalone { typealias Input = Int; typealias Output = Int; typealias Failure = Never }
